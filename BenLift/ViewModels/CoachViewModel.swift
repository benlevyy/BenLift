import SwiftUI
import SwiftData

@Observable
class CoachViewModel {
    var selectedCategory: WorkoutCategory?
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

    var daysSinceLast: [WorkoutCategory: Int] = [:]

    /// Cached plans per category — survives switching between tabs
    private var savedPlans: [WorkoutCategory: (plan: DailyPlanResponse?, exercises: [PlannedExercise])] = [:]

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
        loadCachedGeneration()
    }

    @MainActor
    func calculateDaysSinceLast(modelContext: ModelContext) {
        for category in WorkoutCategory.allCases {
            var descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate<WorkoutSession> { session in session.category == category },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 1

            if let sessions = try? modelContext.fetch(descriptor),
               let last = sessions.first {
                daysSinceLast[category] = Date().daysSince(last.date)
            } else {
                daysSinceLast[category] = nil
            }
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

        // Load weight cache + build library + weekly volume from SwiftData.
        loadAllLastWeights(modelContext: modelContext)
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

        let (system, user) = PromptBuilder.recommendAndPlanPrompt(
            recentSessionsSummary: recentSummary,
            recentActivities: activitiesText,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns.isEmpty ? nil : concerns,
            exerciseLibrary: library,
            weeklyVolumeProgress: volumeProgress,
            program: program,
            healthContext: healthContext,
            intelligence: intelligence
        )

        // Single Haiku call replaces the prior Sonnet→Haiku pipeline.
        let model = UserDefaults.standard.string(forKey: "modelDailyPlan") ?? "claude-haiku-4-5"
        print("[BenLift/Coach] recommendAndPlan: feeling=\(feeling), model=\(model)")

        do {
            let response = try await coachService.recommendAndPlan(
                systemPrompt: system,
                userPrompt: user,
                model: model
            )

            // Populate both halves of the view model atomically.
            recommendation = response.asRecommendation
            targetMuscleGroups = response.recommendedFocus.compactMap { MuscleGroup(rawValue: $0) }
            currentSessionName = response.recommendedSessionName

            let plan = response.asPlan
            currentPlan = plan

            // Fill suggested weights from history for any exercises returned as 0/nil.
            editedExercises = plan.exercises.map { exercise in
                if exercise.weight <= 0, let histWeight = _weightCache[exercise.name], histWeight > 0 {
                    return PlannedExercise(
                        name: exercise.name, sets: exercise.sets, targetReps: exercise.targetReps,
                        suggestedWeight: histWeight, repScheme: exercise.repScheme,
                        warmupSets: exercise.warmupSets, notes: exercise.notes, intent: exercise.intent
                    )
                }
                return exercise
            }

            // Fresh plan → fresh adjustment history.
            planAdjustments = []

            if selectedCategory != nil { savePlanForCurrentCategory() }
            markGenerated(modelContext: modelContext)
            print("[BenLift/Coach] ✅ recommendAndPlan: \(response.recommendedSessionName) — \(editedExercises.count) exercises")
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] recommendAndPlan cancelled (superseded by reload)")
            } else {
                print("[BenLift/Coach] ❌ recommendAndPlan failed: \(error)")
                planError = "Couldn't generate today's plan: \(error.localizedDescription)"
                // Legacy fallback to default template if a category is selected.
                if let cat = selectedCategory {
                    loadDefaultTemplate(category: cat, modelContext: modelContext)
                }
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

        // Load last weights from history so Claude can reference them
        loadAllLastWeights(modelContext: modelContext)

        let healthContext = await HealthKitService.shared.fetchHealthContext()

        // Use category if set (legacy PPL), otherwise use target muscle groups
        let category = selectedCategory
        let (system, user) = ContextBuilder.buildDailyPlanContext(
            category: category,
            targetMuscleGroups: targetMuscleGroups,
            sessionName: currentSessionName,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns.isEmpty ? nil : concerns,
            modelContext: modelContext,
            program: program,
            healthContext: healthContext
        )

        let model = UserDefaults.standard.string(forKey: "modelDailyPlan") ?? "claude-haiku-4-5"

        print("[BenLift/Coach] Generating plan for \(currentSessionName ?? category?.displayName ?? "Custom"), feeling=\(feeling), time=\(availableTime.map { "\($0)min" } ?? "unset")")

        do {
            let plan = try await coachService.generateDailyPlan(systemPrompt: system, userPrompt: user, model: model)
            currentPlan = plan
            // New plan => fresh adjustment history
            planAdjustments = []
            // Fill in weights from history for any exercises Claude returned as 0/null
            editedExercises = plan.exercises.map { exercise in
                if exercise.weight <= 0, let histWeight = _weightCache[exercise.name], histWeight > 0 {
                    return PlannedExercise(
                        name: exercise.name, sets: exercise.sets, targetReps: exercise.targetReps,
                        suggestedWeight: histWeight, repScheme: exercise.repScheme,
                        warmupSets: exercise.warmupSets, notes: exercise.notes, intent: exercise.intent
                    )
                }
                return exercise
            }
            if let cat = category { savePlanForCurrentCategory() }
            print("[BenLift/Coach] ✅ Plan generated: \(editedExercises.count) exercises")
        } catch {
            if Self.isCancellation(error) {
                print("[BenLift/Coach] Plan generation cancelled (superseded by reload)")
            } else {
                print("[BenLift/Coach] ❌ Plan generation failed: \(error)")
                planError = error.localizedDescription
                if let cat = category {
                    loadDefaultTemplate(category: cat, modelContext: modelContext)
                }
            }
        }

        isGenerating = false
    }

    /// Evidence-based default templates: 5 exercises per session
    /// Based on Israetel (RP), Helms, Schoenfeld research (2023-2025)
    /// Primary compound: 3-4 x 5-8 @ 2-3 RIR
    /// Secondary compound: 3 x 8-12 @ 1-2 RIR
    /// Isolation: 2-3 x 10-15 @ 0-1 RIR
    @MainActor
    func loadDefaultTemplate(category: WorkoutCategory, modelContext: ModelContext) {
        let pool = DefaultExercises.exercises(for: category)
        let corePool = DefaultExercises.core

        switch category {
        case .push:
            // Chest (6 sets) + Side delts (3 sets) + Triceps (3 direct + overlap) + Core
            editedExercises = [
                exercise("Bench Press", from: pool, sets: 3, reps: "6-8", intent: "primary compound", warmup: true),
                exercise("DB Incline Press", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("DB Shoulder Press", from: pool, sets: 3, reps: "8-10", intent: "secondary compound"),
                exercise("Lateral Raises", from: pool, sets: 3, reps: "12-15", intent: "isolation"),
                exercise("Tricep Overhead Extension", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
                exercise("Hanging Leg Raise", from: corePool, sets: 3, reps: "10-15", intent: "finisher"),
            ]

        case .pull:
            // Back (9 sets) + Rear delts (2-3 sets) + Biceps (2-3 direct, reduced for bouldering) + Core
            editedExercises = [
                exercise("Pull-ups", from: pool, sets: 3, reps: "6-10", intent: "primary compound"),
                exercise("Chest Supported Row", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Seated Row", from: pool, sets: 3, reps: "10-12", intent: "secondary compound"),
                exercise("Face Pulls", from: pool, sets: 3, reps: "12-15", intent: "isolation"),
                exercise("Incline Hammer Curl", from: pool, sets: 2, reps: "10-15", intent: "isolation"),
                exercise("Pallof Press", from: corePool, sets: 3, reps: "10-12", intent: "finisher"),
            ]

        case .legs:
            // Quads (6-7 sets) + Hamstrings (6 sets) + Core
            editedExercises = [
                exercise("Squat", from: pool, sets: 3, reps: "5-8", intent: "primary compound", warmup: true),
                exercise("Romanian Deadlift", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Split Squat", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Hamstring Curl", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
                exercise("Leg Extension", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
                exercise("Plank", from: corePool, sets: 3, reps: "30-60s", intent: "finisher"),
            ]
        }

        print("[BenLift/Coach] Loaded default \(category.displayName) template: \(editedExercises.count) exercises (~\(editedExercises.reduce(0) { $0 + $1.sets }) working sets)")
    }

    /// Build a PlannedExercise, using last session's weight if available, else default.
    private func exercise(
        _ name: String,
        from pool: [DefaultExercises.ExerciseDef],
        sets: Int,
        reps: String,
        intent: String,
        warmup: Bool = false
    ) -> PlannedExercise {
        let def = pool.first(where: { $0.name == name })
        // Use last logged weight if we have history, otherwise default
        let weight = lastWeight(for: name) ?? def?.defaultWeight ?? 0
        return PlannedExercise(
            name: name,
            sets: sets,
            targetReps: reps,
            suggestedWeight: weight,
            repScheme: nil,
            warmupSets: warmup ? defaultWarmups(weight: weight, equipment: def?.equipment) : nil,
            notes: nil,
            intent: intent
        )
    }

    /// Look up the most recent working weight for an exercise from SwiftData history.
    private var _weightCache: [String: Double] = [:]

    @MainActor
    private func lastWeight(for exerciseName: String) -> Double? {
        if let cached = _weightCache[exerciseName] { return cached }
        // Can't query without modelContext — return nil, weights come from defaults
        // This gets populated when loadDefaultTemplate is called with modelContext
        return nil
    }

    /// Pre-load last weights from history for all exercises in a category.
    @MainActor
    func loadLastWeights(for category: WorkoutCategory, modelContext: ModelContext) {
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate<WorkoutSession> { session in session.category == category },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 3

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
        print("[BenLift/Coach] Loaded last weights for \(_weightCache.count) exercises")
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

    /// Only generate 1 warmup set for the first compound exercise. Keep it simple.
    private func defaultWarmups(weight: Double, equipment: Equipment?) -> [WarmupSet]? {
        guard weight >= 135, equipment == .barbell else { return nil }
        // Single warmup: ~50% of working weight
        return [
            WarmupSet(weight: round(weight * 0.5 / 5) * 5, reps: 5),
        ]
    }

    func removeExercise(at index: Int) {
        guard index < editedExercises.count else { return }
        editedExercises.remove(at: index)
    }

    func moveExercise(from source: IndexSet, to destination: Int) {
        editedExercises.move(fromOffsets: source, toOffset: destination)
    }

    /// Save current plan for this category before switching away
    func savePlanForCurrentCategory() {
        guard let category = selectedCategory, !editedExercises.isEmpty else { return }
        savedPlans[category] = (plan: currentPlan, exercises: editedExercises)
    }

    /// Try to restore a previously saved plan for a category
    func restorePlan(for category: WorkoutCategory) -> Bool {
        if let saved = savedPlans[category], !saved.exercises.isEmpty {
            currentPlan = saved.plan
            editedExercises = saved.exercises
            return true
        }
        return false
    }

    func resetPlan() {
        // Save before clearing so we can restore later
        savePlanForCurrentCategory()
        currentPlan = nil
        editedExercises = []
        selectedCategory = nil
        concerns = ""
        planError = nil
    }

    func clearPlanEntirely() {
        if let cat = selectedCategory { savedPlans.removeValue(forKey: cat) }
        currentPlan = nil
        editedExercises = []
        selectedCategory = nil
        concerns = ""
        planError = nil
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
                lastReps: nil
            )
        }
        let restTimer = UserDefaults.standard.double(forKey: "restTimerDuration")
        let increment = UserDefaults.standard.double(forKey: "weightIncrement")

        return WatchWorkoutPlan(
            sessionName: currentSessionName,
            muscleGroups: targetMuscleGroups.map(\.rawValue),
            category: selectedCategory,
            exercises: watchExercises,
            sessionStrategy: currentPlan?.sessionStrategy,
            restTimerDuration: restTimer > 0 ? restTimer : 150,
            weightIncrement: increment > 0 ? increment : 5.0
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
    }
}
