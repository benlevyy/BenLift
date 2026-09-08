import Foundation
import SwiftData

/// Applies Claude's tool calls to today's plan. Runs on the main actor
/// because every one of these touches SwiftData.
///
/// Every handler is defensive: a missing field or a lift name that doesn't
/// match anything comes back as a readable tool error rather than throwing,
/// so Claude can correct itself on the next round instead of the whole turn
/// failing.
/// A rule Claude wants to create, held until the user says yes.
///
/// Rules are hard filters in the resolver — an excluded lift simply never
/// appears — so creating one silently is exactly how the old app ended up
/// with a pile of standing preferences nobody agreed to. Nothing is written
/// until it's approved.
struct PendingRuleProposal: Identifiable, Equatable {
    let id = UUID()
    let kind: UserRuleKind
    let subject: String
    let target: String?
    let reason: String?

    var summary: String {
        switch kind {
        case .exerciseOut:  return "Never program \(subject)"
        case .preferOver:   return "Use \(target ?? "an alternative") instead of \(subject)"
        case .equipment:    return subject
        case .programming:  return subject
        case .unknown:      return subject
        }
    }
}

@MainActor
final class ChatToolExecutor {
    let modelContext: ModelContext
    let plan: DailyPlan
    /// Set while a workout is running. Edits then land on BOTH the stored
    /// plan and the live session, so "kill the overhead press" between sets
    /// actually changes what the runner (and the Watch) shows — not just
    /// tomorrow's record of today.
    let liveWorkout: PhoneWorkoutViewModel?
    /// Restricts which tools run. Session review gets the read-only set —
    /// editing a plan from three weeks ago is meaningless.
    let allowedTools: Set<String>?

    /// Rules proposed this turn, awaiting the user's yes.
    private(set) var pendingRules: [PendingRuleProposal] = []
    /// Set when the day's focus changed and the plan has to be rebuilt.
    private(set) var didChangeFocus = false

    init(
        modelContext: ModelContext,
        plan: DailyPlan,
        liveWorkout: PhoneWorkoutViewModel? = nil,
        allowedTools: Set<String>? = nil
    ) {
        self.modelContext = modelContext
        self.plan = plan
        self.liveWorkout = liveWorkout
        self.allowedTools = allowedTools
    }

    func execute(_ calls: [ChatToolCall]) -> [ChatToolResult] {
        let results = calls.map { call -> ChatToolResult in
            if let allowedTools, !allowedTools.contains(call.name) {
                return ChatToolResult(
                    toolUseId: call.id,
                    content: "\(call.name) isn't available here — this is a past session, not today's plan.",
                    isError: true
                )
            }
            switch call.name {
            case "replace_exercise": return replaceExercise(call)
            case "add_exercise":     return addExercise(call)
            case "remove_exercise":  return removeExercise(call)
            case "set_load":         return setLoad(call)
            case "reorder":          return reorder(call)
            case "set_focus":        return setFocus(call)
            case "create_rule":      return createRule(call)
            case "query_history":    return queryHistory(call)
            default:
                return ChatToolResult(
                    toolUseId: call.id,
                    content: "Unknown tool \(call.name).",
                    isError: true
                )
            }
        }
        try? modelContext.save()
        return results
    }

    // MARK: - Plan edits

