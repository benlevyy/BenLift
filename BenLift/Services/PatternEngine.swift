import Foundation

// MARK: - PatternEngine
//
// Pure functions that produce the Week Strip's day list from raw inputs:
// - completed WorkoutSessions (last 21 days)
// - active MuscleGroupPins
// - SeedPatterns (used only when real history is too sparse)
//
// The engine is the single source of truth for what each calendar cell
// should display. It is also where `targetMuscle` for today is decided —
// that decision flows downstream into the planner without an LLM call.
//
// Design notes:
// - Pure: takes inputs, returns a value. No SwiftData reads, no
//   side-effects. Wire it via the view's @Query; that keeps SwiftUI's
//   reactivity intact and the engine trivially testable.
// - Window: 21 days back is enough for a 3-week modal-by-weekday signal
//   without dragging in stale phases. Adjust `Self.lookbackDays` to tune.
// - Confidence: the share of the modal weekday's sessions that match the
//   modal muscle. e.g., 4/4 = 1.0 (rock solid), 2/3 = 0.67 (probable),
//   1/2 = 0.5 (weak). The view softens prediction visuals at < 0.6.

struct PatternEngine {
    static let lookbackDays = 21
    static let strongConfidence = 0.6
    /// Modal-by-weekday needs at least this many sessions in the bucket to
    /// claim a pattern. Below this, we don't predict — better to show `?`
    /// and let the user pin than to alternate weak guesses (which is what
    /// happened on Ben's sparse 21-day window: 1–2 sessions per weekday
    /// flipped between quads/shoulders depending on which one happened
    /// to be most recent).
    static let minPatternSamples = 3

    /// Cross-training record from HealthKit (climbing, running, etc.).
    /// Same shape as `HealthKitService.fetchRecentActivities()` returns.
    typealias ActivityRecord = (
        type: String, date: Date, duration: TimeInterval,
        calories: Double?, source: String
    )

    /// Produce the strip's day list — past 3, today, next 3 days (7 total).
    /// `now` is injected for testability; pass `Date()` from the call site.
    /// `exerciseMuscleLookup` maps an exercise's display name to its primary
    /// muscle group — used to derive a session's primary muscle from actual
    /// training volume rather than from the order of `muscleGroups[]` (which
    /// is non-deterministic depending on whether the session came from the
    /// AI plan, manual entry, or watch sync).
    static func computeWeek(
        sessions: [WorkoutSession],
        pins: [MuscleGroupPin],
        seedPatterns: [SeedPattern],
        activities: [ActivityRecord] = [],
        exerciseMuscleLookup: [String: MuscleGroup] = [:],
        now: Date = Date()
    ) -> [DayIntent] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Pre-bucket sessions by their date's weekday, restricted to the
        // rolling window. The pattern signal lives in this bucket.
        let windowStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let recentSessions = sessions.filter { $0.date >= windowStart }

        // Index HealthKit activities by startOfDay. Used to color past days
        // that were "training" (climbing, running) even though no
        // WorkoutSession was logged. Lifted sessions still beat activities.
        let activitiesByDay: [Date: [ActivityRecord]] = activities.reduce(into: [:]) { acc, act in
            acc[cal.startOfDay(for: act.date), default: []].append(act)
        }

        // Pre-compute primary muscle per session ONCE — costs O(entries) per
        // session, much cheaper than recomputing per cell / per pattern call.
        let primaryByID: [UUID: MuscleGroup] = recentSessions.reduce(into: [:]) { acc, s in
            if let m = primaryMuscle(of: s, lookup: exerciseMuscleLookup) {
                acc[s.id] = m
            }
        }

        let sessionsByWeekday: [Int: [WorkoutSession]] = Dictionary(grouping: recentSessions) {
            cal.component(.weekday, from: $0.date)
        }

        // Map pins by startOfDay for O(1) lookup. The model already aligns
        // its `date` to startOfDay on insert, but defensively re-align here
        // for safety against pins inserted via raw construction.
        let pinsByDay: [Date: MuscleGroupPin] = pins.reduce(into: [:]) { acc, pin in
            acc[cal.startOfDay(for: pin.date)] = pin
        }

        // Map seed patterns by weekday — used only when real history is
        // sparse. SeedSource doesn't affect lookup, just provenance.
        let seedByWeekday: [Int: SeedPattern] = seedPatterns.reduce(into: [:]) { acc, seed in
            acc[seed.weekday] = seed
        }

        // Most-recent-completed-day-per-muscle index — uses derived primary
        // (not the muscleGroups[] array) so cross-muscle days are scored
        // by what they actually trained most.
        let mostRecentByMuscle: [MuscleGroup: Date] = recentSessions.reduce(into: [:]) { acc, s in
            guard let m = primaryByID[s.id] else { return }
            if (acc[m] ?? .distantPast) < s.date { acc[m] = s.date }
        }

