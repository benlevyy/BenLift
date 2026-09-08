import SwiftUI
import SwiftData

@Observable
class CoachViewModel {
    var feeling: Int = 3
    /// Defaults to 60 (visibly pre-selected in the Time chips) so a plan
    /// generates immediately on launch without waiting on a check-in —
    /// the user adjusts it afterward if 60/"OK" wasn't right for today.
    var availableTime: Int? = 60
    var concerns: String = ""

    var currentPlan: DailyPlanResponse?
    var editedExercises: [PlannedExercise] = []
    var isGenerating: Bool = false
    var planError: String?

    // MARK: - Iterate state
    //
    // The manual "Customize" sheet that used to read this is gone (folded
    // into the single Update Plan action on Today). `iterate(...)` is now
    // only called automatically, by the future-conflict / recovery-overlap
    // pill actions — `iterateLastResult` isn't read by any UI, but
    // `iterateError` rides the shared error banner on Today so a failed
    // pill action isn't silently swallowed.

    /// Result of the last successful iterate call. Set in `iterate(...)`.
    /// Nil between requests.
    var iterateLastResult: IterateResultDisplay?

    /// User-facing error string from the last iterate call. Surfaced inline
    /// in the sheet with a Retry button. Nil on success.
    var iterateError: String?

    /// True while an iterate request is in flight. Drives the sheet's
    /// spinner + disables the submit button.
    var isIterating: Bool = false

    /// What the iterate sheet should render. Wraps the two service-side
    /// shapes so the view doesn't have to know about IterateResponse's
    /// codable discriminator dance.
    enum IterateResultDisplay {
        case edit(IterateEdit)
        case explain(IterateExplain)
    }

    /// In-memory log of quick swaps the user has accepted on the current plan.
    /// Cleared when a new plan is generated. Fed back into subsequent swap prompts
    /// so the model can spot patterns (e.g., 3 pressing swaps -> likely shoulder issue).
    var planAdjustments: [AdjustmentRecord] = []

    // MARK: - Future-pin overlap state
    //
    // After a plan is generated, we scan its exercises against any pins on
    // the next ±2 days. If today's plan hits a muscle the user has already
    // committed to in the near future, we surface a pill so the user can
    // (optionally) redistribute the volume — same UX shape as the refresh
    // pill. Adjusting routes through `iterate(...)` so the LLM does the
    // actual redistribution; the deterministic baseline doesn't try to
    // be clever about volume math.

    var futureConflicts: [FutureConflict] = []
    var isAdjustingForConflict: Bool = false

    struct FutureConflict: Identifiable {
        let id = UUID()
        let muscle: MuscleGroup
        let date: Date
        let daysOut: Int  // 1 = tomorrow, 2 = day after
    }

    // MARK: - Recovery overlap pattern
    //
    // Surfaced when the next 5 days (today + 4 future) hit the same muscle
    // 3+ times — typical recovery is 48–72h, so 3 hits in 5 days is
    // borderline overtraining. We don't refuse; we surface a pill that
    // routes through iterate to redistribute. Per-week dismissal so the
    // user isn't nagged after they've explicitly chosen to keep the load.

    var recoveryOverlap: RecoveryOverlap?
    var isAdjustingForRecoveryOverlap: Bool = false

    struct RecoveryOverlap: Identifiable {
        let id = UUID()
        let muscle: MuscleGroup
        let hits: Int          // count in the 5-day window
        let windowDays: Int    // currently always 5; carried for messaging
    }

    /// ISO week identifier of the last dismissal, scoped per muscle. Lets
    /// the pill self-suppress after the user explicitly says "I'll keep it"
    /// without nagging again until the calendar week rolls over.
    /// Stored in UserDefaults so dismissals survive app launches.
    private static let dismissalKey = "recoveryOverlapDismissals"

