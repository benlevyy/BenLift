import Foundation
import SwiftData

// MARK: - Cross-training input

/// A non-lifting session read from HealthKit. Passed into the resolver as a
/// plain value so the resolver itself stays pure and testable — it never
/// touches HealthKit directly.
struct CrossTrainingActivity: Equatable {
    var type: String            // "climbing", "running", "cycling", …
    var date: Date
    var duration: TimeInterval
    var distanceMiles: Double?
}

// MARK: - Plan Resolver

/// Builds today's plan deterministically: rotate the split, replay the last
/// session of that type, progress the loads. No network call, no model, no
/// HealthKit in the decision path — it runs in well under a frame.
///
/// The one thing it will not do is overwrite a plan that already exists for
/// today. Once chat (or the user) has touched a plan, resolving again would
/// silently discard those edits, so `resolve` returns the stored plan
/// untouched instead.
@MainActor
enum PlanResolver {

    /// Days without a session of a given type before its loads are treated
    /// as stale and scaled back.
    static let stalenessThresholdDays = 14
    static let stalenessScale = 0.9

    // MARK: Entry point

    static func resolve(
        for date: Date = Date(),
        modelContext: ModelContext,
        activities: [CrossTrainingActivity] = []
    ) -> DailyPlan {
        let day = Calendar.current.startOfDay(for: date)

        if let existing = existingPlan(on: day, modelContext: modelContext) {
            return existing
        }

        let sessions = completedSessions(modelContext: modelContext)
        // One fetch of the exercise table for the whole resolve pass — this
        // used to be re-fetched by category inference, replay, and every
        // deload rounding individually.
        let lookup = exerciseLookup(modelContext: modelContext)
        let split = TrainingSplit.current
        let splitDay = resolveDay(for: day, split: split, sessions: sessions, lookup: lookup, modelContext: modelContext)
        let source = lastSession(matching: splitDay, in: sessions, before: day, split: split, lookup: lookup)

        debugLog("[BenLift/Resolver] \(sessions.count) completed sessions; today = \(splitDay.name) (\(split.displayName))")
        if let source {
            debugLog("[BenLift/Resolver] replaying \(source.date.shortFormatted) — \(source.sortedEntries.filter { !$0.isSkipped }.count) entries")
        } else {
            debugLog("[BenLift/Resolver] no prior \(splitDay.name) session — using template")
        }

        var lifts = source
            .map { replayLifts(from: $0, lookup: lookup, modelContext: modelContext) }
            ?? templateLifts(for: splitDay)

        let beforeRules = lifts.count
        lifts = applyRules(to: lifts, modelContext: modelContext)
        if lifts.count != beforeRules {
            debugLog("[BenLift/Resolver] rules removed \(beforeRules - lifts.count) of \(beforeRules) lifts")
        }

        // Staleness — loads from a month ago aren't loads you can hit today.
        var scale = 1.0
        if let source, daysBetween(source.date, day) > stalenessThresholdDays {
            scale = stalenessScale
            for lift in lifts {
                lift.weight = roundToIncrement(lift.weight * scale, for: lift.name, lookup: lookup)
            }
        }

        // Cross-training — surfaced as fact, with only the adjustments that
        // hold regardless of how hard the session actually was.
        let flag = crossTrainingFlag(for: splitDay.muscleGroups, activities: activities, on: day)
        if let flag {
            lifts = applyFlagAdjustments(flag, to: lifts)
        }

        for (i, lift) in lifts.enumerated() { lift.order = i }

        let plan = DailyPlan(
            date: day,
            category: split.category(for: splitDay),
            dayName: splitDay.name,
            muscleGroups: splitDay.muscleGroups,
            lifts: lifts,
            replayedFromDate: source?.date,
            resolverNote: note(source: source, lifts: lifts, scaled: scale < 1.0),
            stalenessScale: scale,
            crossTrainingFlag: flag
        )

        // Freeze the default before chat can touch it, so there is always a
        // "what the resolver said" to reopen after edits supersede the card.
        plan.originalSnapshot = PlanSnapshot(of: plan, title: "Today's plan")

        modelContext.insert(plan)
        try? modelContext.save()
        return plan
    }