    private func replaceExercise(_ call: ChatToolCall) -> ChatToolResult {
        guard let currentName = call.input["current_name"] as? String,
              let newName = call.input["new_name"] as? String else {
            return error(call, "replace_exercise needs current_name and new_name.")
        }
        guard let lift = lift(named: currentName) else {
            return error(call, notFound(currentName))
        }

        let previousName = lift.name
        lift.name = newName
        lift.noteText = "was \(previousName)"
        lift.muscleGroup = exercise(named: newName)?.muscleGroup ?? lift.muscleGroup
        lift.progression = .new
        lift.progressionDelta = 0
        lift.usesStraps = false

        if let sets = call.input["sets"] as? Int { lift.sets = sets }
        if let reps = call.input["target_reps"] as? String { lift.targetReps = reps }
        if let weight = numeric(call.input["weight"]) {
            lift.weight = weight
        } else {
            lift.weight = suggestedWeight(for: newName)
        }

        var suffix = ""
        if let live = liveWorkout, live.isWorkoutActive {
            let info = WatchExerciseInfo(
                name: newName,
                sets: lift.sets,
                targetReps: lift.targetReps,
                suggestedWeight: lift.weight,
                warmupSets: nil,
                notes: nil,
                intent: lift.intentRaw,
                lastWeight: nil,
                lastReps: nil,
                equipment: exercise(named: newName)?.equipment
            )
            suffix = live.liveReplace(exerciseNamed: previousName, with: info)
                ? " Updated in the running session."
                : " (Not in the running session — only the plan changed.)"
        }

        markEdited()
        return ok(call, "Replaced \(previousName) with \(newName) at \(format(lift.weight)) lbs, \(lift.sets)x\(lift.targetReps).\(suffix)")
    }

    private func addExercise(_ call: ChatToolCall) -> ChatToolResult {
        guard let name = call.input["name"] as? String,
              let sets = call.input["sets"] as? Int,
              let reps = call.input["target_reps"] as? String else {
            return error(call, "add_exercise needs name, sets and target_reps.")
        }
        if lift(named: name) != nil {
            return error(call, "\(name) is already in today's plan. Use set_load to change it.")
        }

        let weight = numeric(call.input["weight"]) ?? suggestedWeight(for: name)
        let new = PlannedLift(
            name: name,
            order: plan.lifts.count,
            sets: sets,
            targetReps: reps,
            weight: weight,
            muscleGroup: exercise(named: name)?.muscleGroup,
            progression: .new
        )
        new.plan = plan
        plan.lifts.append(new)

        if let after = call.input["after"] as? String, let anchor = lift(named: after) {
            var ordered = plan.sortedLifts.filter { $0.id != new.id }
            let index = (ordered.firstIndex { $0.id == anchor.id }).map { $0 + 1 } ?? ordered.count
            ordered.insert(new, at: min(index, ordered.count))
            renumber(ordered)
        } else {
            renumber(plan.sortedLifts)
        }

        // Re-adding a lift is the clearest possible "never mind" — retire any
        // rule that was keeping it out.
        archiveExerciseOutRule(for: name)

        markEdited()
        return ok(call, "Added \(name), \(sets)x\(reps) at \(format(weight)) lbs.")
    }

    private func removeExercise(_ call: ChatToolCall) -> ChatToolResult {
        guard let name = call.input["name"] as? String else {
            return error(call, "remove_exercise needs a name.")
        }
        guard let lift = lift(named: name) else {
            return error(call, notFound(name))
        }
        let removedName = lift.name

        // Mid-workout, skip rather than delete: sets already logged against
        // this exercise happened, and the session record has to keep them.
        var suffix = ""
        if let live = liveWorkout, live.isWorkoutActive {
            suffix = live.liveRemove(exerciseNamed: removedName)
                ? " Skipped in the running session; anything already logged is kept."
                : ""
        }

        plan.lifts.removeAll { $0.id == lift.id }
        modelContext.delete(lift)
        renumber(plan.sortedLifts)
        markEdited()
        return ok(call, "Removed \(removedName). \(plan.lifts.count) lifts left.\(suffix)")
    }

    private func setLoad(_ call: ChatToolCall) -> ChatToolResult {
        guard let name = call.input["name"] as? String else {
            return error(call, "set_load needs a name.")
        }
        guard let lift = lift(named: name) else {
            return error(call, notFound(name))
        }

        var changes: [String] = []
        if let weight = numeric(call.input["weight"]) {
            lift.weight = weight
            lift.progression = .new
            lift.progressionDelta = 0
            changes.append("\(format(weight)) lbs")
        }
        if let sets = call.input["sets"] as? Int {
            lift.sets = sets
            changes.append("\(sets) sets")
        }
        if let reps = call.input["target_reps"] as? String {
            lift.targetReps = reps
            changes.append("\(reps) reps")
        }
        guard !changes.isEmpty else {
            return error(call, "set_load needs at least one of weight, sets or target_reps.")
        }

        if let live = liveWorkout, live.isWorkoutActive {
            live.liveSetLoad(
                exerciseNamed: lift.name,
                weight: numeric(call.input["weight"]),
                sets: call.input["sets"] as? Int
            )
        }

        markEdited()
        return ok(call, "\(lift.name) is now \(changes.joined(separator: ", ")).")
    }

