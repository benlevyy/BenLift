import Foundation
import SwiftData

// MARK: - MuscleGroupPin
//
// User-explicit pin on a future calendar day. Created when the user taps a
// future cell in the Week Strip and picks a muscle group (or "Rest"). Trumps
// the pattern engine's prediction for that date.
//
// Cleanup: pins for past dates are auto-deleted when the strip computes (a
// pin in the past has no decision-relevant role; once a session is logged
// for that day, history wins).

@Model
final class MuscleGroupPin {
    var id: UUID
    /// The calendar day this pin applies to. Stored as a startOfDay-aligned
    /// Date so equality compares by day, not by instant.
    var date: Date
    /// nil = "rest day" / "off". A muscle pin and a rest pin are mutually
    /// exclusive — the freeform `label` carries non-muscle intent.
    var muscleGroupRaw: String?
    /// Freeform label for non-muscle days ("Rest", "Travel"). nil otherwise.
    var label: String?
    /// User's freeform note for that day ("dumbbells only", "going light").
    /// Rides into the planner prompt as `recovery.userNote` on that date.
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        muscleGroup: MuscleGroup? = nil,
        label: String? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.muscleGroupRaw = muscleGroup?.rawValue
        self.label = label
        self.note = note
        self.createdAt = createdAt
    }

    var muscleGroup: MuscleGroup? {
        get { muscleGroupRaw.flatMap { MuscleGroup(rawValue: $0) } }
        set { muscleGroupRaw = newValue?.rawValue }
    }
}

// MARK: - SeedPattern
//
// One-time bootstrap output: which weekday seeds which muscle group, before
// the user has enough real session history for the pattern engine to take
// over. Each row = one weekday slot.
//
// Lifecycle: written by the bootstrap LLM call at signup (or whenever the
// user redoes goals). Used by PatternEngine as a fallback when fewer than
// 3 real sessions exist for a given weekday in the rolling window. Once
// real data is available, real wins.

@Model
final class SeedPattern {
    var id: UUID
    /// 1=Sun, 2=Mon, ... 7=Sat (Calendar.component(.weekday, from:))
    var weekday: Int
    /// nil = rest day in the seed pattern.
    var muscleGroupRaw: String?
    /// "bootstrap" = produced by the onboarding LLM call. "user_edit" = the
    /// user manually changed their default for this weekday in settings.
    var sourceRaw: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        weekday: Int,
        muscleGroup: MuscleGroup? = nil,
        source: SeedSource = .bootstrap,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.weekday = weekday
        self.muscleGroupRaw = muscleGroup?.rawValue
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    var muscleGroup: MuscleGroup? {
        get { muscleGroupRaw.flatMap { MuscleGroup(rawValue: $0) } }
        set { muscleGroupRaw = newValue?.rawValue }
    }

    var source: SeedSource {
        get { SeedSource(rawValue: sourceRaw) ?? .bootstrap }
        set { sourceRaw = newValue.rawValue }
    }
}

enum SeedSource: String, Codable {
    case bootstrap   // from onboarding LLM
    case userEdit = "user_edit"
}
