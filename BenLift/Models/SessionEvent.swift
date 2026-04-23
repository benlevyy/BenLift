import Foundation
import SwiftData

/// Kinds of user actions that happen during a workout and become signal for
/// future AI plan generation. Recorded by the session owner in response to
/// `WorkoutCommand`s that mutate the plan (as opposed to logging sets).
///
/// Stored as a String rawValue so SwiftData migrations don't break when new
/// cases are added — unknown values decode as `.unknown`.
enum SessionEventKind: String, Codable, CaseIterable {
    case skip
    case unskip
    case swap
    case link
    case unlink
    case insertStretch
    case insertRest
    case reorder
    case addExercise
    case unknown
}

/// An atom of user behavior during a workout — every one of these feeds the
/// next plan's prompt so Claude can spot patterns ("user swaps bench →
/// incline 4/5 recent push days → default to incline").
///
/// Purposely flat / easily queryable. Detailed context goes in `contextJSON`
/// rather than dedicated columns so the schema doesn't churn every time we
/// want to capture one more thing.
@Model
final class SessionEvent {
    var id: UUID
    var timestamp: Date
    /// Raw value of `SessionEventKind`. Using String so unknown future kinds
    /// round-trip instead of crashing.
    var kindRaw: String
    /// Exercise acted on (nil for reorders that affect multiple).
    var exerciseName: String?
    /// Only set for `.swap` — what the exercise was replaced with.
    var replacementName: String?
    /// Index in the session at the time of the event (for reconstructing order).
    var exerciseIndex: Int?
    /// Free-form JSON payload — feeling, muscleGroup, time-of-day, etc.
    /// Intentionally loose so prompt builders can add new context fields
    /// without migrating SwiftData.
    var contextJSON: String?
    /// Link back to the WorkoutSession the event belongs to. Optional because
    /// events can occur before the session is finalized (no `WorkoutSession`
    /// row exists until `finishWorkout`).
    var sessionDate: Date?

    var kind: SessionEventKind {
        SessionEventKind(rawValue: kindRaw) ?? .unknown
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: SessionEventKind,
        exerciseName: String? = nil,
        replacementName: String? = nil,
        exerciseIndex: Int? = nil,
        contextJSON: String? = nil,
        sessionDate: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.exerciseName = exerciseName
        self.replacementName = replacementName
        self.exerciseIndex = exerciseIndex
        self.contextJSON = contextJSON
        self.sessionDate = sessionDate
    }
}