    private static func dismissedThisWeek(muscle: MuscleGroup, now: Date = Date()) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: dismissalKey) as? [String: String] ?? [:]
        guard let stored = map[muscle.rawValue] else { return false }
        return stored == Self.weekKey(for: now)
    }

    private static func recordDismissal(muscle: MuscleGroup, now: Date = Date()) {
        var map = UserDefaults.standard.dictionary(forKey: dismissalKey) as? [String: String] ?? [:]
        map[muscle.rawValue] = Self.weekKey(for: now)
        UserDefaults.standard.set(map, forKey: dismissalKey)
    }

    private static func weekKey(for date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
    }

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
        /// Raw values of muscles pinned for today, ordered. Pinning a
        /// different muscle for today drifts this list and trips
        /// `isPlanStale`, surfacing the refresh pill — same UX as
        /// changing the time chip or the concerns field.
        let todayPinnedMuscles: [String]
    }

    /// Current today-pin muscles, set by the view layer (TodayView observes
    /// MuscleGroupPin via @Query and writes the today row's raw muscle
    /// values here on change). Read by `isPlanStale` and snapshotted at
    /// plan-generation time.
    var todayPinnedMusclesRaw: [String] = []

    /// Phase of the in-flight V5 escalation, surfaced to the UI so the
    /// thinking spinner can advance ("reasoning..." → "drafting..." →
    /// done) instead of looking like one ~15-second hang. Nil when no V5
    /// call is in flight or after `.complete`.
    var planForTodayPhase: PlanForTodayPhase?

    enum PlanForTodayPhase: Equatable {
        case reasoning   // .thinking event from server
        case drafting    // .drafting event — visible text streaming
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
        return snap != currentInputSnapshot()
    }

    /// Helper to build the current InputSnapshot — used both for the
    /// staleness check and to record the snapshot at plan generation time.
    /// Keeps the field list in one place so adding a new tracked input
    /// (today pin, etc.) only needs one update site.
    private func currentInputSnapshot() -> InputSnapshot {
        InputSnapshot(
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns,
            muscleOverrides: muscleOverridesForSnapshot,
            todayPinnedMuscles: todayPinnedMusclesRaw
        )
    }

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
        self.muscleOverrides = Self.loadMuscleOverrides()
        loadCachedGeneration()
    }

    /// Refresh entry point for the Refresh pill. Used to branch into a
    /// "cheap" non-thinking regenerate (`generatePlan`, now removed) once a
    /// recommendation was already in hand. That shortcut predated
    /// always-escalating to daily_plan_v5 and bypassed the whole V2
    /// pipeline — no PlannerInput, no thinking, no streaming — which is
    /// exactly what timed out on a heavy prompt against a short
    /// non-streaming timeout. Every refresh now goes through the same
    /// real path as a cold start.
    @MainActor
    func refreshPlan(modelContext: ModelContext, program: TrainingProgram?) async {
        await getRecommendationAndPlan(modelContext: modelContext, program: program)
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

        let model = ClaudeModel.current

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
        // V2 escalation gate (Option B). The deterministic baseline planner
        // handles routine days for free; the LLM (daily_plan_v5) only fires
        // when there's a flagged condition (injury, low readiness, cold
        // start). Set `usePlannerLegacy=true` in UserDefaults to force the
        // original single-call recommend+plan flow. Falls through to legacy
        // when V2 can't build a PlannerInput (literal first session, no
        // bootstrap seed yet).
        if !UserDefaults.standard.bool(forKey: "usePlannerLegacy") {
            if await planForToday(modelContext: modelContext, program: program) {
                return
            }
            print("[BenLift/Coach] V2 had no PlannerInput — falling through to legacy")
        }

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

        let model = ClaudeModel.current
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
            planInputSnapshot = currentInputSnapshot()

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

    // MARK: - V2: LLM-first planning (BaselinePlanner as offline fallback)
    //
    // Single-user app, precision over cost/speed: every day's plan goes
    // through daily_plan_v5 — the LLM with extended thinking that scored
    // 5/5 on the safety fixtures. BaselinePlanner no longer sits on the
    // happy path; it only runs when the Claude call itself fails (offline,
    // API down, malformed stream), so there's still a plan on screen
    // instead of a dead end.
    //
    // Returns true if it produced a plan, false if PlannerInput.build
    // came back nil (true cold start — no calendar signal, no AI rec yet).
    // Caller falls through to the legacy v1 path on false.

    @MainActor
    func planForToday(modelContext: ModelContext, program: TrainingProgram?) async -> Bool {
        isLoadingRecommendation = true
        isGenerating = true
        planError = nil

        // PlannerInput needs HK context + activities for the recovery block
        // and to color past-day muscle state. Fetched in parallel.
        async let healthContextTask = HealthKitService.shared.fetchHealthContext()
        async let activitiesTask = HealthKitService.shared.fetchRecentActivities(days: 7)
        let healthContext = await healthContextTask
        let activities = await activitiesTask

        // combinedConcerns folds muscle-override taps into the freeform
        // concerns string the AI reads — same trick as the legacy path.
        let concernsForInput = combinedConcerns()

        guard let input = PlannerInput.build(
            modelContext: modelContext,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concernsForInput,
            healthContext: healthContext,
            recentActivities: activities,
            now: Date()
        ) else {
            isLoadingRecommendation = false
            isGenerating = false
            return false
        }

        let reason = Self.escalationReason(input: input)
        print("[BenLift/Coach] planForToday target=\(input.targetMuscle) source=\(input.targetMuscleSource) reason=\(reason)")

        do {
            let model = ClaudeModel.current
            // Stream the v5 call so the UI can advance phase indicators
            // (reasoning → drafting → ready) during the wait instead of
            // showing a generic spinner the whole time. The `.complete`
            // event carries the parsed response — we hold it in a local
            // and use it after the stream ends.
            var v5: DailyPlanV5Response?
            let stream = coachService.streamDailyPlanV5(input: input, model: model)
            for try await event in stream {
                switch event {
                case .thinking:  planForTodayPhase = .reasoning
                case .drafting:  planForTodayPhase = .drafting
                case .complete(let response): v5 = response
                }
            }
            guard let v5 else {
                throw ClaudeError.malformedResponse("dailyPlanV5 stream ended without .complete")
            }
            let plan = Self.convertV5ToPlan(v5)
            let rec = Self.synthesizeRecommendation(input: input, narrative: v5.recommendation, escalated: true, reason: reason)
            applyGeneratedPlan(plan, rec: rec, input: input, modelContext: modelContext)
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] planForToday cancelled (superseded)")
            } else {
                // Claude is the default path now — this only runs when the
                // call itself fails (offline, API down, malformed stream).
                // Fall back to the deterministic planner so there's still a
                // plan on screen instead of a dead end.
                print("[BenLift/Coach] ❌ planForToday failed, falling back to offline planner: \(error)")
                let library = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
                let plan = BaselinePlanner.plan(input: input, library: library)
                let rec = Self.synthesizeRecommendation(input: input, narrative: nil, escalated: false, reason: reason)
                applyGeneratedPlan(plan, rec: rec, input: input, modelContext: modelContext)
                planError = "Couldn't reach Claude, used the offline planner instead — \(error.localizedDescription)"
            }
        }

        planForTodayPhase = nil
        isLoadingRecommendation = false
        isGenerating = false
        return true
    }

    /// Commits a generated plan (from either the LLM or the offline
    /// fallback) to view-model state. Shared by both branches of
    /// `planForToday` so the snapshot/overrides/conflict-detection
    /// bookkeeping only lives in one place.
    @MainActor
    private func applyGeneratedPlan(
        _ plan: DailyPlanResponse,
        rec: RecoveryRecommendation,
        input: PlannerInput,
        modelContext: ModelContext
    ) {
        currentPlan = plan
        editedExercises = plan.exercises
        recommendation = rec
        targetMuscleGroups = input.targetMuscles.compactMap { MuscleGroup(rawValue: $0) }
        currentSessionName = rec.recommendedSessionName

        // Concerns were one-shot intent — once absorbed into this plan
        // they're stale. Clear before snapshotting so `isPlanStale`
        // measures against the post-consumption state (same dance as
        // getRecommendationAndPlan / generatePlan).
        concerns = ""
        planInputSnapshot = currentInputSnapshot()
        // Overrides have now been absorbed into the plan — clear them
        // so tomorrow's plan isn't silently double-applying today's
        // "chest sore" report.
        clearAllMuscleOverrides()

        markGenerated(modelContext: modelContext)

        // Detect future-pin overlap. If today's plan exercises hit a
        // muscle the user pinned for tomorrow / day after, surface it
        // via a pill so they can opt in to redistributing volume.
        futureConflicts = Self.detectFutureConflicts(
            plan: plan,
            input: input,
            modelContext: modelContext
        )

        // Detect recovery-overlap pattern across the 5-day window.
        // This is a different signal than future-pin overlap: it fires
        // when ANY single muscle (today's target included) shows up 3+
        // times in 5 days, regardless of whether today's plan hits it
        // directly. Same UX shape (pill + iterate adjust) but different
        // intent — coaching the user about consecutive-day load, not
        // about today's specific exercise selection.
        recoveryOverlap = Self.detectRecoveryOverlap(
            input: input,
            modelContext: modelContext
        )
    }

    /// True when yesterday's logged session's primary muscle appears in
    /// today's `targetMuscles`. Recovery for hypertrophy is canonically
    /// 48–72h same-muscle; back-to-back same-muscle days warrant the
    /// LLM's volume / intensity adaptation that the deterministic path
    /// skips.
    private static func sameMuscleAsYesterday(_ input: PlannerInput) -> Bool {
        guard let lastDay = input.recentDays.last else { return false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        guard let yesterdayDate = f.date(from: lastDay.date) else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let delta = cal.dateComponents([.day], from: cal.startOfDay(for: yesterdayDate), to: today).day ?? 99
        return delta == 1 && input.targetMuscles.contains(lastDay.muscle)
    }

    /// Human-readable trigger label for logs / analytics. "routine" when
    /// no escalation condition fired.
    private static func escalationReason(input: PlannerInput) -> String {
        if let inj = input.constraints.injuries, !inj.isEmpty { return "injury" }
        if input.recovery.feeling <= 2 { return "low_feeling" }
        let lowSleep = (input.recovery.sleepHours ?? 8.0) < 6.0
        let lowHRV = (input.recovery.hrv ?? 100) < 40
        if lowSleep && lowHRV { return "low_hrv_sleep" }
        if input.rituals.isEmpty && input.strength.count < 3 { return "cold_start" }
        if sameMuscleAsYesterday(input) { return "same_muscle_yesterday" }
        return "routine"
    }

    /// Scan today's plan against PlannerInput.futurePins (next 2 days). A
    /// conflict fires when an exercise in the plan maps to a muscle that's
    /// also pinned for tomorrow or the day after. Skipped when today's
    /// source is "pinned" — if the user explicitly pinned both today and
    /// tomorrow with overlapping muscles, that's intent, not a mistake.
    @MainActor
    private static func detectFutureConflicts(
        plan: DailyPlanResponse,
        input: PlannerInput,
        modelContext: ModelContext
    ) -> [FutureConflict] {
        guard input.targetMuscleSource != "pinned" else { return [] }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let isoDay = ISO8601DateFormatter()
        isoDay.formatOptions = [.withFullDate]

        // Build the lookup once — exercise name → primary muscle.
        let exercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let lookup = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name, $0.muscleGroup) })

        // Set of muscles today's plan hits (primary mover only — incidental
        // synergists are ignored to keep the signal tight).
        let planMuscles: Set<MuscleGroup> = Set(plan.exercises.compactMap { lookup[$0.name] })

        var conflicts: [FutureConflict] = []
        for pin in input.futurePins {
            guard let pinDate = isoDay.date(from: pin.date) else { continue }
            let daysOut = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: pinDate)).day ?? 99
            guard daysOut >= 1, daysOut <= 2 else { continue }
            // Multi-muscle pin: emit one conflict per overlapping muscle.
            // The pill UI shows the first; the rest are still in the array
            // for richer surfacing later.
            let pinMuscles = pin.muscles.compactMap(MuscleGroup.init(rawValue:))
            for muscle in pinMuscles where planMuscles.contains(muscle) {
                conflicts.append(FutureConflict(muscle: muscle, date: pinDate, daysOut: daysOut))
            }
        }
        return conflicts
    }

    /// Look across the next 5 days (today + 4 future) and flag any muscle
    /// that's hit 3+ times. Counts pulled from MuscleGroupPin (any pin
    /// within the window) plus today's planned target muscles. The window
    /// is non-overlapping with the 1–2 day future-conflict pill — overlap
    /// surfaces a different concern (cumulative load vs. specific
    /// today-tomorrow conflict) so both can fire if they're both true.
    ///
    /// Returns nil when no muscle crosses the threshold OR when the only
    /// candidate has been dismissed this calendar week.
    @MainActor
    private static func detectRecoveryOverlap(
        input: PlannerInput,
        modelContext: ModelContext
    ) -> RecoveryOverlap? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let windowEnd = cal.date(byAdding: .day, value: 4, to: today) ?? today
        let isoDay = ISO8601DateFormatter()
        isoDay.formatOptions = [.withFullDate]

        // Today's targets count once toward each muscle in the list.
        var counts: [MuscleGroup: Int] = [:]
        for raw in input.targetMuscles {
            if let m = MuscleGroup(rawValue: raw) { counts[m, default: 0] += 1 }
        }

        // Future pins: each pin contributes its full muscle list.
        for pin in input.futurePins {
            guard let pinDate = isoDay.date(from: pin.date) else { continue }
            let day = cal.startOfDay(for: pinDate)
            guard day > today, day <= windowEnd else { continue }
            for raw in pin.muscles {
                if let m = MuscleGroup(rawValue: raw) { counts[m, default: 0] += 1 }
            }
        }

        // Threshold: 3+ hits in 5 days. The recovery literature lands at
        // 48–72h between heavy sessions for the same muscle; 3 in 5 days
        // is the borderline that's worth surfacing without being preachy.
        let threshold = 3
        let candidates = counts
            .filter { $0.value >= threshold }
            .sorted { $0.value > $1.value }

        for (muscle, hits) in candidates {
            if dismissedThisWeek(muscle: muscle) { continue }
            return RecoveryOverlap(muscle: muscle, hits: hits, windowDays: 5)
        }
        return nil
    }

    /// User tapped "Redistribute" on the recovery-overlap pill. Routes
    /// through iterate so the LLM does the actual rebalancing.
    @MainActor
    func adjustForRecoveryOverlap(modelContext: ModelContext) async {
        guard let overlap = recoveryOverlap else { return }
        isAdjustingForRecoveryOverlap = true
        let request = "I have \(overlap.muscle.displayName.lowercased()) showing up \(overlap.hits) times in the next 5 days. Reduce today's volume on \(overlap.muscle.displayName.lowercased()) and lean into less-fatigued muscles or movement variety so I don't burn that muscle out across the week."
        await iterate(request: request, modelContext: modelContext)
        recoveryOverlap = nil
        isAdjustingForRecoveryOverlap = false
    }

    /// User tapped "I'll keep it" — record a per-week dismissal so the
    /// pill doesn't reappear every app open. Resets when the calendar
    /// week rolls over.
    @MainActor
    func dismissRecoveryOverlap() {
        guard let overlap = recoveryOverlap else { return }
        Self.recordDismissal(muscle: overlap.muscle)
        recoveryOverlap = nil
    }

    /// User tapped the future-conflict pill. Routes through iterate so the
    /// LLM does the actual volume redistribution — much smarter than any
    /// fixed rule we'd write here. Templated request includes which muscle
    /// is pinned and how soon, so the model knows the constraint.
    @MainActor
    func adjustForFutureConflict(modelContext: ModelContext) async {
        guard let conflict = futureConflicts.first else { return }
        isAdjustingForConflict = true
        let when = conflict.daysOut == 1 ? "tomorrow" : "in \(conflict.daysOut) days"
        let request = "I have \(conflict.muscle.displayName.lowercased()) pinned for \(when). Redistribute today's volume so I save stimulus for that day — keep the work that doesn't overlap, lighten or swap what does."
        await iterate(request: request, modelContext: modelContext)
        // Clear the conflict — iterate either resolved it or surfaced an
        // error in iterateError. Either way the pill should retire.
        futureConflicts = []
        isAdjustingForConflict = false
    }

    /// Map v5 plan response → user-facing DailyPlanResponse. Drops the
    /// audit-only weightAnchor + selfCheck fields — they're useful for
    /// debugging and evals but not displayed on Today.
    private static func convertV5ToPlan(_ v5: DailyPlanV5Response) -> DailyPlanResponse {
        DailyPlanResponse(
            exercises: v5.exercises.map { plannedFromV5($0, fallbackRepScheme: nil) },
            sessionStrategy: v5.strategy,
            estimatedDuration: v5.estimatedDuration,
            deloadNote: v5.deloadNote
        )
    }

    /// The new prompts don't return a RecoveryRecommendation (the calendar
    /// owns that decision now). We synthesize one for the existing UI's
    /// header. Reasoning text comes from the v5 `recommendation` field
    /// when escalated; for routine days, we write a one-liner that names
    /// the muscle(s) and source (pattern vs pin vs cold-start fallback).
    ///
    /// Naming logic:
    /// - Matches a canonical preset → "Push Day" / "Pull Day" / "Legs Day"
    /// - 2 muscles → "Chest + Shoulders Day"
    /// - 3+ muscles (no preset) → "Chest + 2" headline keeps it compact
    /// - 1 muscle → "Chest Day"
    private static func synthesizeRecommendation(
        input: PlannerInput,
        narrative: String?,
        escalated: Bool,
        reason: String
    ) -> RecoveryRecommendation {
        let muscles = input.targetMuscles.compactMap { MuscleGroup(rawValue: $0) }
        let displayName = sessionDisplayName(for: muscles)

        let reasoning: String
        if let n = narrative, !n.isEmpty {
            reasoning = n
        } else {
            let lower = displayName.lowercased()
            switch input.targetMuscleSource {
            case "pinned":     reasoning = "Pinned: \(lower) today."
            case "predicted":  reasoning = "Based on your typical pattern, today's a \(lower) day."
            default:           reasoning = "Today's focus: \(lower)."
            }
        }
        return RecoveryRecommendation(
            muscleGroupStatus: [],
            recommendedFocus: input.targetMuscles,
            recommendedSessionName: "\(displayName) Day",
            reasoning: reasoning
        )
    }

    /// Best-fit name for the session header — same logic the deterministic
    /// baseline planner uses internally, kept duplicated to avoid having
    /// the VM depend on BaselinePlanner internals (these may diverge later
    /// if the LLM wants different wording).
    private static func sessionDisplayName(for muscles: [MuscleGroup]) -> String {
        guard let primary = muscles.first else { return "Workout" }
        let s = Set(muscles)
        if s == Set([.chest, .shoulders, .triceps]) { return "Push" }
        if s == Set([.back, .biceps]) { return "Pull" }
        if s == Set([.quads, .hamstrings, .glutes, .calves]) { return "Legs" }
        if s == Set([.chest, .back, .shoulders, .biceps, .triceps]) { return "Upper" }
        if muscles.count == 2 { return "\(muscles[0].displayName) + \(muscles[1].displayName)" }
        if muscles.count >= 3 { return "\(primary.displayName) +\(muscles.count - 1)" }
        return primary.displayName
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

        let model = ClaudeModel.current
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

    // MARK: - Iterate (general plan customization)
    //
    // Routes a freeform user request ("prioritize pull-ups", "lighten
    // bench, shoulder feels tight", "why is squat first?") through the
    // iterate prompt, which returns either a structured plan edit or a
    // conversational explanation. Distinct from quickSwap, which is the
    // per-row "replace this exercise" flow.

    /// Run an iterate request against the current plan. Updates VM state
    /// for the sheet to read: `isIterating` while in-flight,
    /// `iterateLastResult` on success (edit applied + explainer cached),
    /// `iterateError` on failure.
    @MainActor
    func iterate(request: String, modelContext: ModelContext) async {
        guard let plan = currentPlan else {
            iterateError = "No active plan to iterate on."
            return
        }
        // Pull HealthKit recovery + recent activities before building
        // PlannerInput so the iterate prompt sees the same readiness
        // context the v5 daily-plan call would. We don't need to be
        // surgical here — iterate is a cheap call.
        let healthContext = await HealthKitService.shared.fetchHealthContext()
        let activities = await HealthKitService.shared.fetchRecentActivities(days: 7)
        // PlannerInput.build expects PatternEngine.ActivityRecord — the
        // same type fetchRecentActivities returns, so this is a direct
        // pass-through.
        guard let plannerInput = PlannerInput.build(
            modelContext: modelContext,
            feeling: feeling,
            availableTime: availableTime,
            concerns: combinedConcerns(),
            healthContext: healthContext,
            recentActivities: activities,
            now: Date()
        ) else {
            iterateError = "Couldn't build planner context for this request."
            return
        }

        isIterating = true
        iterateError = nil
        defer { isIterating = false }

        let model = ClaudeModel.current
        print("[BenLift/Coach] iterate request: \"\(request)\"")

        do {
            let response = try await coachService.iterate(
                currentPlan: plan,
                userRequest: request,
                plannerInput: plannerInput,
                model: model
            )
            switch response {
            case .edit(let edit):
                applyIterateEdits(edit.edits)
                planAdjustments.append(AdjustmentRecord(
                    kind: .swap,
                    summary: "Iterate (\(edit.editKind)): \(edit.rationale.prefix(80))"
                ))
                persistCachedGeneration()
                iterateLastResult = .edit(edit)
                print("[BenLift/Coach] ✅ iterate applied \(edit.edits.count) edit(s) — \(edit.editKind)")
            case .explain(let explain):
                iterateLastResult = .explain(explain)
                print("[BenLift/Coach] ✅ iterate explanation returned (\(explain.answer.count) chars)")
            }
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] iterate cancelled")
            } else {
                print("[BenLift/Coach] ❌ iterate failed: \(error)")
                iterateError = error.localizedDescription
            }
        }
    }

    /// Apply the structured edits from an `IterateEdit` to `editedExercises`
    /// and rebuild `currentPlan`. PlannedExerciseV5 → PlannedExercise: most
    /// fields map directly; weightAnchor is audit trail and dropped,
    /// evidenceNote carries through (feeds the muscle-group TL;DR).
    @MainActor
    private func applyIterateEdits(_ edits: [PlanEdit]) {
        for edit in edits {
            switch edit.action {
            case "replace", "modify":
                guard let target = edit.targetExerciseName,
                      let v5 = edit.newExercise,
                      let idx = editedExercises.firstIndex(where: { $0.name == target })
                else { continue }
                // Keep the user's original repScheme on replace if the LLM
                // didn't re-emit one — same defensiveness as quickSwap.
                let original = editedExercises[idx]
                editedExercises[idx] = pickStartingWeight(
                    Self.plannedFromV5(v5, fallbackRepScheme: original.repScheme)
                )

            case "insert":
                guard let v5 = edit.newExercise else { continue }
                editedExercises.append(pickStartingWeight(
                    Self.plannedFromV5(v5, fallbackRepScheme: nil)
                ))

            case "delete":
                guard let target = edit.targetExerciseName else { continue }
                editedExercises.removeAll { $0.name == target }

            default:
                print("[BenLift/Coach] iterate: unknown edit action \"\(edit.action)\" — ignored")
            }
        }
        // Rebuild currentPlan with the mutated exercise list. Strategy /
        // duration / deloadNote are unchanged by an iterate edit — they
        // belong to the parent plan, not the per-exercise edits.
        if let plan = currentPlan {
            currentPlan = DailyPlanResponse(
                exercises: editedExercises,
                sessionStrategy: plan.sessionStrategy,
                estimatedDuration: plan.estimatedDuration,
                deloadNote: plan.deloadNote
            )
        }
    }

    /// Map the v5 schema's exercise into the user-facing PlannedExercise.
    /// Drops weightAnchor (audit-only); evidenceNote carries through. intent
    /// is non-optional in v5 but optional in PlannedExercise — pass through.
    private static func plannedFromV5(
        _ v5: PlannedExerciseV5,
        fallbackRepScheme: String?
    ) -> PlannedExercise {
        PlannedExercise(
            name: v5.name,
            sets: v5.sets,
            targetReps: v5.targetReps,
            suggestedWeight: v5.suggestedWeight,
            repScheme: fallbackRepScheme,
            warmupSets: v5.warmupSets,
            notes: v5.notes,
            intent: v5.intent,
            evidenceNote: v5.evidenceNote
        )
    }

    // MARK: - Recommendation Cache

    private var lastGeneratedSessionCount: Int?
    private var lastGeneratedDate: Date?

    /// Returns true if we should skip regeneration (nothing changed since last call).
    ///
    /// Narrow on purpose — a short window guards against duplicate calls
    /// from rapid re-renders (e.g. `onAppear` firing more than once), not
    /// against calling Claude again. With every plan going through
    /// daily_plan_v5, reopening the app later in the day should always get
    /// a fresh read against whatever HealthKit has synced since (sleep/HRV
    /// often land mid-morning) — a same-day cache would silently plan
    /// against stale recovery data instead.
    @MainActor
    func shouldSkipRegeneration(modelContext: ModelContext) -> Bool {
        guard recommendation != nil, !editedExercises.isEmpty else { return false }
        guard let cachedCount = lastGeneratedSessionCount,
              let cachedDate = lastGeneratedDate else { return false }

        let isRecent = Date().timeIntervalSince(cachedDate) < 300 // 5 minutes
        let currentCount = (try? modelContext.fetchCount(FetchDescriptor<WorkoutSession>())) ?? 0

        return isRecent && currentCount == cachedCount
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
        planInputSnapshot = currentInputSnapshot()
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