    // MARK: Step 1 — which day

    /// Pin wins over rotation. Otherwise advance the split's cycle from the
    /// most recent session whose day can be determined — a session that
    /// genuinely spans days scores nil and is walked past, not guessed at.
    static func resolveDay(
        for day: Date,
        split: TrainingSplit,
        sessions: [WorkoutSession],
        lookup: [String: Exercise],
        modelContext: ModelContext
    ) -> SplitDay {
        if let pinned = pinnedDay(on: day, split: split, modelContext: modelContext) {
            return pinned
        }
        let days = split.days
        for session in sessions.prefix(10) {
            if let matched = splitDay(of: session, in: split, lookup: lookup),
               let index = days.firstIndex(of: matched) {
                return days[(index + 1) % days.count]
            }
        }
        return days[0]
    }

    /// Which of the split's days a session was, from the exercises actually
    /// logged. Same core-excluded, count-weighted, tie-refusing scoring as
    /// the PPL labeler — just against the active split's days. Falls back to
    /// the stored PPL category when scoring can't decide and the split still
    /// speaks that language.
    static func splitDay(
        of session: WorkoutSession,
        in split: TrainingSplit,
        lookup: [String: Exercise]
    ) -> SplitDay? {
        var groups: [MuscleGroup] = session.entries
            .filter { !$0.isSkipped }
            .compactMap { lookup[$0.exerciseName.lowercased()]?.muscleGroup }
        if groups.isEmpty { groups = session.muscleGroups }

        if let scored = bestDay(for: groups, in: split) { return scored }

        if let stored = session.category {
            return split.days.first { $0.name.lowercased() == stored.rawValue }
        }
        return nil
    }

    /// Best-matching day for a bag of muscle groups — the shared scoring
    /// under everything above, plus pins.
    static func bestDay(for groups: [MuscleGroup], in split: TrainingSplit) -> SplitDay? {
        let scored = groups.filter { $0 != .core }
        guard !scored.isEmpty else { return nil }

        let counts = split.days.map { day in
            (day, scored.filter { day.muscleGroups.contains($0) }.count)
        }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        guard counts.filter({ $0.1 == best.1 }).count == 1 else {
            // A full tie on a single-day split isn't ambiguity, it's the answer.
            return split.days.count == 1 ? split.days[0] : nil
        }
        return best.0
    }

    /// A session's category: the stored one when it has it, otherwise
    /// inferred from what was actually performed.
    ///
    /// Manual entry didn't set `category` for most of this app's life, so
    /// inference carries the bulk of the history and has to be right — the
    /// whole rotation is built on these labels.
    static func category(of session: WorkoutSession, lookup: [String: Exercise] = [:]) -> WorkoutCategory? {
        if let stored = session.category { return stored }
        return inferCategory(of: session, lookup: lookup)
    }

    /// Same scoring as `inferCategory`, for callers holding muscle groups but
    /// no session yet — manual entry, for one.
    static func categoryForMuscleGroups(_ groups: [MuscleGroup]) -> WorkoutCategory? {
        score(groups)
    }

    /// Score the session's muscle groups against each category and take the
    /// winner.
    ///
    /// The exercises actually logged are the ground truth, not the stored
    /// `muscleGroups` summary, which is written once and can be stale.
    static func inferCategory(of session: WorkoutSession, lookup: [String: Exercise]) -> WorkoutCategory? {
        var groups: [MuscleGroup] = session.entries
            .filter { !$0.isSkipped }
            .compactMap { lookup[$0.exerciseName.lowercased()]?.muscleGroup }

        if groups.isEmpty { groups = session.muscleGroups }
        return score(groups)
    }

