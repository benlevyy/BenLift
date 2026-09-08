import Foundation
import SwiftData

/// Assembles what Claude sees on a chat turn.
///
/// Split into a stable block and a volatile one so prompt caching actually
/// works: the coaching instructions never change and carry the cache
/// breakpoint; today's plan and history come after it. Anything that varies
/// per request must stay in the second block or the cache is invalidated on
/// every call.
@MainActor
enum ChatContextBuilder {

    static func systemBlocks(
        plan: DailyPlan,
        modelContext: ModelContext,
        crossTraining: [CrossTrainingActivity],
        healthContext: HealthContext? = nil,
        liveWorkout: PhoneWorkoutViewModel? = nil
    ) -> [SystemBlock] {
        [
            .cached(instructions),
            .dynamic(state(
                plan: plan,
                modelContext: modelContext,
                crossTraining: crossTraining,
                healthContext: healthContext,
                liveWorkout: liveWorkout
            ))
        ]
    }

    // MARK: - Stable block

    private static let instructions = """
    You are the coach inside BenLift, a training app with exactly one user. \
    You are talking to him directly, in his gym, usually on his phone, often \
    mid-session. He is an experienced lifter — he knows what a deadlift is. \
    Tell him when not to do one.

    HOW THE APP WORKS

    Today's plan was built deterministically before you were involved: the app \
    rotated push/pull/legs from his last session, replayed the exercises he \
    actually did that day, and progressed the loads where he hit the top of \
    his rep range. You did not write it and you do not need to justify it.

    Your job is to change it when he asks, and to answer questions about his \
    training. Nothing else.

    EDITING

    Make the change he asked for with the tools, then say what you did in one \
    or two sentences. Do not restate the whole plan — he can see it. Do not \
    ask for confirmation before making an edit he clearly asked for.

    Use several tools in one turn when the request needs it. "Only have 30 \
    minutes" means removing lifts and possibly trimming sets, not asking him \
    which ones to cut.

    Distinguish today from always. "No cables today" is an edit. "I never want \
    upright rows" is an edit plus create_rule. When he says "remember that", \
    the thing to remember is whatever he just told you.

    create_rule does NOT save anything. It proposes a rule and he gets an \
    approve/dismiss card. Say what the rule would do in one sentence; never \
    say it's saved, and don't ask him to confirm in text — the card does that.

    Changing the DAY TYPE is set_focus, not a pile of swaps. "Legs today \
    instead" is one set_focus call, which rebuilds the plan from his last legs \
    session. Use it for future days too — "I'm climbing Thursday, do push that \
    day" pins Thursday and the app honours it when Thursday comes.

    ANSWERING

    Call query_history before saying anything about weights, progress, or \
    volume. Never estimate a number you could look up. If the data isn't there, \
    say so.

    TONE

    Short. Concrete. No preamble, no "great question", no encouragement he \
    didn't ask for. When he's mid-workout, be faster and shorter still — he is \
    standing between sets holding a phone.

    Push back when it matters. If he asks for something that will hurt him or \
    wreck a session, say so in one sentence and then do what he asked anyway — \
    he is an adult and it's his training.

    UNITS

    All weights are pounds.
    """

    // MARK: - Volatile block

