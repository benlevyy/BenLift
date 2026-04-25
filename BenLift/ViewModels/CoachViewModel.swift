import SwiftUI
import SwiftData

@Observable
class CoachViewModel {
    var feeling: Int = 3
    var availableTime: Int? = nil
    var concerns: String = ""

    var currentPlan: DailyPlanResponse?
    var editedExercises: [PlannedExercise] = []
    var isGenerating: Bool = false
    var planError: String?

    /// In-memory log of quick swaps the user has accepted on the current plan.
    /// Cleared when a new plan is generated. Fed back into subsequent swap prompts
    /// so the model can spot patterns (e.g., 3 pressing swaps -> likely shoulder issue).
    var planAdjustments: [AdjustmentRecord] = []

    /// Snapshot of the user inputs (feeling, time, concerns, muscle
    /// overrides) at the moment the currently-shown plan was generated.
    /// Drives `isPlanStale` — when any of these drift from this snapshot,
    /// the Today view surfaces the Refresh pill. Nil before the first plan
    /// lands.
    private var planInputSnapshot: InputSnapshot?

    struct InputSnapshot: Equatable {
        let feeling: Int
        let availableTime: Int?
        let concerns: String
        /// Muscle-group name → user-set status (fresh / ready / recovering
        /// / sore). Empty dict when the user hasn't overridden anything;
        /// the AI's own read governs.
        let muscleOverrides: [String: String]
    }

    /// User-set muscle status overrides. The Training tab's muscle map
    /// lets the user tap a row and force a status (e.g. "actually my
    /// chest is sore today"). Backed by `MuscleOverrideStore` so they
    /// survive app relaunches — stale overrides are valuable signal for
    /// the AI ("user reported chest sore 2d ago"), losing them to a
    /// relaunch would quietly drop that. Cleared when a new plan is
    /// generated (the plan absorbed the override as context).
    var muscleOverrides: [MuscleGroup: String] {
        didSet { persistMuscleOverrides() }
    }

    private func persistMuscleOverrides() {
        var dict: [String: String] = [:]
        for (mg, status) in muscleOverrides { dict[mg.rawValue] = status }
        // Write-through: on every mutation, rewrite the store so memory +
        // disk stay in sync. Tiny dataset, cheap serialization.
        var entries: [String: MuscleOverrideStore.Entry] = [:]
        let existing = MuscleOverrideStore.load()
        for (muscle, status) in dict {
            // Preserve the original setAt if the status hasn't changed so
            // the "reported 3d ago" line the AI sees doesn't reset on
            // every incidental write.
            if let prior = existing[muscle], prior.status == status {
                entries[muscle] = prior
            } else {
                entries[muscle] = .init(status: status, setAt: Date())
            }
        }
        MuscleOverrideStore.save(entries)
    }

    private static func loadMuscleOverrides() -> [MuscleGroup: String] {
        let stored = MuscleOverrideStore.load()
        var out: [MuscleGroup: String] = [:]
        for (key, entry) in stored {
            if let mg = MuscleGroup(rawValue: key) {
                out[mg] = entry.status
            }
        }
        return out
    }

    /// For `InputSnapshot` comparison — Dictionary with MuscleGroup keys
    /// isn't Hashable-friendly inside an Equatable check, so we normalize
    /// to raw-string keys.
    private var muscleOverridesForSnapshot: [String: String] {
        var out: [String: String] = [:]
        for (mg, status) in muscleOverrides { out[mg.rawValue] = status }
        return out
    }

