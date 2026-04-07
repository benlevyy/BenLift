import SwiftUI
import SwiftData

@Observable
class HistoryViewModel {

    @MainActor
    func fetchSessions(from context: ModelContext) -> [WorkoutSession] {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    func analysis(for session: WorkoutSession, from context: ModelContext) -> PostWorkoutAnalysis? {
        let sessionId = session.id
        let descriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return try? context.fetch(descriptor).first
    }

    @MainActor
    func exerciseHistory(name: String, from context: ModelContext) -> [(date: Date, topWeight: Double, topReps: Double, e1RM: Double)] {
        let sessions = fetchSessions(from: context)
        return sessions.compactMap { session in
            guard let entry = session.entries.first(where: { $0.exerciseName == name }) else { return nil }
            guard let top = StatsEngine.topSet(sets: entry.sets) else { return nil }
            let e1rm = StatsEngine.estimatedOneRepMax(weight: top.weight, reps: top.reps)
            return (date: session.date, topWeight: top.weight, topReps: top.reps, e1RM: e1rm)
        }
    }
}
