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

        switch category {
        case .push:
            // Chest (6 sets) + Side delts (3 sets) + Triceps (3 direct + overlap)
            editedExercises = [
                exercise("Bench Press", from: pool, sets: 3, reps: "6-8", intent: "primary compound", warmup: true),
                exercise("DB Incline Press", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("DB Shoulder Press", from: pool, sets: 3, reps: "8-10", intent: "secondary compound"),
                exercise("Lateral Raises", from: pool, sets: 3, reps: "12-15", intent: "isolation"),
                exercise("Tricep Overhead Extension", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
            ]

        case .pull:
            // Back (9 sets) + Rear delts (2-3 sets) + Biceps (2-3 direct, reduced for bouldering)
            editedExercises = [
                exercise("Pull-ups", from: pool, sets: 3, reps: "6-10", intent: "primary compound"),
                exercise("Chest Supported Row", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Seated Row", from: pool, sets: 3, reps: "10-12", intent: "secondary compound"),
                exercise("Face Pulls", from: pool, sets: 3, reps: "12-15", intent: "isolation"),
                exercise("Incline Hammer Curl", from: pool, sets: 2, reps: "10-15", intent: "isolation"),
            ]

        case .legs:
            // Quads (6-7 sets) + Hamstrings (6 sets) + optional calves
            // Alternates squat / hack squat as primary — AI will rotate these
            editedExercises = [
                exercise("Squat", from: pool, sets: 3, reps: "5-8", intent: "primary compound", warmup: true),
                exercise("Romanian Deadlift", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Split Squat", from: pool, sets: 3, reps: "8-12", intent: "secondary compound"),
                exercise("Hamstring Curl", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
                exercise("Leg Extension", from: pool, sets: 3, reps: "10-15", intent: "isolation"),
            ]
        }

        print("[BenLift/Coach] Loaded default \(category.displayName) template: \(editedExercises.count) exercises (~\(editedExercises.reduce(0) { $0 + $1.sets }) working sets)")
    }

    private func exercise(
        _ name: String,
        from pool: [DefaultExercises.ExerciseDef],
        sets: Int,
        reps: String,
        intent: String,
        warmup: Bool = false
    ) -> PlannedExercise {
        let def = pool.first(where: { $0.name == name })
        let weight = def?.defaultWeight ?? 0
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

    func resetPlan() {
        currentPlan = nil
        editedExercises = []
        selectedCategory = nil
        feeling = 3
        availableTime = 60
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
                suggestedWeight: exercise.suggestedWeight,
                warmupSets: exercise.warmupSets,
                notes: exercise.notes,
                intent: exercise.intent,
                lastWeight: nil,
                lastReps: nil
            )
        }
        return WatchWorkoutPlan(
            category: category,
            exercises: watchExercises,
            sessionStrategy: currentPlan?.sessionStrategy
        )
    }
}