    private func reorder(_ call: ChatToolCall) -> ChatToolResult {
        guard let name = call.input["name"] as? String,
              let position = call.input["position"] as? Int else {
            return error(call, "reorder needs a name and a position.")
        }
        guard let lift = lift(named: name) else {
            return error(call, notFound(name))
        }

        var ordered = plan.sortedLifts
        guard let from = ordered.firstIndex(where: { $0.id == lift.id }) else {
            return error(call, notFound(name))
        }
        let to = max(0, min(ordered.count - 1, position - 1))
        ordered.remove(at: from)
        ordered.insert(lift, at: to)
        renumber(ordered)

        markEdited()
        return ok(call, "Moved \(lift.name) to position \(to + 1).")
    }

    // MARK: - Focus (calendar pins)

    /// Pin a day's muscle groups. The resolver reads today's pin ahead of the
    /// rotation, so this is the mechanism for "legs today instead" — and for
    /// future days it just sits there until that day comes round.
    private func setFocus(_ call: ChatToolCall) -> ChatToolResult {
        guard let raw = call.input["muscle_groups"] as? [String], !raw.isEmpty else {
            return error(call, "set_focus needs at least one muscle group.")
        }
        let groups = raw.compactMap(MuscleGroup.init(rawValue:))
        guard !groups.isEmpty else {
            return error(call, "None of those are muscle groups I know: \(raw.joined(separator: ", ")).")
        }

        let daysAhead = max(0, call.input["days_ahead"] as? Int ?? 0)
        guard let target = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) else {
            return error(call, "Couldn't work out which day that is.")
        }
        let day = Calendar.current.startOfDay(for: target)

