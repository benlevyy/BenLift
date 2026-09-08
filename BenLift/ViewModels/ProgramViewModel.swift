import SwiftUI
import SwiftData

@Observable
class ProgramViewModel {
    var currentProgram: TrainingProgram?

    @MainActor
    func loadCurrentProgram(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        currentProgram = try? modelContext.fetch(descriptor).first
    }

    /// Create the single program row that holds `goalText`. The old
    /// version asked Claude to design a split, periodisation scheme and
    /// per-muscle volume targets at signup — none of which the resolver
    /// reads. Rotation plus replay does that job, so this is now local.
    @MainActor
    func ensureProgram(goalText: String = "", modelContext: ModelContext) {
        loadCurrentProgram(modelContext: modelContext)
        if let currentProgram {
            if !goalText.isEmpty { currentProgram.goalText = goalText }
        } else {
            let program = TrainingProgram(name: "Training", goal: "")
            program.goalText = goalText
            modelContext.insert(program)
            currentProgram = program
        }
        try? modelContext.save()
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
