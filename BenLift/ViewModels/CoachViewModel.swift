import SwiftUI
import SwiftData

@Observable
class CoachViewModel {
    var selectedCategory: WorkoutCategory?
    var feeling: Int = 3
    var availableTime: Int = 60
    var concerns: String = ""

    var currentPlan: DailyPlanResponse?
    var editedExercises: [PlannedExercise] = []
    var isGenerating: Bool = false
    var planError: String?

    var daysSinceLast: [WorkoutCategory: Int] = [:]

    /// Cached plans per category — survives switching between tabs
    private var savedPlans: [WorkoutCategory: (plan: DailyPlanResponse?, exercises: [PlannedExercise])] = [:]

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
    }

    @MainActor
    func calculateDaysSinceLast(modelContext: ModelContext) {
        for category in WorkoutCategory.allCases {
            var descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.category == category },
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

    @MainActor
    func generatePlan(modelContext: ModelContext, program: TrainingProgram?) async {
        guard let category = selectedCategory else { return }

        isGenerating = true
        planError = nil

        let healthContext = await HealthKitService.shared.fetchHealthContext()

        let (system, user) = ContextBuilder.buildDailyPlanContext(
            category: category,
            feeling: feeling,
            availableTime: availableTime,
            concerns: concerns.isEmpty ? nil : concerns,
            modelContext: modelContext,
            program: program,
            healthContext: healthContext
        )

        let model = UserDefaults.standard.string(forKey: "modelDailyPlan") ?? "claude-haiku-4-5-20251001"

        print("[BenLift/Coach] Generating plan for \(category.displayName), feeling=\(feeling), time=\(availableTime)min, model=\(model)")
        print("[BenLift/Coach] Health context: sleep=\(healthContext.sleepHours.map { String(format: "%.1f", $0) } ?? "nil")h, rhr=\(healthContext.restingHR.map { "\(Int($0))" } ?? "nil")bpm")

        do {
            let plan = try await coachService.generateDailyPlan(systemPrompt: system, userPrompt: user, model: model)
            currentPlan = plan
            editedExercises = plan.exercises
            savePlanForCurrentCategory()
            print("[BenLift/Coach] ✅ Plan generated: \(plan.exercises.count) exercises")
        } catch {
            print("[BenLift/Coach] ❌ Plan generation failed: \(error)")
            planError = error.localizedDescription
            loadDefaultTemplate(category: category, modelContext: modelContext)
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
            predicate: #Predicate { $0.category == category },
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

    private func defaultWarmups(weight: Double, equipment: Equipment?) -> [WarmupSet]? {
        guard weight >= 95, equipment == .barbell else { return nil }
        return [
            WarmupSet(weight: 45, reps: 10),
            WarmupSet(weight: round(weight * 0.6 / 5) * 5, reps: 5),
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
        guard let category = selectedCategory else { return nil }
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
            category: category,
            exercises: watchExercises,
            sessionStrategy: currentPlan?.sessionStrategy,
            restTimerDuration: restTimer > 0 ? restTimer : 150,
            weightIncrement: increment > 0 ? increment : 5.0
        )
    }
}
