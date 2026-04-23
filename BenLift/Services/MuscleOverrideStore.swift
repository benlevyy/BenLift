import Foundation

/// Persistent storage for user muscle-status overrides (the "chest is
/// sore today" taps on the Training tab). Previously these lived in
/// `CoachViewModel.muscleOverrides` as an in-memory dict, so they
/// disappeared on every app relaunch — not great signal for the AI.
///
/// This store is backed by UserDefaults JSON because the dataset is
/// tiny (one entry per muscle group), schema evolution is easy, and we
/// don't need SwiftData query power here. Overrides are timestamped so
/// the AI can see how recently the user asserted them, and they clear
/// automatically when a new plan is generated (the plan absorbs them as
/// context, so they're no longer "pending" once it has).
struct MuscleOverrideStore {
    private static let storageKey = "BenLift.muscleOverrides.v1"

    /// A single override entry — which muscle, what status the user
    /// reported, when they reported it. Timestamp is part of what the
    /// AI sees ("reported 3d ago"), so it can discount stale overrides.
    struct Entry: Codable, Equatable {
        let status: String   // fresh / ready / recovering / sore
        let setAt: Date
    }

    /// Load the current overrides from UserDefaults. Never returns nil —
    /// a missing / corrupted blob just reads as an empty dict so callers
    /// don't have to handle failure modes.
    static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Write the full dict back. Callers mutate a copy and call this to
    /// persist — simpler than exposing add/remove/clear helpers that each
    /// have to round-trip.
    static func save(_ overrides: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Convenience: set or clear a single muscle's override. Passing nil
    /// removes the entry entirely (AI/computed status takes over again).
    static func set(muscle: String, status: String?) {
        var current = load()
        if let status {
            current[muscle] = Entry(status: status, setAt: Date())
        } else {
            current.removeValue(forKey: muscle)
        }
        save(current)
    }

    /// Wipe everything. Called after a new plan is generated — the plan
    /// has now absorbed the override as context, so keeping it around
    /// would cause the next plan to double-apply.
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
