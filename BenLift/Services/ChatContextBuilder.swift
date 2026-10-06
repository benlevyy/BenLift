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

    // MARK: - Session review

    /// Context for talking about a workout that already happened.
    ///
    /// Deliberately a different system prompt, not today's with a session
    /// bolted on: the job is explaining and noticing, not planning, and a
    /// prompt that talks about editing a plan will try to edit one.
    static func reviewBlocks(
        session: WorkoutSession,
        modelContext: ModelContext
    ) -> [SystemBlock] {
        [
            .cached(reviewInstructions),
            .dynamic(reviewState(session: session, modelContext: modelContext))
        ]
    }

    private static let reviewInstructions = """
    You are the coach inside BenLift. The user is looking at a workout they \
    already did and wants to talk about it.

    This session is finished. You cannot change it and shouldn't offer to — \
    no plan edits, no swaps, no loads. What you can do is explain what \
    happened, compare it to what came before, and notice things worth noticing.

    Call query_history before any claim about weights, progress or volume. The \
    session in front of you is one data point; whether it was good depends on \
    what came before it, so go and look rather than guessing.

    Lead with the answer. If they ask how it went, say how it went in a \
    sentence, then the evidence. No preamble, no encouragement they didn't ask \
    for, no summarising the session back at them — they can see it.

    Say when nothing stands out. A workout that was simply fine is the most \
    common kind, and inventing significance in it is worse than saying so.

    If something recurs — a lift they keep bailing on, a load that hasn't \
    moved in a month — say it plainly once. If they want it to shape future \
    plans, create_rule proposes one and they get an approve/dismiss card; it \
    does not save anything, so never say a rule is saved.

    Never assume the user's gender. Use "you" when addressing them and they/\
    them otherwise.

    All weights are pounds.
    """

    private static func reviewState(
        session: WorkoutSession,
        modelContext: ModelContext
    ) -> String {
        var sections: [String] = []

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy"
        var header = "THE SESSION THEY'RE LOOKING AT\n\(formatter.string(from: session.date)) — \(session.displayName)"
        if let duration = session.duration, duration > 0 {
            header += " · \(TimeInterval(duration).spokenDuration)"
        }
        if let feeling = session.feeling {
            header += " · felt \(feeling)/5"
        }
        sections.append(header)

        var lines: [String] = []
        for entry in session.sortedEntries {
            if entry.isSkipped {
                lines.append("- \(entry.exerciseName): SKIPPED")
                continue
            }
            let sets = entry.workingSets
            guard !sets.isEmpty else {
                lines.append("- \(entry.exerciseName): nothing logged")
                continue
            }
            let detail = sets.map { "\(formatWeight($0.weight))x\($0.reps.formattedReps)" }
                .joined(separator: ", ")
            var line = "- \(entry.exerciseName): \(detail)"
            if let target = entry.targetReps { line += " (target \(target))" }
            lines.append(line)
        }
        sections.append("WHAT THEY LOGGED\n\(lines.isEmpty ? "(nothing)" : lines.joined(separator: "\n"))")

        if let concerns = session.concerns, !concerns.isEmpty {
            sections.append("WHAT THEY SAID AT THE TIME\n\(concerns)")
        }
        if let goal = goalText(modelContext: modelContext), !goal.isEmpty {
            sections.append("THEIR GOAL (their own words)\n\(goal)")
        }
        if let rules = ruleLines(modelContext: modelContext) {
            sections.append("STANDING RULES\n\(rules)")
        }
        if let history = recentLiftingLines(modelContext: modelContext) {
            sections.append("RECENT LIFTING (for comparison)\n\(history)")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Stable block

    private static let instructions = """
    You are the coach inside BenLift. You are talking to the user directly, in \
    their gym, usually on their phone, often mid-session. They are an \
    experienced lifter — they know what a deadlift is. Tell them when not to \
    do one.

    HOW THE APP WORKS

    Today's plan was built deterministically before you were involved: the app \
    advanced their training split from their last session, replayed the \
    exercises they actually did on that day type, and progressed the loads \
    where they hit the top of their rep range. You did not write it and you \
    do not need to justify it. The split they train is in the state below.

    Your job is to change it when they ask, and to answer questions about \
    their training. Nothing else.

    EDITING

    Make the change they asked for with the tools, then say what you did in \
    one or two sentences. Do not restate the whole plan — they can see it. Do \
    not ask for confirmation before making an edit they clearly asked for.

    Use several tools in one turn when the request needs it. "Only have 30 \
    minutes" means removing lifts and possibly trimming sets, not asking which \
    ones to cut.

    AFTER ANY EDIT

    Every edit tool reports what the plan adds up to afterwards: set count \
    and time against their usual session length, which of the day's muscle \
    groups are covered, anything off the day's focus, anything out of order. \
    Read it before you reply. If the edit left one of the day's groups with \
    no lift, stacked one group far above the rest, pushed the session well \
    past their usual length, or put a compound after isolation work, say so \
    in one short sentence and name the fix — what to trim, where to move it. \
    Do not make that second change unless they asked for it: adding curls is \
    not permission to cut the bench. If nothing is off, say nothing about it. \
    Mid-workout, judge against what they have already logged, not the plan.

    Distinguish today from always. "No cables today" is an edit. "I never want \
    upright rows" is an edit plus create_rule. When they say "remember that", \
    the thing to remember is whatever they just told you.

    create_rule does NOT save anything. It proposes a rule and they get an \
    approve/dismiss card. Say what the rule would do in one sentence; never \
    say it's saved, and don't ask them to confirm in text — the card does that.

    Changing the DAY TYPE is set_focus, not a pile of swaps. "Legs today \
    instead" is one set_focus call, which rebuilds the plan from their last \
    session of that day type. It only applies to today — if they ask you to \
    plan a future LIFTING day, say the rotation handles it and they can \
    change any day when it arrives.

    Future cross-training is different, and worth catching. The app only \
    learns about a climb or a run after HealthKit records it, so when they \
    mention one that hasn't happened — "climbing tomorrow", "long run \
    Saturday" — call plan_activity, even if they only said it in passing. \
    Acknowledge it in a few words. Don't rework today's plan around it \
    unless they ask; knowing is the point, and they can decide what it means.

    ANSWERING

    Call query_history before saying anything about weights, progress, or \
    volume. Never estimate a number you could look up. If the data isn't \
    there, say so.

    TONE

    Short. Concrete. No preamble, no "great question", no encouragement they \
    didn't ask for. When they're mid-workout, be faster and shorter still — \
    they are standing between sets holding a phone.

    Push back when it matters. If they ask for something that will hurt them \
    or wreck a session, say so in one sentence and then do what they asked \
    anyway — it's their training.

    Never assume the user's gender. Use "you" when addressing them and they/\
    them otherwise.

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
        sections.append("TRAINING SPLIT: \(TrainingSplit.current.displayName)")

        // Mid-workout: what they have actually done so far outranks everything
        // else. Answer against this, not the plan.
        if let live = liveWorkout, live.isWorkoutActive {
            sections.append("THEY ARE MID-WORKOUT RIGHT NOW\n\(liveLines(live))")
        }
        sections.append("TODAY'S PLAN\n\(planLines(plan))")

        if let goal = goalText(modelContext: modelContext), !goal.isEmpty {
            sections.append("THEIR GOAL (their own words)\n\(goal)")
        }
        if let rules = ruleLines(modelContext: modelContext) {
            sections.append("STANDING RULES (already enforced by the app — don't re-apply them)\n\(rules)")
        }
        if let flag = plan.crossTrainingFlag {
            sections.append("""
            CROSS-TRAINING FLAG ON TODAY'S PLAN
            \(flag.headline). \(flag.detail)
            Already applied: \(flag.appliedAdjustments.isEmpty ? "nothing" : flag.appliedAdjustments.joined(separator: ", ")).
            The app cannot tell how hard that session was. If they tell you, adjust accordingly.
            """)
        }
        if let cross = crossTrainingLines(crossTraining) {
            sections.append("OTHER TRAINING, LAST 7 DAYS\n\(cross)")
        }
        if let planned = plannedLines(modelContext: modelContext) {
            sections.append("""
            WHAT THEY'VE TOLD YOU IS COMING
            \(planned)
            Recorded by them, not observed. Worth weighing when they ask what \
            to do today; not a reason to change the plan on your own.
            """)
        }
        if let history = recentLiftingLines(modelContext: modelContext) {
            sections.append("RECENT LIFTING\n\(history)")
        }
        if let health = healthLine(healthContext) {
            sections.append("RECOVERY TODAY\n\(health)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Sets logged in the running session, so "kill the overhead press" can be
    /// answered with "you already got two sets in, that counts".
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

    private static func plannedLines(modelContext: ModelContext) -> String? {
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        let upcoming = PlannedActivity.upcoming(in: modelContext).filter { $0.date >= tomorrow }
        guard !upcoming.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM"
        return upcoming.prefix(5).map { plan in
            var line = "- \(formatter.string(from: plan.date)): \(plan.activityType)"
            if let note = plan.note, !note.isEmpty { line += " (\(note))" }
            return line
        }.joined(separator: "\n")
    }

    private static func crossTrainingLines(_ activities: [CrossTrainingActivity]) -> String? {
        guard !activities.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return activities.prefix(10).map { activity in
            // Units spelled out: "50m" beside a ride was being read as 50
            // miles rather than 50 minutes.
            var line = "- \(formatter.string(from: activity.date)): \(activity.type), \(activity.duration.spokenDuration)"
            if let miles = activity.distanceMiles, miles > 0 {
                line += String(format: ", %.1f miles", miles)
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
                    let top = PlanResolver.workingWeight(of: entry.workingSets) ?? 0
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