    /// `core` is excluded because it belongs to all three categories —
    /// counting it adds the same number to every score while making near-ties
    /// look decisive, which is how mixed days ended up labelled arbitrarily
    /// (and identically, run after run).
    ///
    /// Weighted by exercise count rather than distinct groups: four chest
    /// movements and one stray row is a push day. A genuine tie returns nil —
    /// a session that really did span categories should be skipped by the
    /// rotation, not guessed at.
    private static func score(_ groups: [MuscleGroup]) -> WorkoutCategory? {
        let scored = groups.filter { $0 != .core }
        guard !scored.isEmpty else { return nil }

        let counts = WorkoutCategory.allCases.map { category in
            (category, scored.filter { category.muscleGroups.contains($0) }.count)
        }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        guard counts.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }

    static func pinnedDay(on day: Date, split: TrainingSplit, modelContext: ModelContext) -> SplitDay? {
        let descriptor = FetchDescriptor<MuscleGroupPin>()
        guard let pins = try? modelContext.fetch(descriptor) else { return nil }
        guard let pin = pins.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) else {
            return nil
        }
        return bestDay(for: pin.muscleGroups, in: split)
    }

    // MARK: Step 2 — which exercises

    private static func replayLifts(
        from session: WorkoutSession,
        lookup: [String: Exercise],
        modelContext: ModelContext
    ) -> [PlannedLift] {
        let history = completedSessions(modelContext: modelContext)

        return session.sortedEntries
            .filter { !$0.isSkipped }
            .enumerated()
            .map { index, entry in
                let exercise = lookup[entry.exerciseName.lowercased()]
                let result = progression(
                    for: entry,
                    equipment: exercise?.equipment,
                    history: history,
                    lookup: lookup
                )
                return PlannedLift(
                    name: entry.exerciseName,
                    order: index,
                    sets: max(1, entry.workingSets.count),
                    targetReps: entry.targetReps ?? "8-12",
                    weight: result.weight,
                    muscleGroup: exercise?.muscleGroup,
                    progression: result.kind,
                    progressionDelta: result.delta
                )
            }
    }

    /// Cold start — no session of this day type has ever been logged.
    ///
    /// Round-robins the library across the day's muscle groups instead of
    /// taking a prefix. The old prefix(5) of the push list was five chest
    /// movements in a row — the library is ordered by muscle, so a prefix is
    /// always a monoculture. One pick per group, then seconds, until the cap.
    private static func templateLifts(for day: SplitDay) -> [PlannedLift] {
        var byGroup: [MuscleGroup: [DefaultExercises.ExerciseDef]] = [:]
        for def in DefaultExercises.all where day.muscleGroups.contains(def.muscleGroup) {
            byGroup[def.muscleGroup, default: []].append(def)
        }

        let cap = day.muscleGroups.filter { $0 != .core }.count >= 5 ? 6 : 5
        var picks: [DefaultExercises.ExerciseDef] = []
        while picks.count < cap {
            var advanced = false
            for group in day.muscleGroups where group != .core {
                guard picks.count < cap, var pool = byGroup[group], !pool.isEmpty else { continue }
                picks.append(pool.removeFirst())
                byGroup[group] = pool
                advanced = true
            }
            if !advanced { break }
        }

        return picks.enumerated().map { index, def in
            PlannedLift(
                name: def.name,
                order: index,
                sets: 3,
                targetReps: "8-12",
                weight: def.defaultWeight ?? 0,
                muscleGroup: def.muscleGroup,
                progression: .new
            )
        }
    }

    // MARK: Step 3 — which weights (double progression)

    struct ProgressionResult {
        var weight: Double
        var kind: ProgressionKind
        var delta: Double
    }

    /// Hit the top of the range on every working set, clean → add a plate.
    /// Missed a rep or landed mid-range → hold. Held twice at the same load
    /// → back off 10% to break the stall.
    static func progression(
        for entry: ExerciseEntry,
        equipment: Equipment?,
        history: [WorkoutSession],
        lookup: [String: Exercise]
    ) -> ProgressionResult {
        let sets = entry.workingSets

        guard !sets.isEmpty else {
            return ProgressionResult(weight: entry.prescribedWeight ?? 0, kind: .new, delta: 0)
        }

        let base = workingWeight(of: sets) ?? entry.prescribedWeight ?? 0

        // No prescribed range means we can't tell "hit the top" from "landed
        // in the middle". Hold rather than guess — one session under the new
        // schema and this resolves itself.
        guard let range = PlannedLift.parseRepRange(entry.targetReps ?? "") else {
            return ProgressionResult(weight: base, kind: .held, delta: 0)
        }

        let topSets = sets.filter { $0.weight >= base - 0.01 }
        let allHitTop = !topSets.isEmpty && topSets.allSatisfy {
            !$0.isFailed && Int($0.reps) >= range.high
        }

        if allHitTop {
            let increment = equipment?.defaultIncrement ?? 5.0
            guard increment > 0 else {
                return ProgressionResult(weight: base, kind: .held, delta: 0)
            }
            return ProgressionResult(weight: base + increment, kind: .progressed, delta: increment)
        }

        if stalled(exerciseName: entry.exerciseName, at: base, history: history) {
            let deloaded = roundToIncrement(base * 0.9, for: entry.exerciseName, lookup: lookup)
            return ProgressionResult(weight: deloaded, kind: .deloaded, delta: deloaded - base)
        }

        return ProgressionResult(weight: base, kind: .held, delta: 0)
    }

    /// The weight you actually worked at, as distinct from the heaviest thing
    /// you touched.
    ///
    /// This used to be `max`, which is wrong in the two most common shapes a
    /// set list takes. Work up to a top single and back off — 185, 185, 225 —
    /// and max prescribes 225 for all three sets next time. Fat-finger one
    /// entry and that number anchors the lift permanently. Both read as the
    /// app inventing weights.
    ///
    /// So: the most frequent weight wins, heavier breaking a tie. Straight
    /// sets return their weight, back-offs return the working weight rather
    /// than the top single, and a lone typo loses to the majority. Sets below
    /// 70% of the top are dropped first — those are warmups that were never
    /// marked as such, and they'd otherwise win the count on a day with more
    /// warmup sets than working ones.
    ///
    /// A true pyramid, where every set differs, has no majority; the heaviest
    /// wins the tie, which is the old behaviour and the right answer there.
    static func workingWeight(of sets: [SetLog]) -> Double? {
        let weights = sets.map(\.weight).filter { $0 > 0 }
        guard let top = weights.max() else { return nil }

        let candidates = weights.filter { $0 >= top * 0.7 }
        guard !candidates.isEmpty else { return top }

        var counts: [Double: Int] = [:]
        for weight in candidates { counts[weight, default: 0] += 1 }

        return counts
            .max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?
            .key
    }

    /// True when the two most recent performances of this exercise were both
    /// at the same load — i.e. it already held once and is about to hold again.
    private static func stalled(
        exerciseName: String,
        at weight: Double,
        history: [WorkoutSession]
    ) -> Bool {
        let performances: [Double] = history.compactMap { session in
            session.entries
                .first { $0.exerciseName == exerciseName && !$0.isSkipped }
                .flatMap { workingWeight(of: $0.workingSets) }
        }
        guard performances.count >= 2 else { return false }
        return abs(performances[0] - weight) < 0.01 && abs(performances[1] - weight) < 0.01
    }

    // MARK: Step 4 — durable user rules

    /// Rules are enforced here, in Swift — not requested of a model. An
    /// `exerciseOut` rule means the lift does not appear, full stop.
    private static func applyRules(
        to lifts: [PlannedLift],
        modelContext: ModelContext
    ) -> [PlannedLift] {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate { $0.isActive == true }
        )
        guard let rules = try? modelContext.fetch(descriptor), !rules.isEmpty else {
            return lifts
        }

        let excluded = Set(
            rules.filter { $0.kindRaw == UserRuleKind.exerciseOut.rawValue }
                 .map { $0.subject.lowercased() }
        )
        let substitutions = Dictionary(
            rules.filter { $0.kindRaw == UserRuleKind.preferOver.rawValue }
                 .compactMap { rule -> (String, String)? in
                     guard let target = rule.target else { return nil }
                     return (rule.subject.lowercased(), target)
                 },
            uniquingKeysWith: { first, _ in first }
        )

        return lifts.compactMap { lift in
            let key = lift.name.lowercased()
            if excluded.contains(key) {
                debugLog("[BenLift/Resolver] dropped \(lift.name) — active exerciseOut rule")
                return nil
            }
            if let preferred = substitutions[key] {
                lift.noteText = "was \(lift.name)"
                lift.name = preferred
            }
            return lift
        }
    }

    // MARK: Step 5 — cross-training collisions

    ///
    /// This table IS the mechanism. A flag exists when a pairing is in here
    /// and does not exist otherwise — there is no muscle-overlap scoring and
    /// no generic fallback line. That kept an earlier version honest in two
    /// ways: it can't fire with nothing to say, and it can't be skewed by
    /// `core`, which appears in every category and so carried no signal while
    /// still padding every overlap count.
    ///
    /// `adjustments` are only the changes that hold whether the session was
    /// hard or easy — HealthKit reports duration, not intensity. Anything
    /// that depends on how hard he actually went is a question for chat.
    /// Guidance keyed by what the day actually trains, so it works for any
    /// split. First matching rule wins, so order encodes priority: a day that
    /// trains back gets the straps guidance even if it also trains shoulders
    /// (Pull, Upper), and only a back-free pressing day falls through to the
    /// shoulders note (Push).
    struct GuidanceRule {
        let activity: String
        let trains: MuscleGroup
        let detail: String
        let adjustments: [String]
    }

    static let guidanceRules: [GuidanceRule] = [
        GuidanceRule(
            activity: "climbing", trains: .back,
            detail: "Grip is the limiter, not your back — straps are on, and direct forearm work is dropped.",
            adjustments: ["straps", "dropped forearm work"]
        ),
        GuidanceRule(
            activity: "climbing", trains: .shoulders,
            detail: "Shoulders took a beating on overhangs. Loads are unchanged — ease into the first pressing set.",
            adjustments: []
        ),
        GuidanceRule(
            activity: "rowing", trains: .back,
            detail: "That was most of a pull session already. Loads are unchanged — cut a set if the back feels cooked.",
            adjustments: []
        ),
        GuidanceRule(
            activity: "running", trains: .quads,
            detail: "Quads and calves are pre-fatigued. Loads are unchanged — cut a set if the first one feels heavy.",
            adjustments: []
        ),
        GuidanceRule(
            activity: "hiking", trains: .quads,
            detail: "Quads and calves are pre-fatigued. Loads are unchanged — cut a set if the first one feels heavy.",
            adjustments: []
        ),
        GuidanceRule(
            activity: "cycling", trains: .quads,
            detail: "Quads have volume in them already. Loads are unchanged — the stimulus is different enough to keep.",
            adjustments: []
        ),
    ]


    /// First rule whose activity matches and whose trained muscle the day
    /// includes — order in `guidanceRules` is priority.
    static func rule(for activityType: String, trains groups: [MuscleGroup]) -> GuidanceRule? {
        guidanceRules.first { $0.activity == activityType && groups.contains($0.trains) }
    }

    static func crossTrainingFlag(
        for groups: [MuscleGroup],
        activities: [CrossTrainingActivity],
        on day: Date
    ) -> CrossTrainingFlag? {
        // Longest qualifying session in the last 48h wins — one flag, never
        // a stack of them.
        let candidate = activities
            .filter {
                let hours = day.timeIntervalSince($0.date) / 3600
                return hours >= 0 && hours <= 48
                    && rule(for: $0.type, trains: groups) != nil
            }
            .max { $0.duration < $1.duration }

        guard let activity = candidate,
              let advice = rule(for: activity.type, trains: groups) else { return nil }

        return CrossTrainingFlag(
            activityType: activity.type,
            date: activity.date,
            duration: activity.duration,
            distanceMiles: activity.distanceMiles,
            headline: headline(for: activity, on: day),
            detail: advice.detail,
            appliedAdjustments: advice.adjustments
        )
    }

    private static func headline(for activity: CrossTrainingActivity, on day: Date) -> String {
        let when = Calendar.current.isDateInYesterday(activity.date) ? "yesterday" : "today"
        let verb: String
        switch activity.type {
        case "climbing": verb = "Climbed"
        case "running": verb = "Ran"
        case "cycling": verb = "Rode"
        case "hiking": verb = "Hiked"
        case "rowing": verb = "Rowed"
        default: verb = activity.type.capitalized
        }
        // Distance is the more meaningful number when there is one.
        if let miles = activity.distanceMiles, miles > 0 {
            return "\(verb) \(String(format: "%.1f", miles))mi \(when)"
        }
        return "\(verb) \(activity.duration.formattedDurationShort) \(when)"
    }

    /// Names that are grip-limited (straps help) or redundant forearm work
    /// (drop it). Matched loosely so "Barbell Row" and "Pendlay Row" both hit.
    private static let gripLimited = ["row", "pulldown", "deadlift", "shrug", "pull-up", "pullup", "chin"]
    private static let forearmWork = ["wrist curl", "forearm", "farmer", "grip", "hang"]

    private static func applyFlagAdjustments(
        _ flag: CrossTrainingFlag,
        to lifts: [PlannedLift]
    ) -> [PlannedLift] {
        guard !flag.appliedAdjustments.isEmpty else { return lifts }

        var result = lifts
        if flag.appliedAdjustments.contains("dropped forearm work") {
            result = result.filter { lift in
                let name = lift.name.lowercased()
                return !forearmWork.contains { name.contains($0) }
            }
        }
        if flag.appliedAdjustments.contains("straps") {
            for lift in result {
                let name = lift.name.lowercased()
                if gripLimited.contains(where: { name.contains($0) }) {
                    lift.usesStraps = true
                }
            }
        }
        return result
    }

    // MARK: Provenance

    private static func note(source: WorkoutSession?, lifts: [PlannedLift], scaled: Bool) -> String {
        guard let source else { return "Starting template — no history for this day yet" }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        var parts = ["Replayed from \(formatter.string(from: source.date))"]

        let progressed = lifts.filter { $0.progression == .progressed }.count
        let deloaded = lifts.filter { $0.progression == .deloaded }.count
        if progressed > 0 { parts.append("\(progressed) lift\(progressed == 1 ? "" : "s") progressed") }
        if deloaded > 0 { parts.append("\(deloaded) backed off") }
        if scaled { parts.append("scaled back after time off") }

        return parts.joined(separator: " · ")
    }

    // MARK: Fetch helpers

    static func existingPlan(on day: Date, modelContext: ModelContext) -> DailyPlan? {
        let descriptor = FetchDescriptor<DailyPlan>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let plans = try? modelContext.fetch(descriptor) else { return nil }
        return plans.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    /// Sessions that actually have logged work, newest first.
    private static func completedSessions(modelContext: ModelContext) -> [WorkoutSession] {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { session in
            session.entries.contains { !$0.isSkipped && !$0.workingSets.isEmpty }
        }
    }

    private static func lastSession(
        matching day: SplitDay,
        in sessions: [WorkoutSession],
        before date: Date,
        split: TrainingSplit,
        lookup: [String: Exercise]
    ) -> WorkoutSession? {
        sessions.first { session in
            session.date < date && splitDay(of: session, in: split, lookup: lookup) == day
        }
    }

    private static func exerciseLookup(modelContext: ModelContext) -> [String: Exercise] {
        let descriptor = FetchDescriptor<Exercise>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func roundToIncrement(
        _ weight: Double,
        for exerciseName: String,
        lookup: [String: Exercise]
    ) -> Double {
        let equipment = lookup[exerciseName.lowercased()]?.equipment
        let increment = equipment?.defaultIncrement ?? 5.0
        guard increment > 0 else { return weight }
        return (weight / increment).rounded() * increment
    }

    private static func daysBetween(_ a: Date, _ b: Date) -> Int {
        Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

// MARK: - Duration formatting

extension TimeInterval {
    /// "1h 20m" / "45m" — for the cross-training flag headline.
    var formattedDurationShort: String {
        let totalMinutes = Int(self) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
