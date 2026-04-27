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

    /// Produce the strip's day list — past 3, today, next 3 days (7 total).
    /// `now` is injected for testability; pass `Date()` from the call site.
    static func computeWeek(
        sessions: [WorkoutSession],
        pins: [MuscleGroupPin],
        seedPatterns: [SeedPattern],
        now: Date = Date()
    ) -> [DayIntent] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Pre-bucket sessions by their date's weekday, restricted to the
        // rolling window. The pattern signal lives in this bucket.
        let windowStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let recentSessions = sessions.filter { $0.date >= windowStart }
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

        // Most-recent-completed-day-per-muscle index, used for the fallback
        // "least recently trained" pick when neither pattern nor seed apply.
        let mostRecentByMuscle: [MuscleGroup: Date] = recentSessions.reduce(into: [:]) { acc, s in
            for mg in s.muscleGroups {
                if (acc[mg] ?? .distantPast) < s.date { acc[mg] = s.date }
            }
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
                pinsByDay: pinsByDay,
                seedByWeekday: seedByWeekday,
                mostRecentByMuscle: mostRecentByMuscle
            ))
        }
        return days
    }

    /// Convenience for the planner pipeline — extract today's targetMuscle
    /// without rebuilding the full strip.
    static func targetMuscleForToday(
        sessions: [WorkoutSession],
        pins: [MuscleGroupPin],
        seedPatterns: [SeedPattern],
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

        if let (modal, conf) = modalMuscle(in: sameDayofWeek), sameDayofWeek.count >= 2 {
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
        pinsByDay: [Date: MuscleGroupPin],
        seedByWeekday: [Int: SeedPattern],
        mostRecentByMuscle: [MuscleGroup: Date]
    ) -> DayIntent {
        // 1. Past or today with a logged session → completed cell.
        if offset <= 0,
           let logged = sessions.first(where: { cal.isDate($0.date, inSameDayAs: date) }) {
            // Take the first muscle group as primary; multi-muscle is shown
            // by the cell as the first chip + an underline hint.
            let primary = logged.muscleGroups.first
            return DayIntent(
                date: date,
                muscle: primary,
                label: primary == nil ? (logged.sessionName ?? "Session") : nil,
                source: offset == 0 ? .today : .completed,
                note: nil
            )
        }

        // 2. Pin (today or future) wins over prediction.
        if let pin = pinsByDay[date] {
            return DayIntent(
                date: date,
                muscle: pin.muscleGroup,
                label: pin.label,
                source: offset == 0 ? .today : .pinned,
                note: pin.note
            )
        }

        // 3. Today, no pin, no logged session → predicted muscle for today.
        // This is the strip's anchor cell — show the prediction with the
        // .today styling so the user can immediately tap to lock it.
        if offset == 0 {
            let (m, _) = predict(
                for: date, cal: cal,
                sessionsByWeekday: sessionsByWeekday,
                seedByWeekday: seedByWeekday,
                mostRecentByMuscle: mostRecentByMuscle
            )
            return DayIntent(date: date, muscle: m, label: nil, source: .today, note: nil)
        }

        // 4. Future cell, no pin → predict (or unknown).
        let (m, conf) = predict(
            for: date, cal: cal,
            sessionsByWeekday: sessionsByWeekday,
            seedByWeekday: seedByWeekday,
            mostRecentByMuscle: mostRecentByMuscle
        )
        if m == nil {
            return DayIntent(date: date, muscle: nil, label: nil, source: .unknown, note: nil)
        }
        // Use predicted regardless of confidence — the cell visual softens
        // when confidence is low, and the user can always pin to override.
        _ = conf
        return DayIntent(date: date, muscle: m, label: nil, source: .predicted, note: nil)
    }

    // MARK: - Prediction

    /// Returns the predicted muscle and a 0–1 confidence for `date`.
    /// Order: weekday-modal (real data) → seed → least-recently-trained.
    private static func predict(
        for date: Date,
        cal: Calendar,
        sessionsByWeekday: [Int: [WorkoutSession]],
        seedByWeekday: [Int: SeedPattern],
        mostRecentByMuscle: [MuscleGroup: Date]
    ) -> (MuscleGroup?, Double?) {
        let wd = cal.component(.weekday, from: date)

        // Real data path — needs ≥2 candidates to be a "pattern" not a coincidence.
        if let bucket = sessionsByWeekday[wd], bucket.count >= 2 {
            if let (modal, conf) = modalMuscle(in: bucket) {
                return (modal, conf)
            }
        }

        // Seed fallback — flat 0.5 confidence, since it's a guess from goals.
        if let seed = seedByWeekday[wd], let m = seed.muscleGroup {
            return (m, 0.5)
        }

        // Last resort — pick the least-recently-trained muscle so we suggest
        // "even rotation" rather than nothing. Confidence stays low (0.4)
        // so the cell renders soft.
        if !mostRecentByMuscle.isEmpty {
            let oldest = mostRecentByMuscle.min { $0.value < $1.value }
            return (oldest?.key, 0.4)
        }

        return (nil, nil)
    }

    /// Find the most-frequent primary muscle across a session bucket, plus
    /// the share-of-bucket confidence. Ties broken by alphabetical order
    /// for determinism.
    private static func modalMuscle(in sessions: [WorkoutSession]) -> (MuscleGroup, Double)? {
        guard !sessions.isEmpty else { return nil }
        var counts: [MuscleGroup: Int] = [:]
        for s in sessions {
            // Use first listed muscle as primary — matches the strip's "one
            // muscle per cell" model. Multi-muscle session days lose the
            // tail muscles in the pattern signal; that's an accepted
            // trade-off (the user's MODAL Mon focus is what matters).
            if let first = s.muscleGroups.first {
                counts[first, default: 0] += 1
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
