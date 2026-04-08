import SwiftUI
import SwiftData

@Observable
class ProgramViewModel {
    var currentProgram: TrainingProgram?
    var isGenerating: Bool = false
    var error: String?

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
    }

    @MainActor
    func loadCurrentProgram(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        currentProgram = try? modelContext.fetch(descriptor).first
    }

    @MainActor
    func generateProgram(
        goal: TrainingGoal,
        specificTargets: String?,
        daysPerWeek: Int,
        experience: ExperienceLevel,
        injuries: String?,
        equipment: EquipmentAccess,
        modelContext: ModelContext
    ) async {
        isGenerating = true
        error = nil

        let (system, user) = PromptBuilder.goalSettingPrompt(
            goal: goal,
            specificTargets: specificTargets,
            daysPerWeek: daysPerWeek,
            experience: experience,
            injuries: injuries,
            equipment: equipment
        )

        let model = UserDefaults.standard.string(forKey: "modelGoalSetting") ?? "claude-haiku-4-5"

        print("[BenLift/Program] Generating program: goal=\(goal.displayName), days=\(daysPerWeek), exp=\(experience.displayName), model=\(model)")

        do {
            let response = try await coachService.generateProgram(systemPrompt: system, userPrompt: user, model: model)
            print("[BenLift/Program] ✅ Program received: \(response.program.name)")

            // Deactivate existing programs
            let existing = FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.isActive == true })
            if let programs = try? modelContext.fetch(existing) {
                for p in programs { p.isActive = false }
            }

            // Create new program
            let program = TrainingProgram(
                name: response.program.name,
                goal: goal.displayName,
                specificTargets: specificTargets,
                experienceLevel: experience.rawValue,
                daysPerWeek: daysPerWeek,
                periodization: response.program.periodization,
                deloadFrequency: response.program.deloadFrequency
            )
            program.split = response.program.split
            program.weeklyVolumeTargets = response.program.weeklyVolumeTargets
            program.compoundPriority = response.program.compoundPriority
            program.progressionScheme = response.program.progressionScheme

            modelContext.insert(program)
            try? modelContext.save()
            currentProgram = program

        } catch {
            print("[BenLift/Program] ❌ Program generation failed: \(error)")
            self.error = error.localizedDescription
        }

        isGenerating = false
    }

    func todaysSuggestedCategory() -> WorkoutCategory? {
        currentProgram?.todayCategory()
    }

    @MainActor
    func currentWeekStatus(modelContext: ModelContext) -> (completed: Int, planned: Int) {
        let planned = currentProgram?.daysPerWeek ?? 0
        let weekStart = Date().startOfWeek
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= weekStart }
        )
        let completed = (try? modelContext.fetchCount(descriptor)) ?? 0
        return (completed, planned)
    }
}
