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

//
// One-time bootstrap output: which weekday seeds which muscle group, before
