import Foundation
import SwiftData

/// Create / upsert / expire helpers for `Observation` rows. Observations
/// are AI-discovered patterns (probabilistic, soft priors) — unlike
/// UserRules which are deterministic hard constraints. Lifecycle:
///
/// - Created by post-workout analysis + intelligence refresh.
/// - Superseded on `(kind, subject)` match during subsequent refreshes
///   (bumping `lastReinforcedAt` rather than creating duplicates).
/// - Auto-archived after 90 days without reinforcement.
/// - Top 5 active by `lastReinforcedAt` ride in every plan prompt via
///   `UserState.observations`.
struct ObservationStore {

    /// Upsert by `(kind, subject)`. If an active observation already
    /// exists for that key, bump its reinforcement + optionally update
    /// the text/confidence. Otherwise create new. Used by both the
    /// post-workout analysis note-append path and the intelligence
    /// refresh rebuild path so they dedupe cleanly.
    @MainActor
    static func upsert(
        kind: ObservationKind,
        subject: String,
        text: String,
        confidence: ObservationConfidence = .medium,
        modelContext: ModelContext
    ) {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<UserObservation>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw
                && $0.subject == subject
                && $0.isActive == true
            }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastReinforcedAt = Date()
            // Keep text current — the latest phrasing of the pattern is
            // usually better than the stale one. Confidence can shift
            // (low → high when the AI sees more evidence).
            existing.text = text
            existing.confidenceRaw = confidence.rawValue
        } else {
            let obs = UserObservation(
                kind: kind,
                subject: subject,
                text: text,
                confidence: confidence
            )
            modelContext.insert(obs)
        }
        try? modelContext.save()
    }

    /// Convenience — record a simple post-workout observation (loose
    /// note kind, scoped to "postWorkout"). Primary call site is
    /// `AnalysisViewModel.appendObservations`.
    @MainActor
    static func recordPostWorkoutNote(_ text: String, modelContext: ModelContext) {
        // Subject derived from the text so multiple notes don't all
        // collide into one row. Use a hash-ish prefix for the subject
        // key — keeps things stable while still deduping exact repeats.
        let subjectKey = "postWorkout:\(String(text.prefix(60)))"
        upsert(
            kind: .note,
            subject: subjectKey,
            text: text,
            confidence: .medium,
            modelContext: modelContext
        )
    }

    /// Run 90-day decay. Called before each refresh job writes new
    /// observations so the active set stays current.
    @MainActor
    static func archiveStale(modelContext: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<UserObservation>(
            predicate: #Predicate {
                $0.isActive == true && $0.lastReinforcedAt < cutoff
            }
        )
        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else {
            return
        }
        for obs in stale { obs.isActive = false }
        try? modelContext.save()
        print("[BenLift/Obs] archived \(stale.count) stale observations")
    }
}