        let descriptor = FetchDescriptor<MuscleGroupPin>()
        let pins = (try? modelContext.fetch(descriptor)) ?? []
        if let existing = pins.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            existing.muscleGroups = groups
            if let note = call.input["note"] as? String { existing.note = note }
        } else {
            let pin = MuscleGroupPin(date: day, muscleGroups: groups)
            pin.note = call.input["note"] as? String
            modelContext.insert(pin)
        }

        let names = groups.map(\.displayName).joined(separator: " + ")

        if daysAhead == 0 {
            // Today's plan was resolved against the old focus and is stored;
            // `resolve` never overwrites a stored plan, so it has to go or the
            // pin does nothing. A different day type makes the old lifts moot
            // anyway.
            if let stored = PlanResolver.existingPlan(on: day, modelContext: modelContext) {
                modelContext.delete(stored)
            }
            didChangeFocus = true
            try? modelContext.save()
            return ok(call, "Today is now \(names). Rebuilt the plan from the last session of that type — describe it in one sentence.")
        }

        try? modelContext.save()
        let when = daysAhead == 1 ? "Tomorrow" : "In \(daysAhead) days"
        return ok(call, "\(when) is pinned to \(names).")
    }

    // MARK: - Rules

    private func createRule(_ call: ChatToolCall) -> ChatToolResult {
        guard let kindRaw = call.input["kind"] as? String,
              let kind = UserRuleKind(rawValue: kindRaw),
              let subject = call.input["subject"] as? String else {
            return error(call, "create_rule needs a valid kind and a subject.")
        }

        let descriptor = FetchDescriptor<UserRule>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        if existing.contains(where: {
            $0.isActive && $0.kindRaw == kindRaw && $0.subject.lowercased() == subject.lowercased()
        }) {
            return ok(call, "That rule is already active — nothing to change.")
        }

        // Staged, not written. The user approves it in the transcript.
        pendingRules.append(PendingRuleProposal(
            kind: kind,
            subject: subject,
            target: call.input["target"] as? String,
            reason: call.input["reason"] as? String
        ))

        return ok(call, """
        Proposed — waiting on his approval, not saved yet. Tell him what the \
        rule would do in one short sentence. Do not claim it's saved.
        """)
    }

    private func archiveExerciseOutRule(for name: String) {
        let descriptor = FetchDescriptor<UserRule>()
        guard let rules = try? modelContext.fetch(descriptor) else { return }
        for rule in rules where rule.kindRaw == UserRuleKind.exerciseOut.rawValue
            && rule.subject.lowercased() == name.lowercased() {
            rule.isActive = false
        }
    }

    // MARK: - History queries

    private func queryHistory(_ call: ChatToolCall) -> ChatToolResult {
        let days = call.input["days"] as? Int ?? 28
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let exerciseFilter = (call.input["exercise"] as? String)?.lowercased()
        let groupFilter = (call.input["muscle_group"] as? String).flatMap(MuscleGroup.init(rawValue:))

        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let sessions = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.date >= cutoff }
        guard !sessions.isEmpty else {
            return ok(call, "No sessions logged in the last \(days) days.")
        }

        let lookup = exerciseLookup()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"

        var lines: [String] = []
        for session in sessions {
            var entryLines: [String] = []
            for entry in session.sortedEntries where !entry.isSkipped {
                if let exerciseFilter, !entry.exerciseName.lowercased().contains(exerciseFilter) { continue }
                if let groupFilter, lookup[entry.exerciseName.lowercased()]?.muscleGroup != groupFilter { continue }
                let sets = entry.workingSets
                guard !sets.isEmpty else { continue }
                let detail = sets.map { "\(format($0.weight))x\($0.reps.formattedReps)" }.joined(separator: ", ")
                entryLines.append("  \(entry.exerciseName): \(detail)")
            }
            if !entryLines.isEmpty {
                lines.append("\(formatter.string(from: session.date)) — \(session.displayName)")
                lines.append(contentsOf: entryLines)
            }
        }

        guard !lines.isEmpty else {
            return ok(call, "Nothing matching that in the last \(days) days.")
        }
        return ok(call, lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func lift(named name: String) -> PlannedLift? {
        let target = name.lowercased()
        if let exact = plan.lifts.first(where: { $0.name.lowercased() == target }) {
            return exact
        }
        // Loose match so "bench" finds "Bench Press" — Claude works from the
        // plan text, but the user's phrasing leaks through sometimes.
        return plan.lifts.first { $0.name.lowercased().contains(target) }
            ?? plan.lifts.first { target.contains($0.name.lowercased()) }
    }

    private func renumber(_ lifts: [PlannedLift]) {
        for (index, lift) in lifts.enumerated() { lift.order = index }
    }

    private func markEdited() {
        plan.wasEdited = true
    }

    private func exerciseLookup() -> [String: Exercise] {
        let descriptor = FetchDescriptor<Exercise>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func exercise(named name: String) -> Exercise? {
        exerciseLookup()[name.lowercased()]
    }

    /// Last load actually logged for this lift, else the library default.
    private func suggestedWeight(for name: String) -> Double {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        for session in sessions {
            if let entry = session.entries.first(where: {
                $0.exerciseName.lowercased() == name.lowercased() && !$0.isSkipped
            }), let heaviest = entry.workingSets.map(\.weight).max() {
                return heaviest
            }
        }
        return exercise(named: name)?.defaultWeight ?? 0
    }

    private func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func format(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight))
            : String(format: "%.1f", weight)
    }

    private func notFound(_ name: String) -> String {
        let names = plan.sortedLifts.map(\.name).joined(separator: ", ")
        return "No lift called \"\(name)\" in today's plan. Current lifts: \(names)."
    }

    private func ok(_ call: ChatToolCall, _ message: String) -> ChatToolResult {
        ChatToolResult(toolUseId: call.id, content: message)
    }

    private func error(_ call: ChatToolCall, _ message: String) -> ChatToolResult {
        ChatToolResult(toolUseId: call.id, content: message, isError: true)
    }
}
