import SwiftUI
import SwiftData

/// Plain value-type snapshot of an analysis. Held by `AnalysisViewModel` instead of
/// the SwiftData `@Model` directly — the @Model's backing data can be detached when
/// its model context goes out of scope, which crashes any subsequent property access.
struct AnalysisSnapshot {
    let id: UUID
    let summary: String
    let overallRating: OverallRating
    let recoveryNotes: String?
    let coachNote: String
    let progressionEvents: [ProgressionEvent]
    let volumeAnalysis: [String: VolumeAnalysisEntry]
}

@Observable
class AnalysisViewModel {
    var currentAnalysis: AnalysisSnapshot?
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

            // Hold a value-type snapshot, NOT the @Model — avoids backing-data
            // detachment crashes when the source context goes out of scope.
            currentAnalysis = AnalysisSnapshot(
                id: analysis.id,
                summary: analysis.summary,
                overallRating: analysis.overallRating,
                recoveryNotes: analysis.recoveryNotes,
                coachNote: analysis.coachNote,
                progressionEvents: analysis.progressionEvents,
                volumeAnalysis: analysis.volumeAnalysis
            )

            // Append observations to intelligence for next refresh. Pass
            // the analyzed session's id so we can de-duplicate re-analyses
            // — editing a session and re-analyzing shouldn't inflate the
            // "workouts since refresh" counter.
            if let observations = response.observations, !observations.isEmpty {
                appendObservations(
                    observations,
                    sessionId: session.id,
                    modelContext: modelContext
                )
            }

        } catch {
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }

    // MARK: - Intelligence Observations

    /// Cap pendingObservations at this many lines. Older lines get trimmed
    /// on append. Keeps the prompt-bound string bounded — without this,
    /// months of post-workout analyses could stack into a giant blob that
    /// bloats every plan request.
    private static let maxPendingObservationLines: Int = 20

    @MainActor
    private func appendObservations(
        _ observations: [String],
        sessionId: UUID,
        modelContext: ModelContext
    ) {
        // Dedup: if a PostWorkoutAnalysis for this session already exists
        // and predates this one, it was a re-analysis (user edited the
        // session in History). We already counted this session's
        // observations + bumped the counter on the original analysis —
        // don't re-inflate stats on every edit.
        let analysesDescriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let existingAnalysesCount = (try? modelContext.fetchCount(analysesDescriptor)) ?? 0
        // `existingAnalysesCount` is 1 here (we just inserted one above).
        // >1 means there's an older one → this is a re-analysis.
        let isReanalysis = existingAnalysesCount > 1

        let intel = ensureIntelligenceExists(modelContext: modelContext)
        let newText = observations.map { "• \($0)" }.joined(separator: "\n")

        if intel.pendingObservations.isEmpty {
            intel.pendingObservations = newText
        } else {
            intel.pendingObservations += "\n" + newText
        }

        // Also emit structured Observation rows so UserState /
        // IntelligenceView / the Patterns card can consume them. Each
        // AI observation becomes one row; upsert by text-prefix so
        // repeated observations dedupe instead of stacking.
        for text in observations {
            ObservationStore.recordPostWorkoutNote(text, modelContext: modelContext)
        }

        // Trim to the most-recent N lines so pending stays bounded.
        let lines = intel.pendingObservations.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maxPendingObservationLines {
            let keep = lines.suffix(Self.maxPendingObservationLines)
            intel.pendingObservations = keep.joined(separator: "\n")
        }

        if !isReanalysis {
            intel.workoutsSinceRefresh += 1
        }
        try? modelContext.save()

        print("[BenLift/Intel] Observations appended: \(observations.count) items, \(intel.workoutsSinceRefresh) workouts since refresh\(isReanalysis ? " (re-analysis, counter skipped)" : "")")
    }

    /// Mirror of IntelligenceViewModel.ensureIntelligenceExists — lives
    /// here too so AnalysisViewModel doesn't need a cross-VM dependency.
    /// Both funnel through the same "fetch-or-create" pattern so we don't
    /// ever silently end up with duplicate UserIntelligence rows.
    @MainActor
    private func ensureIntelligenceExists(modelContext: ModelContext) -> UserIntelligence {
        let descriptor = FetchDescriptor<UserIntelligence>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let new = UserIntelligence()
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }
}
