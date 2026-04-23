import Foundation
import SwiftData

/// Helpers for creating + archiving `UserRule` rows. Small struct of
/// static functions so the call sites (CoachViewModel remove, Add
/// Exercise flow, ExercisePreferencesView, etc.) stay readable without
/// everyone reimplementing the fetch+upsert dance.
///
/// Rules are the "explicit user decisions the AI must respect" layer —
/// creating one is a deliberate act, archiving one restores the AI's
/// freedom to suggest that exercise again. Soft-archive (flag) is used
/// throughout rather than delete so the history stays debuggable.
struct UserRuleStore {

    /// Create (or reinforce) an `exerciseOut` rule for the given
    /// exercise. If an active rule for this exercise already exists,
    /// bump its `lastReinforcedAt` instead of creating a duplicate so
    /// the repeated-removal signal stays visible to the 90-day decay.
    /// Reactivates a previously archived rule if the user removes the
    /// exercise again — respects the "repeated action strengthens the
    /// preference" pattern.
    @MainActor
    static func addExerciseOut(
        exerciseName: String,
        reason: String? = nil,
        modelContext: ModelContext
    ) {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate {
                $0.kindRaw == "exerciseOut" && $0.subject == exerciseName
            }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastReinforcedAt = Date()
            existing.isActive = true
            if let reason, existing.reason != reason {
                existing.reason = reason
            }
        } else {
            let rule = UserRule(
                kind: .exerciseOut,
                subject: exerciseName,
                reason: reason
            )
            modelContext.insert(rule)
        }
        try? modelContext.save()
        print("[BenLift/Rule] exerciseOut: \(exerciseName) (\(reason ?? "no reason"))")
    }

    /// Archive any active `exerciseOut` rule for the given exercise —
    /// called when the user explicitly adds the exercise back to their
    /// plan, which is the clearest possible "I changed my mind" signal.
    /// Leaves archived rules in the DB (isActive = false) so history is
    /// preserved.
    @MainActor
    static func archiveExerciseOutRule(
        for exerciseName: String,
        modelContext: ModelContext
    ) {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate {
                $0.kindRaw == "exerciseOut"
                && $0.subject == exerciseName
                && $0.isActive == true
            }
        )
        guard let rules = try? modelContext.fetch(descriptor), !rules.isEmpty else {
            return
        }
        for rule in rules {
            rule.isActive = false
        }
        try? modelContext.save()
        print("[BenLift/Rule] archived \(rules.count) exerciseOut rule(s) for \(exerciseName) — user re-added")
    }

    /// User-initiated archive from a "Manage Rules" screen. Same
    /// soft-delete semantics as the add-back path.
    @MainActor
    static func archiveRule(_ ruleId: UUID, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate { $0.id == ruleId }
        )
        if let rule = try? modelContext.fetch(descriptor).first {
            rule.isActive = false
            try? modelContext.save()
        }
    }

    /// Optional maintenance job: run periodically to expire rules that
    /// haven't been reinforced in 90 days. Keeps the active rule set
    /// from accumulating stale decisions over months.
    @MainActor
    static func expireStaleRules(modelContext: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate {
                $0.isActive == true && $0.lastReinforcedAt < cutoff
            }
        )
        guard let rules = try? modelContext.fetch(descriptor), !rules.isEmpty else {
            return
        }
        for rule in rules {
            rule.isActive = false
        }
        try? modelContext.save()
        print("[BenLift/Rule] expired \(rules.count) stale rules (>90d without reinforcement)")
    }
}