    /// True when the user has changed any of the chip/concerns inputs since
    /// the current plan was generated. Used by the Today view to show a
    /// visible "Refresh plan" pill — replaces the previous debounced
    /// auto-regenerate that fired on every tap and felt fidgety.
    var isPlanStale: Bool {
        guard !editedExercises.isEmpty, let snap = planInputSnapshot else { return false }
        return snap != InputSnapshot(
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns,
            muscleOverrides: muscleOverridesForSnapshot
        )
    }

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
        self.muscleOverrides = Self.loadMuscleOverrides()
        loadCachedGeneration()
    }

    /// Cheap regenerate path for iteration. When the recommendation is
    /// already in hand (muscle-group focus + session name), just re-plan via
    /// `generatePlan` — skips the recommendation half of the combined call,
    /// so it's noticeably faster than the full `getRecommendationAndPlan`.
    /// Pull-to-refresh (which clears recommendation first) still takes the
    /// full path when the user wants a totally fresh session.
    @MainActor
    func refreshPlan(modelContext: ModelContext, program: TrainingProgram?) async {
        if recommendation != nil && !targetMuscleGroups.isEmpty {
            await generatePlan(modelContext: modelContext, program: program)
        } else {
            await getRecommendationAndPlan(modelContext: modelContext, program: program)
        }
    }

    // MARK: - Step 1: Get AI Recommendation (Sonnet)

    var isLoadingRecommendation = false

    @MainActor
    func getRecommendation(modelContext: ModelContext, program: TrainingProgram?) async {
        isLoadingRecommendation = true
        planError = nil

        let healthContext = await HealthKitService.shared.fetchHealthContext()
        let activities = await HealthKitService.shared.fetchRecentActivities(days: 7)

        // Summarize recent sessions
        let recentSummary = ContextBuilder.summarizeAllRecentSessions(limit: 10, modelContext: modelContext)

        // Format activities
        let activitiesText = activities.map { act in
            "\(act.date.shortFormatted): \(act.type) (\(TimeInterval(act.duration).formattedDuration), \(act.source))"
        }.joined(separator: "\n")

        // Load intelligence for prompt context
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        let intelligence = try? modelContext.fetch(intelDescriptor).first

        let (system, user) = PromptBuilder.recommendFocusPrompt(
            recentSessionsSummary: recentSummary,
            recentActivities: activitiesText,
            feeling: feeling,
            soreness: concerns.isEmpty ? nil : concerns,
            program: program,
            healthContext: healthContext,
            intelligence: intelligence
        )

        let model = UserDefaults.standard.string(forKey: "modelRecommendFocus") ?? "claude-sonnet-4-5"

        print("[BenLift/Coach] Getting AI recommendation, feeling=\(feeling), model=\(model)")

        do {
            let rec = try await coachService.recommendFocus(systemPrompt: system, userPrompt: user, model: model)
            recommendation = rec
            targetMuscleGroups = rec.recommendedFocus.compactMap { MuscleGroup(rawValue: $0) }
            currentSessionName = rec.recommendedSessionName
            print("[BenLift/Coach] ✅ Recommendation: \(rec.recommendedSessionName) — \(rec.recommendedFocus.joined(separator: ", "))")
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] Recommendation cancelled (superseded by reload)")
            } else {
                print("[BenLift/Coach] ❌ Recommendation failed: \(error)")
                planError = "Recommendation failed: \(error.localizedDescription)"
            }
        }

        isLoadingRecommendation = false
    }

    /// URLSession cancellation (NSURLErrorCancelled) and Swift `CancellationError`
    /// both fire when a prior request is superseded by a reload/refresh. They're
    /// expected outcomes, not user-facing errors.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        // ClaudeError.networkError wraps the underlying URLError
        if let wrapped = (error as? ClaudeError) {
            if case .networkError(let inner) = wrapped {
                return isCancellation(inner)
            }
        }
        return false
    }

    // MARK: - One-Shot: Recommendation + Plan (single LLM call)

    /// Single round-trip that produces both the recovery recommendation and the
    /// full daily plan. ~2.2x faster than the legacy two-step flow.
    @MainActor
    func getRecommendationAndPlan(modelContext: ModelContext, program: TrainingProgram?) async {
        isLoadingRecommendation = true
        isGenerating = true
        planError = nil

        // Run both HealthKit queries in parallel; each is independent.
        async let healthContextTask = HealthKitService.shared.fetchHealthContext()
        async let activitiesTask = HealthKitService.shared.fetchRecentActivities(days: 7)
        let healthContext = await healthContextTask
        let activities = await activitiesTask
        let activitiesText = activities.map { act in
            "\(act.date.shortFormatted): \(act.type) (\(TimeInterval(act.duration).formattedDuration), \(act.source))"
        }.joined(separator: "\n")

        // Shared recent-session summary (used to be re-computed in each stage).
        let recentSummary = ContextBuilder.summarizeAllRecentSessions(limit: 10, modelContext: modelContext)

        // Load weight cache + recent-exercise ranking + library + weekly
        // volume from SwiftData. Recent ranking flows into the watch plan
        // so the add-exercise picker can show a "Recent" section up top.
        loadAllLastWeights(modelContext: modelContext)
        refreshRecentExerciseNames(modelContext: modelContext)
        let allExercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let library = MuscleGroup.allCases.compactMap { group -> String? in
            let items = allExercises.filter { $0.muscleGroup == group }
            guard !items.isEmpty else { return nil }
            let names = items.map { $0.equipment == .bodyweight ? "\($0.name) (BW)" : $0.name }
                .joined(separator: ", ")
            return "\(group.displayName): \(names)"
        }.joined(separator: "\n")
        let volumeProgress = ContextBuilder.weeklyVolumeProgress(
            modelContext: modelContext,
            exerciseLookup: DefaultExercises.buildMuscleGroupLookup(from: modelContext)
        )

        // Intelligence
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        let intelligence = try? modelContext.fetch(intelDescriptor).first

        // Fold user muscle-state overrides into concerns — they need to
        // reach the AI's prompt. Prefixed so the model can recognize them
        // as user-reported ground truth rather than just vague notes.
        let concernsForPrompt = combinedConcerns()

        // Build the structured UserState snapshot — the AI reads this
        // instead of the old per-field text dump. Big token win + puts
        // UserRules (the "never suggest X" layer) into every prompt.
        let healthAverages = await HealthKitService.shared.fetchHealthAverages(days: 7)
        let userState = UserState.current(
            modelContext: modelContext,
            program: program,
            intelligence: intelligence,
            checkIn: UserState.CheckInInput(
                feeling: feeling,
                availableTime: availableTime,
                concerns: concernsForPrompt
            ),
            healthContext: healthContext,
            healthAverages: healthAverages,
            recentActivities: activities
        )

        let (system, user) = PromptBuilder.recommendAndPlanPrompt(
            userState: userState,
            recentSessionsSummary: recentSummary,
            recentActivities: activitiesText,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concernsForPrompt.isEmpty ? nil : concernsForPrompt,
            exerciseLibrary: library,
            weeklyVolumeProgress: volumeProgress,
            program: program,
            healthContext: healthContext,
            intelligence: intelligence
        )

        // Single Haiku call replaces the prior Sonnet→Haiku pipeline.
        let model = UserDefaults.standard.string(forKey: "modelDailyPlan") ?? "claude-haiku-4-5"
        print("[BenLift/Coach] recommendAndPlan: feeling=\(feeling), model=\(model)")

        // Don't wipe the visible plan up front — refresh feels slow when
        // the screen flashes through empty/skeleton even though the old
        // plan was perfectly fine to look at while the new one builds.
        // We hold the existing rows on screen (UI dims them via
        // `isGenerating`) and only replace them when the new
        // recommendation event lands. Cold-start case is unaffected:
        // editedExercises is already empty, so the skeleton shows
        // automatically until first event.

        do {
            let stream = coachService.streamRecommendAndPlan(
                systemPrompt: system,
                userPrompt: user,
                model: model
            )
            var finalResponse: RecommendAndPlanResponse?
            var didClearOldPlan = false

            for try await event in stream {
                switch event {
                case .recommendation(let rec):
                    // First event — atomically: clear old plan, set new
                    // recommendation, dismiss skeleton. Wrapped in
                    // withAnimation so the swap is one smooth transition,
                    // not three discrete renders.
                    withAnimation(.smooth(duration: 0.4)) {
                        editedExercises = []
                        currentPlan = nil
                        recommendation = rec
                        targetMuscleGroups = rec.recommendedFocus.compactMap { MuscleGroup(rawValue: $0) }
                        currentSessionName = rec.recommendedSessionName
                        isLoadingRecommendation = false
                    }
                    didClearOldPlan = true

                case .exercise(let exercise):
                    // Defensive: if for some reason the recommendation
                    // event was skipped (malformed prefix), still clear
                    // the old plan before appending so we don't mix old
                    // and new exercises.
                    if !didClearOldPlan {
                        withAnimation(.smooth(duration: 0.4)) {
                            editedExercises = []
                        }
                        didClearOldPlan = true
                    }
                    // Append as-it-arrives. pickStartingWeight runs the
                    // same sanitization (history > LLM > default) used by
                    // the non-streaming path so partial state is never
                    // worse than full state.
                    editedExercises.append(pickStartingWeight(exercise))

                case .strategy(let strategy):
                    // We don't have the full DailyPlanResponse yet, so
                    // park the strategy on a placeholder currentPlan.
                    // It'll get replaced on .complete with the real
                    // typed object.
                    currentPlan = DailyPlanResponse(
                        exercises: editedExercises,
                        sessionStrategy: strategy,
                        estimatedDuration: nil,
                        deloadNote: nil
                    )

                case .complete(let response):
                    finalResponse = response
                }
            }

            guard let response = finalResponse else {
                throw ClaudeError.noContent
            }

            // Final sync: source of truth is the complete response.
            // Anything the scanner missed (rare malformed-prefix case)
            // gets backfilled here so the saved plan is always atomic.
            if recommendation == nil {
                recommendation = response.asRecommendation
                targetMuscleGroups = response.recommendedFocus.compactMap { MuscleGroup(rawValue: $0) }
                currentSessionName = response.recommendedSessionName
            }
            let plan = response.asPlan
            currentPlan = plan
            // Reconcile streamed exercises against the canonical list —
            // identical in the happy path; the canonical list wins on any
            // diff (e.g. if the model patched an earlier exercise mid-stream).
            editedExercises = plan.exercises.map(pickStartingWeight)

            // Fresh plan → fresh adjustment history.
            planAdjustments = []

            // Concerns were one-shot intent ("go heavy today", "shoulder
            // sore") — once a plan absorbs them they're stale. Clear on
            // the VM before snapshotting so `isPlanStale` measures against
            // the post-consumption state and the UI text field empties.
            concerns = ""

            // Capture the inputs that produced this plan. `isPlanStale`
            // compares live values to this snapshot to decide whether to
            // show the Refresh pill on Today.
            planInputSnapshot = InputSnapshot(
                feeling: feeling,
                availableTime: availableTime,
                concerns: concerns,
                muscleOverrides: muscleOverridesForSnapshot
            )

            // Overrides have now been absorbed into the plan — clear them
            // so tomorrow's plan isn't silently double-applying yesterday's
            // "chest sore" report.
            clearAllMuscleOverrides()

            markGenerated(modelContext: modelContext)
            print("[BenLift/Coach] ✅ recommendAndPlan (streamed): \(response.recommendedSessionName) — \(editedExercises.count) exercises")
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] recommendAndPlan cancelled (superseded by reload)")
            } else {
                print("[BenLift/Coach] ❌ recommendAndPlan failed: \(error)")
                planError = "Couldn't generate today's plan: \(error.localizedDescription)"
            }
        }

        isLoadingRecommendation = false
        isGenerating = false
    }

    // MARK: - Step 2: Generate Plan (Haiku)

    @MainActor
    func generatePlan(modelContext: ModelContext, program: TrainingProgram?) async {
        isGenerating = true
        planError = nil

        // Load last weights + refresh recent-exercise ranking so the watch
        // plan gets the up-to-date "Recent" list on iteration refreshes too.
        loadAllLastWeights(modelContext: modelContext)
        refreshRecentExerciseNames(modelContext: modelContext)

        let healthContext = await HealthKitService.shared.fetchHealthContext()
        let healthAverages = await HealthKitService.shared.fetchHealthAverages(days: 7)
        let activities = await HealthKitService.shared.fetchRecentActivities(days: 7)

        // Same prompt-folding of muscle overrides as the combined path —
        // see `combinedConcerns()` for why we prefix them.
        let concernsForPrompt = combinedConcerns()

        // Build a UserState so iteration refreshes hit the same
        // structured prompt as the full recommend-and-plan path.
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        let intelligence = try? modelContext.fetch(intelDescriptor).first
        let userState = UserState.current(
            modelContext: modelContext,
            program: program,
            intelligence: intelligence,
            checkIn: UserState.CheckInInput(
                feeling: feeling,
                availableTime: availableTime,
                concerns: concernsForPrompt
            ),
            healthContext: healthContext,
            healthAverages: healthAverages,
            recentActivities: activities
        )

        let (system, user) = ContextBuilder.buildDailyPlanContext(
            userState: userState,
            targetMuscleGroups: targetMuscleGroups,
            sessionName: currentSessionName,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concernsForPrompt.isEmpty ? nil : concernsForPrompt,
            modelContext: modelContext,
            program: program,
            healthContext: healthContext
        )

        let model = UserDefaults.standard.string(forKey: "modelDailyPlan") ?? "claude-haiku-4-5"

        print("[BenLift/Coach] Generating plan for \(currentSessionName ?? "Custom"), feeling=\(feeling), time=\(availableTime.map { "\($0)min" } ?? "unset")")

        do {
            let plan = try await coachService.generateDailyPlan(systemPrompt: system, userPrompt: user, model: model)
            currentPlan = plan
            // New plan => fresh adjustment history
            planAdjustments = []
            // Starting weight: trust user history > sanitized LLM suggestion > library default.
            editedExercises = plan.exercises.map(pickStartingWeight)
            // Concerns consumed by the plan — clear before snapshotting so
            // the text field empties and the Refresh pill rests correctly.
            concerns = ""
            // Same snapshot dance as `getRecommendationAndPlan` so the
            // Refresh pill clears after an iteration refresh too.
            planInputSnapshot = InputSnapshot(
                feeling: feeling,
                availableTime: availableTime,
                concerns: concerns,
                muscleOverrides: muscleOverridesForSnapshot
            )
            // Plan absorbed the overrides — reset so tomorrow starts fresh.
            clearAllMuscleOverrides()
            print("[BenLift/Coach] ✅ Plan generated: \(editedExercises.count) exercises")
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] Plan generation cancelled (superseded by reload)")
            } else {
                print("[BenLift/Coach] ❌ Plan generation failed: \(error)")
                planError = error.localizedDescription
            }
        }

        isGenerating = false
    }

    /// Look up the most recent working weight for an exercise from SwiftData history.
    /// Populated by `loadAllLastWeights` and consumed by `pickStartingWeight`.
    private var _weightCache: [String: Double] = [:]

    /// Top ~10 exercise names from the user's last 30 days of sessions,
    /// ranked by usage. Refreshed whenever we regenerate a plan and
    /// piggybacked into `WatchWorkoutPlan.recentExercises` so the watch's
    /// add-exercise picker can surface them in a "Recent" section without
    /// needing its own SwiftData access.
    private var _recentExerciseNames: [String] = []

    /// Recompute the recent-exercise ranking from history. Cheap (bounded
    /// scan) and only called during plan generation, so no need to
    /// memoize beyond the single session.
    @MainActor
    private func refreshRecentExerciseNames(modelContext: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= cutoff }
        )
        guard let sessions = try? modelContext.fetch(descriptor) else {
            _recentExerciseNames = []
            return
        }
        var counts: [String: Int] = [:]
        for session in sessions {
            for entry in session.entries where !entry.isSkipped {
                counts[entry.exerciseName, default: 0] += 1
            }
        }
        _recentExerciseNames = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key  // stable alpha tiebreak
            }
            .prefix(10)
            .map { $0.key }
    }

    /// Decide a sane starting weight for a planned exercise.
    ///
    /// The LLM can't actually observe the user's strength — it only sees whatever
    /// context we feed it, and has been known to hallucinate garbage values
    /// (e.g. 15000 lb). The user's own recent working weight is a far better signal.
    /// Priority: recent history > sanitized LLM suggestion > library default > 0.
    @MainActor
    private func pickStartingWeight(_ exercise: PlannedExercise) -> PlannedExercise {
        let def = DefaultExercises.all.first { $0.name == exercise.name }
        let llmWeight = exercise.weight
        let sanitizedLLM = Self.plausibleWeight(llmWeight, for: def?.equipment)
        let histWeight = _weightCache[exercise.name].flatMap {
            Self.plausibleWeight($0, for: def?.equipment)
        }

        let finalWeight = histWeight ?? sanitizedLLM ?? def?.defaultWeight ?? 0

        if finalWeight != llmWeight {
            print("[BenLift/Coach] Start weight override for \(exercise.name): \(llmWeight) → \(finalWeight) (hist=\(histWeight.map { "\($0)" } ?? "nil"), llm=\(llmWeight), default=\(def?.defaultWeight.map { "\($0)" } ?? "nil"))")
        }

        return PlannedExercise(
            name: exercise.name,
            sets: exercise.sets,
            targetReps: exercise.targetReps,
            suggestedWeight: finalWeight,
            repScheme: exercise.repScheme,
            warmupSets: exercise.warmupSets,
            notes: exercise.notes,
            intent: exercise.intent
        )
    }

    /// Returns the weight if it's within a sensible range for the given equipment;
    /// otherwise nil so the caller can fall back to history or a library default.
    /// Upper bounds are deliberately generous — they only catch clearly-nonsense
    /// values (LLM hallucinations, unit mix-ups), not legitimately heavy loads.
    private static func plausibleWeight(_ value: Double, for equipment: Equipment?) -> Double? {
        guard value > 0 else { return nil }
        let ceiling: Double
        switch equipment {
        case .barbell: ceiling = 1000   // beyond world-class
        case .dumbbell: ceiling = 200   // heaviest commercial DBs
        case .machine: ceiling = 500    // full plate/pin stacks
        case .cable: ceiling = 300
        case .kettlebell: ceiling = 150
        case .bodyweight: ceiling = 300 // added load (vest/belt)
        case .none: ceiling = 500       // unknown equipment: play safe
        }
        return value <= ceiling ? value : nil
    }

    /// Load weights from ALL recent sessions (not category-specific) — for dynamic plans
    @MainActor
    func loadAllLastWeights(modelContext: ModelContext) {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        guard let sessions = try? modelContext.fetch(descriptor) else { return }

        for session in sessions {
            for entry in session.entries {
                if _weightCache[entry.exerciseName] == nil {
                    if let topSet = StatsEngine.topSet(sets: entry.sets) {
                        _weightCache[entry.exerciseName] = topSet.weight
                    }
                }
            }
        }
        print("[BenLift/Coach] Loaded all last weights: \(_weightCache.count) exercises")
    }

    /// Remove an exercise from the current plan. When `modelContext` is
    /// provided, also records a durable `exerciseOut` UserRule so the AI
    /// knows to exclude this exercise from subsequent plans until the
    /// user adds it back. The modelContext arg is optional for back-
    /// compat with call sites that don't have it handy; Today's plan
    /// list passes it in, which is the user-facing removal path.
    @MainActor
    func removeExercise(at index: Int, modelContext: ModelContext? = nil) {
        guard index < editedExercises.count else { return }
        let removed = editedExercises[index]
        editedExercises.remove(at: index)
        if let modelContext {
            UserRuleStore.addExerciseOut(
                exerciseName: removed.name,
                reason: "Removed from plan",
                modelContext: modelContext
            )
        }
    }

    func moveExercise(from source: IndexSet, to destination: Int) {
        editedExercises.move(fromOffsets: source, toOffset: destination)
    }

    /// Custom-drag reorder: pluck the named exercise and re-insert at the
    /// final desired position. `targetIndex` is the position the user
    /// wants the item to occupy in the resulting array — NOT a "drop
    /// before this index" semantic. Bounds are clamped so callers can
    /// pass any int and we'll snap it to a valid slot.
    @MainActor
    func moveExercise(named name: String, toIndex targetIndex: Int) {
        guard let from = editedExercises.firstIndex(where: { $0.name == name }) else { return }
        guard from != targetIndex else { return }
        let item = editedExercises.remove(at: from)
        let clamped = max(0, min(targetIndex, editedExercises.count))
        editedExercises.insert(item, at: clamped)
        persistCachedGeneration()
    }

    /// Add an exercise to the current plan. If a matching `exerciseOut`
    /// rule exists, archive it — the user explicitly wanting the
    /// exercise back is the strongest possible "never mind, suggest it
    /// again" signal, cleaner than waiting for the rule to decay.
    @MainActor
    func addExerciseToPlan(_ exercise: PlannedExercise, modelContext: ModelContext) {
        editedExercises.append(exercise)
        UserRuleStore.archiveExerciseOutRule(
            for: exercise.name,
            modelContext: modelContext
        )
    }

    /// Convert current plan to WatchWorkoutPlan for transfer
    func buildWatchPlan() -> WatchWorkoutPlan? {
        guard !editedExercises.isEmpty else { return nil }
        let watchExercises = editedExercises.map { exercise in
            WatchExerciseInfo(
                name: exercise.name,
                sets: exercise.sets,
                targetReps: exercise.targetReps,
                suggestedWeight: exercise.weight,
                warmupSets: exercise.warmupSets,
                notes: exercise.notes,
                intent: exercise.intent,
                lastWeight: nil,
                lastReps: nil,
                equipment: DefaultExercises.all.first(where: { $0.name == exercise.name })?.equipment
            )
        }
        let restTimer = UserDefaults.standard.double(forKey: "restTimerDuration")
        let increment = UserDefaults.standard.double(forKey: "weightIncrement")

        return WatchWorkoutPlan(
            sessionName: currentSessionName,
            muscleGroups: targetMuscleGroups.map(\.rawValue),
            category: nil,
            exercises: watchExercises,
            sessionStrategy: currentPlan?.sessionStrategy,
            restTimerDuration: restTimer > 0 ? restTimer : 150,
            weightIncrement: increment > 0 ? increment : 5.0,
            aiPlanUsed: true,
            recentExercises: _recentExerciseNames.isEmpty ? nil : _recentExerciseNames
        )
    }

    // MARK: - Dynamic Training Support

    var recommendation: RecoveryRecommendation?
    var targetMuscleGroups: [MuscleGroup] = []
    var currentSessionName: String?

    // MARK: - Quick Swap (planning)

    /// Index of the exercise currently being swapped — used by the UI to show a
    /// per-row spinner. Nil when no swap is in flight. Only one swap at a time.
    var swappingIndex: Int?

    @MainActor
    func quickSwap(at index: Int, modelContext: ModelContext) async {
        guard index < editedExercises.count else { return }
        let original = editedExercises[index]
        swappingIndex = index
        defer { swappingIndex = nil }

        let allExercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let availableNames = allExercises.map(\.name).filter { $0 != original.name }

        let (system, user) = PromptBuilder.quickSwapPrompt(
            exerciseName: original.name,
            sets: original.sets,
            targetReps: original.targetReps,
            intent: original.intent,
            availableExercises: availableNames,
            priorAdjustments: planAdjustments
        )

        let model = UserDefaults.standard.string(forKey: "modelMidWorkout") ?? "claude-haiku-4-5-20251001"
        do {
            let response = try await coachService.adaptMidWorkout(
                systemPrompt: system,
                userPrompt: user,
                model: model
            )
            guard let replacement = response.exercises.first else {
                print("[BenLift/Coach] quickSwap: no replacement returned")
                return
            }
            // Re-check index — the user may have edited the list while we were waiting.
            guard index < editedExercises.count, editedExercises[index].name == original.name else {
                print("[BenLift/Coach] quickSwap: list changed during request, dropping result")
                return
            }
            editedExercises[index] = PlannedExercise(
                name: replacement.name,
                sets: replacement.sets,
                targetReps: replacement.targetReps,
                suggestedWeight: replacement.suggestedWeight,
                repScheme: original.repScheme,
                warmupSets: replacement.warmupSets,
                notes: replacement.notes ?? original.notes,
                intent: replacement.intent ?? original.intent
            )
            planAdjustments.append(AdjustmentRecord(
                kind: .swap,
                summary: "Swapped \(original.name) -> \(replacement.name)"
            ))
            persistCachedGeneration()
            print("[BenLift/Coach] ↔ Swapped \(original.name) → \(replacement.name)")
        } catch {
            if Self.isCancellation(error) { return }
            print("[BenLift/Coach] ❌ quickSwap failed: \(error)")
        }
    }

    // MARK: - Recommendation Cache

    private var lastGeneratedSessionCount: Int?
    private var lastGeneratedDate: Date?

    /// Returns true if we should skip regeneration (nothing changed since last call)
    @MainActor
    func shouldSkipRegeneration(modelContext: ModelContext) -> Bool {
        guard recommendation != nil, !editedExercises.isEmpty else { return false }
        guard let cachedCount = lastGeneratedSessionCount,
              let cachedDate = lastGeneratedDate else { return false }

        // Skip if generated today and session count hasn't changed
        let isToday = Calendar.current.isDateInToday(cachedDate)
        let currentCount = (try? modelContext.fetchCount(FetchDescriptor<WorkoutSession>())) ?? 0

        return isToday && currentCount == cachedCount
    }

    /// Call after successful generation to snapshot current state
    @MainActor
    func markGenerated(modelContext: ModelContext) {
        lastGeneratedDate = Date()
        lastGeneratedSessionCount = (try? modelContext.fetchCount(FetchDescriptor<WorkoutSession>())) ?? 0
        persistCachedGeneration()
    }

    // MARK: - Persistent cache (so cold launches can skip regeneration)

    private struct CachedGeneration: Codable {
        let recommendation: RecoveryRecommendation
        let currentPlan: DailyPlanResponse
        let editedExercises: [PlannedExercise]
        let sessionCount: Int
        let generatedAt: Date
    }

    private static let cacheKey = "BenLift.coach.cachedGeneration"

    private func persistCachedGeneration() {
        guard let rec = recommendation,
              let plan = currentPlan,
              let date = lastGeneratedDate,
              let count = lastGeneratedSessionCount else { return }
        let snapshot = CachedGeneration(
            recommendation: rec,
            currentPlan: plan,
            editedExercises: editedExercises,
            sessionCount: count,
            generatedAt: date
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func loadCachedGeneration() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let snapshot = try? JSONDecoder().decode(CachedGeneration.self, from: data) else { return }
        recommendation = snapshot.recommendation
        currentPlan = snapshot.currentPlan
        editedExercises = snapshot.editedExercises
        lastGeneratedDate = snapshot.generatedAt
        lastGeneratedSessionCount = snapshot.sessionCount
        // Seed the input snapshot with the current VM inputs so the
        // Refresh pill works on cold launches that skip regeneration.
        // Without this, `isPlanStale` always returned false (snapshot=nil)
        // and the pill never appeared — which is exactly what the user
        // reported as "refresh is just not there physically."
        planInputSnapshot = InputSnapshot(
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns,
            muscleOverrides: muscleOverridesForSnapshot
        )
    }

    // MARK: - Muscle Overrides

    /// Set or clear a user-reported muscle status override. Nil clears
    /// the override and lets the AI / computed read govern again.
    @MainActor
    func setMuscleOverride(_ muscle: MuscleGroup, status: String?) {
        if let status {
            muscleOverrides[muscle] = status
        } else {
            muscleOverrides.removeValue(forKey: muscle)
        }
    }

    @MainActor
    func clearAllMuscleOverrides() {
        muscleOverrides.removeAll()
        MuscleOverrideStore.clearAll()
    }

    /// Render user overrides as a short string for the LLM prompt. Empty
    /// when no overrides set so the caller can skip including a section.
    func formattedMuscleOverridesForPrompt() -> String {
        guard !muscleOverrides.isEmpty else { return "" }
        return muscleOverrides
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.displayName): \($0.value)" }
            .joined(separator: ", ")
    }

    /// Compose the user's concerns text + any muscle-state overrides into
    /// a single string to hand to the prompt layer. Overrides get a
    /// prefix ("User-reported muscle state:") so the model can treat them
    /// as ground truth rather than a vague aside. Returns empty string
    /// when neither concerns nor overrides are set — caller passes nil.
    func combinedConcerns() -> String {
        let overrides = formattedMuscleOverridesForPrompt()
        let concernsText = concerns.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (overrides.isEmpty, concernsText.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return concernsText
        case (false, true):
            return "User-reported muscle state: \(overrides)"
        case (false, false):
            return "User-reported muscle state: \(overrides). \(concernsText)"
        }
    }
}
