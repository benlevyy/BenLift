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

        let model = UserDefaults.standard.string(forKey: "modelPostAnalysis") ?? "claude-haiku-4-5-20251001"

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

        } catch {
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }
}
