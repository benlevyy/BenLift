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
    /// Single-muscle field, retained for SwiftData migration and back-compat
    /// reads from old pins. New writes go through `muscleGroups` (the array
    /// accessor below) which writes to `muscleGroupsRaw`. The accessor falls
    /// back to this field when the multi-field is empty so existing rows
    /// from before the multi-muscle refactor still render correctly.
    var muscleGroupRaw: String?
    /// JSON-encoded list of MuscleGroup raw values. Stored as a String to
    /// keep the SwiftData schema simple — most muscle-set sizes are 1–3, the
    /// encoding overhead is trivial. Empty / nil = falls back to
    /// muscleGroupRaw, which falls back to "rest day."
    var muscleGroupsRaw: String?
    /// Freeform label for non-muscle days ("Rest", "Travel"). nil otherwise.
    var label: String?
    /// User's freeform note for that day ("dumbbells only", "going light").
    /// Rides into the planner prompt as `recovery.userNote` on that date.
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        muscleGroups: [MuscleGroup] = [],
        label: String? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.muscleGroupRaw = muscleGroups.first?.rawValue
        self.muscleGroupsRaw = MuscleGroupPin.encode(muscleGroups)
        self.label = label
        self.note = note
        self.createdAt = createdAt
    }

    /// Convenience init for callers still passing a single muscle —
    /// keeps source-call-site simple while the refactor is in flight.
    convenience init(
        id: UUID = UUID(),
        date: Date,
        muscleGroup: MuscleGroup?,
        label: String? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            date: date,
            muscleGroups: muscleGroup.map { [$0] } ?? [],
            label: label,
            note: note,
            createdAt: createdAt
        )
    }

    /// Authoritative list of muscles for this pin. Falls back to the
    /// legacy single-muscle field for rows written before the multi
    /// refactor.
    var muscleGroups: [MuscleGroup] {
        get {
            if let decoded = MuscleGroupPin.decode(muscleGroupsRaw), !decoded.isEmpty {
                return decoded
            }
            if let single = muscleGroupRaw.flatMap({ MuscleGroup(rawValue: $0) }) {
                return [single]
            }
            return []
        }
        set {
            muscleGroupsRaw = MuscleGroupPin.encode(newValue)
            muscleGroupRaw = newValue.first?.rawValue  // keep legacy field in sync
        }
    }

    /// First muscle of the pin — used by callers that haven't migrated to
    /// the full list yet. Setter wraps in a single-element array.
    var muscleGroup: MuscleGroup? {
        get { muscleGroups.first }
        set { muscleGroups = newValue.map { [$0] } ?? [] }
    }

    private static func encode(_ muscles: [MuscleGroup]) -> String? {
        guard !muscles.isEmpty else { return nil }
        let raw = muscles.map(\.rawValue)
        return (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ raw: String?) -> [MuscleGroup]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr.compactMap(MuscleGroup.init(rawValue:))
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
    /// Single-muscle field, retained for SwiftData migration and back-compat
    /// reads. New writes go through `muscleGroups`. Same migration pattern
    /// as MuscleGroupPin.muscleGroupRaw.
    var muscleGroupRaw: String?
    /// JSON-encoded muscle list. Lets the bootstrap LLM seed multi-muscle
    /// days like "Monday = Push" without losing the shoulders/triceps.
    /// Empty / nil = rest day (or falls back to muscleGroupRaw).
    var muscleGroupsRaw: String?
    /// "bootstrap" = produced by the onboarding LLM call. "user_edit" = the
    /// user manually changed their default for this weekday in settings.
    var sourceRaw: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        weekday: Int,
        muscleGroups: [MuscleGroup] = [],
        source: SeedSource = .bootstrap,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.weekday = weekday
        self.muscleGroupRaw = muscleGroups.first?.rawValue
        self.muscleGroupsRaw = SeedPattern.encode(muscleGroups)
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    convenience init(
        id: UUID = UUID(),
        weekday: Int,
        muscleGroup: MuscleGroup?,
        source: SeedSource = .bootstrap,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            weekday: weekday,
            muscleGroups: muscleGroup.map { [$0] } ?? [],
            source: source,
            createdAt: createdAt
        )
    }

    /// Authoritative list of muscles. Falls back to legacy single-muscle
    /// field for rows from before the multi refactor.
    var muscleGroups: [MuscleGroup] {
        get {
            if let decoded = SeedPattern.decode(muscleGroupsRaw), !decoded.isEmpty {
                return decoded
            }
            if let single = muscleGroupRaw.flatMap({ MuscleGroup(rawValue: $0) }) {
                return [single]
            }
            return []
        }
        set {
            muscleGroupsRaw = SeedPattern.encode(newValue)
            muscleGroupRaw = newValue.first?.rawValue
        }
    }

    /// First muscle, used by callers that haven't migrated to the full list.
    var muscleGroup: MuscleGroup? {
        get { muscleGroups.first }
        set { muscleGroups = newValue.map { [$0] } ?? [] }
    }

    var source: SeedSource {
        get { SeedSource(rawValue: sourceRaw) ?? .bootstrap }
        set { sourceRaw = newValue.rawValue }
    }

    private static func encode(_ muscles: [MuscleGroup]) -> String? {
        guard !muscles.isEmpty else { return nil }
        let raw = muscles.map(\.rawValue)
        return (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ raw: String?) -> [MuscleGroup]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr.compactMap(MuscleGroup.init(rawValue:))
    }
}

enum SeedSource: String, Codable {
    case bootstrap   // from onboarding LLM
    case userEdit = "user_edit"
}