    private static func state(
        plan: DailyPlan,
        modelContext: ModelContext,
        crossTraining: [CrossTrainingActivity],
        healthContext: HealthContext?,
        liveWorkout: PhoneWorkoutViewModel?
    ) -> String {
        var sections: [String] = []

        sections.append("TODAY: \(dayLine(plan))")

        // Mid-workout: what he has actually done so far outranks everything
        // else. Answer against this, not the plan.
        if let live = liveWorkout, live.isWorkoutActive {
            sections.append("HE IS MID-WORKOUT RIGHT NOW\n\(liveLines(live))")
        }
        sections.append("TODAY'S PLAN\n\(planLines(plan))")

        if let goal = goalText(modelContext: modelContext), !goal.isEmpty {
            sections.append("HIS GOAL (his own words)\n\(goal)")
        }
        if let rules = ruleLines(modelContext: modelContext) {
            sections.append("STANDING RULES (already enforced by the app — don't re-apply them)\n\(rules)")
        }
        if let flag = plan.crossTrainingFlag {
            sections.append("""
            CROSS-TRAINING FLAG ON TODAY'S PLAN
            \(flag.headline). \(flag.detail)
            Already applied: \(flag.appliedAdjustments.isEmpty ? "nothing" : flag.appliedAdjustments.joined(separator: ", ")).
            The app cannot tell how hard that session was. If he tells you, adjust accordingly.
            """)
        }
        if let cross = crossTrainingLines(crossTraining) {
            sections.append("OTHER TRAINING, LAST 7 DAYS\n\(cross)")
        }
        if let history = recentLiftingLines(modelContext: modelContext) {
            sections.append("RECENT LIFTING\n\(history)")
        }
        if let health = healthLine(healthContext) {
            sections.append("RECOVERY TODAY\n\(health)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Sets logged in the running session, so "kill the overhead press"
    /// can be answered with "you already got two sets in, that counts".
    private static func liveLines(_ live: PhoneWorkoutViewModel) -> String {
        let elapsed = Int(live.elapsedTime / 60)
        var lines = ["Elapsed: \(elapsed) min"]
        for state in live.exerciseStates {
            let logged = state.loggedSets
            if logged.isEmpty {
                lines.append("- \(state.name): not started (\(state.targetSets) sets planned)")
            } else {
                let detail = logged.map { "\(formatWeight($0.weight))x\($0.reps.formattedReps)" }
                    .joined(separator: ", ")
                lines.append("- \(state.name): \(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func dayLine(_ plan: DailyPlan) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        var line = "\(formatter.string(from: plan.date)) — \(plan.displayName)"
        if let note = plan.resolverNote { line += " (\(note))" }
        if plan.wasEdited { line += " [already edited today]" }
        return line
    }

    private static func planLines(_ plan: DailyPlan) -> String {
        guard !plan.lifts.isEmpty else { return "(empty — every lift has been removed)" }
        return plan.sortedLifts.enumerated().map { index, lift in
            var line = "\(index + 1). \(lift.name) — \(lift.sets)x\(lift.targetReps) @ \(formatWeight(lift.weight)) lbs"
            var tags: [String] = []
            switch lift.progression {
            case .progressed: tags.append("up \(formatWeight(lift.progressionDelta))")
            case .deloaded:   tags.append("backed off \(formatWeight(abs(lift.progressionDelta)))")
            case .held:       tags.append("held")
            case .new:        break
            }
            if lift.usesStraps { tags.append("straps") }
            if let note = lift.noteText { tags.append(note) }
            if !tags.isEmpty { line += " [\(tags.joined(separator: ", "))]" }
            return line
        }.joined(separator: "\n")
    }

    private static func goalText(modelContext: ModelContext) -> String? {
        let descriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true }
        )
        return try? modelContext.fetch(descriptor).first?.goalText
    }

    private static func ruleLines(modelContext: ModelContext) -> String? {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate { $0.isActive == true }
        )
        guard let rules = try? modelContext.fetch(descriptor), !rules.isEmpty else { return nil }
        return rules.map { rule in
            var line = "- \(rule.subject)"
            if let target = rule.target { line += " → use \(target)" }
            if let reason = rule.reason, !reason.isEmpty { line += " (\(reason))" }
            return line
        }.joined(separator: "\n")
    }

    private static func crossTrainingLines(_ activities: [CrossTrainingActivity]) -> String? {
        guard !activities.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return activities.prefix(10).map { activity in
            var line = "- \(formatter.string(from: activity.date)): \(activity.type) \(activity.duration.formattedDurationShort)"
            if let miles = activity.distanceMiles, miles > 0 {
                line += String(format: ", %.1fmi", miles)
            }
            return line
        }.joined(separator: "\n")
    }

    /// Three weeks of sessions, condensed. Enough for "am I stalling?" without
    /// shipping every set — `query_history` exists for the detail.
    private static func recentLiftingLines(modelContext: ModelContext) -> String? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -21, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let sessions = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.date >= cutoff }
        guard !sessions.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return sessions.prefix(12).map { session in
            let lifts = session.sortedEntries
                .filter { !$0.isSkipped && !$0.workingSets.isEmpty }
                .map { entry -> String in
                    let top = entry.workingSets.map(\.weight).max() ?? 0
                    return "\(entry.exerciseName) \(formatWeight(top))"
                }
                .joined(separator: ", ")
            return "- \(formatter.string(from: session.date)) \(session.displayName): \(lifts)"
        }.joined(separator: "\n")
    }

    private static func healthLine(_ context: HealthContext?) -> String? {
        guard let context else { return nil }
        var parts: [String] = []
        if let sleep = context.sleepHours { parts.append(String(format: "slept %.1fh", sleep)) }
        if let rhr = context.restingHR { parts.append("resting HR \(Int(rhr))") }
        if let hrv = context.hrv { parts.append("HRV \(Int(hrv))ms") }
        if let weight = context.bodyWeight { parts.append("bodyweight \(Int(weight))lb") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func formatWeight(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight))
            : String(format: "%.1f", weight)
    }
}
