import SwiftUI
import SwiftData

@Observable
class AnalysisViewModel {
    var currentAnalysis: PostWorkoutAnalysis?
    var isAnalyzing: Bool = false
    var analysisError: String?

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
    }

    @MainActor
    func analyzeWorkout(
        session: WorkoutSession,
        planSummary: String?,
        modelContext: ModelContext,
        program: TrainingProgram?,
        healthContext: HealthContext?
    ) async {
        isAnalyzing = true
        analysisError = nil

        let (system, user) = ContextBuilder.buildPostWorkoutContext(
            session: session,
            planSummary: planSummary,
            modelContext: modelContext,
            program: program,
            healthContext: healthContext
        )

        let model = UserDefaults.standard.string(forKey: "modelPostAnalysis") ?? "claude-haiku-4-5"

        do {
            let response = try await coachService.analyzePostWorkout(systemPrompt: system, userPrompt: user, model: model)

            let analysis = PostWorkoutAnalysis(
                sessionId: session.id,
                summary: response.summary,
                overallRating: OverallRating(rawValue: response.overallRating) ?? .average,
                recoveryNotes: response.recoveryNotes,
                coachNote: response.coachNote
            )
            analysis.progressionEvents = response.progressionEvents
            if let volumeAnalysis = response.volumeAnalysis {
                analysis.volumeAnalysis = volumeAnalysis
            }

            modelContext.insert(analysis)
            try? modelContext.save()
            currentAnalysis = analysis

            // Append observations to intelligence for next refresh
            if let observations = response.observations, !observations.isEmpty {
                appendObservations(observations, modelContext: modelContext)
            }

        } catch {
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }

    // MARK: - Intelligence Observations

    @MainActor
    private func appendObservations(_ observations: [String], modelContext: ModelContext) {
        let descriptor = FetchDescriptor<UserIntelligence>()
        let intel: UserIntelligence
        if let existing = try? modelContext.fetch(descriptor).first {
            intel = existing
        } else {
            intel = UserIntelligence()
            modelContext.insert(intel)
        }

        let newText = observations.map { "• \($0)" }.joined(separator: "\n")
        if intel.pendingObservations.isEmpty {
            intel.pendingObservations = newText
        } else {
            intel.pendingObservations += "\n" + newText
        }
        intel.workoutsSinceRefresh += 1
        try? modelContext.save()

        print("[BenLift/Intel] Observations appended: \(observations.count) items, \(intel.workoutsSinceRefresh) workouts since refresh")
    }
}