        // Build the 7-cell window: 3 days back → today → 3 days forward.
        var days: [DayIntent] = []
        for offset in -3...3 {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            days.append(buildDay(
                for: date,
                offset: offset,
                today: today,
                cal: cal,
                sessions: recentSessions,
                sessionsByWeekday: sessionsByWeekday,
                primaryByID: primaryByID,
                activitiesByDay: activitiesByDay,
                pinsByDay: pinsByDay,
                seedByWeekday: seedByWeekday
            ))
        }
        return days
    }

    // MARK: - Primary muscle inference
    //
    // A session's "primary muscle" is the muscle hit by the most exercises
    // (one-vote-per-exercise), NOT `muscleGroups.first`. The `muscleGroups`
    // array is metadata: its order depends on whether the session came from
    // the AI plan, manual entry, or watch sync, so it's not a reliable
    // primary signal. Counting actual exercises is — a "push" session with
    // 4 chest exercises and 1 lateral-raise should read as chest, not
    // shoulders.
    //
    // Tie-break: alphabetical for determinism. Fallback to muscleGroups[0]
    // when no exercises (or no entries match the lookup), then to
    // category-derived guess for legacy sessions.
    static func primaryMuscle(of session: WorkoutSession, lookup: [String: MuscleGroup]) -> MuscleGroup? {
        if !session.entries.isEmpty && !lookup.isEmpty {
            var counts: [MuscleGroup: Int] = [:]
            for entry in session.entries {
                if let m = lookup[entry.exerciseName] {
                    counts[m, default: 0] += 1
                }
            }
            if let best = counts.max(by: { lhs, rhs in
                lhs.value != rhs.value
                    ? lhs.value < rhs.value
                    : lhs.key.rawValue > rhs.key.rawValue
            }) {
                return best.key
            }
        }
        if let first = session.muscleGroups.first { return first }
        return nil
    }

    /// Convenience for the planner pipeline — extract today's targetMuscle
    /// without rebuilding the full strip.
    static func targetMuscleForToday(
        sessions: [WorkoutSession],
        pins: [MuscleGroupPin],
        seedPatterns: [SeedPattern],
        exerciseMuscleLookup: [String: MuscleGroup] = [:],
        now: Date = Date()
    ) -> (muscle: MuscleGroup?, source: PlannerMuscleSource, confidence: Double?) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Pin wins.
        if let pin = pins.first(where: { cal.isDate($0.date, inSameDayAs: today) }),
           let m = pin.muscleGroup {
            return (m, .pinned, 1.0)
        }

        // Pattern from rolling window.
        let windowStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let recent = sessions.filter { $0.date >= windowStart }
        let weekday = cal.component(.weekday, from: today)
        let sameDayofWeek = recent.filter { cal.component(.weekday, from: $0.date) == weekday }

        let primaryByID: [UUID: MuscleGroup] = sameDayofWeek.reduce(into: [:]) { acc, s in
            if let m = primaryMuscle(of: s, lookup: exerciseMuscleLookup) {
                acc[s.id] = m
            }
        }

        if let (modal, conf) = modalMuscle(in: sameDayofWeek, primaryByID: primaryByID),
           sameDayofWeek.count >= minPatternSamples {
            return (modal, .predicted, conf)
        }

        // Seed fallback.
        if let seed = seedPatterns.first(where: { $0.weekday == weekday }),
           let m = seed.muscleGroup {
            return (m, .fallback, 0.5)
        }

        // Nothing — caller (deterministic engine) handles this case.
        return (nil, .fallback, nil)
    }

    // MARK: - Cell construction

    private static func buildDay(
        for date: Date,
        offset: Int,
        today: Date,
        cal: Calendar,
        sessions: [WorkoutSession],
        sessionsByWeekday: [Int: [WorkoutSession]],
        primaryByID: [UUID: MuscleGroup],
        activitiesByDay: [Date: [ActivityRecord]],
        pinsByDay: [Date: MuscleGroupPin],
        seedByWeekday: [Int: SeedPattern]
    ) -> DayIntent {
        // 1. Past or today with a logged session → completed cell.
        // Primary muscle from exercise-count, not `muscleGroups.first` — see
        // `primaryMuscle(of:)` rationale.
        if offset <= 0,
           let logged = sessions.first(where: { cal.isDate($0.date, inSameDayAs: date) }) {
            let primary = primaryByID[logged.id]
            return DayIntent(
                date: date,
                muscle: primary,
                label: primary == nil ? (logged.sessionName ?? "Session") : nil,
                source: offset == 0 ? .today : .completed,
                note: nil
            )
        }

        // 2. Past day, no lifted session → check HealthKit cross-activity.
        // A 60-min climb counts as a real training day for the purposes of
        // visualizing the user's week. Pick the longest activity if multiple.
        if offset < 0 {
            if let acts = activitiesByDay[date], let longest = acts.max(by: { $0.duration < $1.duration }) {
                return DayIntent(
                    date: date,
                    muscle: nil,
                    label: activityLabel(longest),
                    source: .completed,
                    note: nil
                )
            }
            // Genuinely empty past day → rest.
            return DayIntent(
                date: date,
                muscle: nil,
                label: "Rest",
                source: .completed,
                note: nil
            )
        }

        // 3. Pin (today or future) wins over prediction.
        if let pin = pinsByDay[date] {
            return DayIntent(
                date: date,
                muscle: pin.muscleGroup,
                label: pin.label,
                source: offset == 0 ? .today : .pinned,
                note: pin.note
            )
        }

        // 4. Today, no pin, no logged session → predicted muscle for today.
        // This is the strip's anchor cell — show the prediction with the
        // .today styling so the user can immediately tap to lock it.
        if offset == 0 {
            let m = predict(
                for: date, cal: cal,
                sessionsByWeekday: sessionsByWeekday,
                primaryByID: primaryByID,
                seedByWeekday: seedByWeekday
            )
            return DayIntent(date: date, muscle: m, label: nil, source: .today, note: nil)
        }

        // 5. Future cell, no pin → predict (or unknown).
        if let m = predict(
            for: date, cal: cal,
            sessionsByWeekday: sessionsByWeekday,
            primaryByID: primaryByID,
            seedByWeekday: seedByWeekday
        ) {
            return DayIntent(date: date, muscle: m, label: nil, source: .predicted, note: nil)
        }
        return DayIntent(date: date, muscle: nil, label: nil, source: .unknown, note: nil)
    }

    /// Compact label for a HealthKit activity cell. Capitalize and add
    /// minutes if non-trivial (≥10 min). e.g., "Climbing 65m".
    private static func activityLabel(_ act: ActivityRecord) -> String {
        let title = act.type.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        let minutes = Int(act.duration / 60)
        return minutes >= 10 ? "\(title) \(minutes)m" : title
    }

    // MARK: - Prediction

    /// Returns the predicted muscle for `date`, or nil when the signal is
    /// too weak to claim. Order: weekday-modal (real data, ≥3 sessions) →
    /// seed pattern → nil (cell renders as `?`).
    ///
    /// Why no "least recently trained" fallback: with sparse data, that
    /// path alternates between muscles as days pass and creates the
    /// "every day is quads/shoulders" oscillation Ben observed. Better
    /// to show `?` and let the user pin than to invent confidence.
    private static func predict(
        for date: Date,
        cal: Calendar,
        sessionsByWeekday: [Int: [WorkoutSession]],
        primaryByID: [UUID: MuscleGroup],
        seedByWeekday: [Int: SeedPattern]
    ) -> MuscleGroup? {
        let wd = cal.component(.weekday, from: date)

        // Real data path — needs minPatternSamples (3) candidates so a one-
        // off Tuesday doesn't become "your Tuesday plan."
        if let bucket = sessionsByWeekday[wd], bucket.count >= minPatternSamples {
            if let (modal, _) = modalMuscle(in: bucket, primaryByID: primaryByID) {
                return modal
            }
        }

        // Seed fallback — only fires if the bootstrap LLM has populated it.
        if let seed = seedByWeekday[wd], let m = seed.muscleGroup {
            return m
        }

        return nil
    }

    /// Find the most-frequent primary muscle across a session bucket, plus
    /// the share-of-bucket confidence. Uses the pre-computed `primaryByID`
    /// (exercise-count-derived) rather than `muscleGroups.first` so the
    /// pattern signal reflects what the user actually trained, not metadata
    /// ordering. Ties broken alphabetically for determinism.
    private static func modalMuscle(
        in sessions: [WorkoutSession],
        primaryByID: [UUID: MuscleGroup]
    ) -> (MuscleGroup, Double)? {
        guard !sessions.isEmpty else { return nil }
        var counts: [MuscleGroup: Int] = [:]
        for s in sessions {
            if let m = primaryByID[s.id] {
                counts[m, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : lhs.key.rawValue > rhs.key.rawValue  // alpha ascending → break to lower name
        }) else { return nil }
        let confidence = Double(best.value) / Double(sessions.count)
        return (best.key, confidence)
    }
}

// MARK: - PlannerMuscleSource
//
// Mirrors the `targetMuscleSource` field in the daily_plan_v5 input
// contract. Used by the planner to decide whether to soften language
// in the LLM prompt or the deterministic baseline's recommendation text.

enum PlannerMuscleSource: String {
    case pinned
    case predicted
    case fallback
}
