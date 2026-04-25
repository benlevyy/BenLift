import Foundation
import SwiftData

/// Compact, decision-ready snapshot of the user — the single structured
/// object that every AI prompt consumes. Replaces the per-prompt pattern
/// of dumping raw sessions + weekly-volume tables + HK text + freeform
/// intelligence strings.
///
/// Design principles (discussed extensively with the user):
///
/// - **Raw data stays in SwiftData / HealthKit / UserDefaults** as the
///   source of truth. `UserState` is *derived*, never persisted. If the
///   user logs a set / taps a chip / sets a rule, the next call to
///   `UserState.current(...)` reflects it.
/// - **Aggregates for decisions, raw data for discovery.** Most prompts
///   use only `UserState`. The intelligence refresh separately gets a
///   raw 8-week supplement (in `IntelligenceViewModel`) so Sonnet can
///   find correlations the aggregates lose.
/// - **Tiered attention.** Tier 1 (Today + Constraints) lives at the top
///   of the prompt — most decision-relevant, always included. Tier 4
///   (Observations, Rules) carries durable AI-learned patterns and
///   explicit user decisions; also always included. Tier 2 (Preferences,
///   Strength, MuscleState) is the user's identity. Tier 3 (Recent
///   sessions, Recovery, CrossActivity) is context that plan-gen uses
///   and adapt doesn't need.
/// - **Deterministic in-app aggregation.** e1RM math, frequency counts,
///   days-since — all done in Swift. AI's job is to decide, not parse.
///
/// Encoded as JSON into prompts. Field names are kept concise but not
/// cryptic; the model handles clear JSON very well and cryptic field
/// names risk confusion without real token savings.
struct UserState: Codable {
    let today: TodayBlock
    let constraints: Constraints
    let preferences: Preferences
    let strength: [String: StrengthEntry]  // keyed by exercise name
    let muscleState: [String: MuscleStateEntry]  // keyed by muscle group
    let recent: [RecentSession]
    let recovery: RecoveryBlock
    let crossActivity: [CrossActivityEntry]
    let observations: [ObservationBlock]
    let rules: [RuleBlock]

    /// JSON payload for embedding in a prompt. Pretty-printed because
    /// the model parses it faster and debugging prints are readable.
    /// Token cost of pretty-print vs. compact is negligible (~5-10%)
    /// for the size we're at.
    func toPromptJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - Tier 1

    /// Today's user input — the variable signal the AI should weight
    /// heaviest for today's decisions. Muscle overrides carry their
    /// timestamp so the AI can discount stale reports.
    struct TodayBlock: Codable {
        let feeling: Int            // 1-5
        let availableTime: Int?     // minutes, nil = no constraint
        let concerns: String?       // freeform user note; nil if empty
        let muscleOverrides: [String: MuscleOverrideEntry]
        /// Deterministic working-set budget for today's session, derived
        /// from `availableTime` and the user's `preferences.sessionShape
        /// .preferredRestSeconds`. nil when no time limit is set. The AI
        /// is instructed to plan exactly this many working sets — no
        /// drift, no conservative trimming based on its own timing guess.
        let targetWorkingSets: Int?
    }

    struct MuscleOverrideEntry: Codable {
        let status: String          // fresh/ready/recovering/sore
        let reportedAgo: String     // "2h", "1d", etc. relative for model
    }

    /// Hard constraints that shape every decision. Injuries lead —
    /// safety-critical. Goal + experience frame everything else.
    struct Constraints: Codable {
        let injuries: String?
        let userNotes: String?
        let goal: String?
        let experience: String?
        let daysPerWeek: Int?
    }

    // MARK: - Tier 2

    /// Who the user is, as a lifter. Derived from frequency analysis of
    /// sessions + UserDefaults + style inference. Rituals = high-signal
    /// staples; rotation = lower-frequency alternates grouped by muscle.
    struct Preferences: Codable {
        /// Exercises appearing in ≥60% of sessions over the last 8
        /// weeks (among sessions that could have included them, loosely
        /// — we simplify to "≥60% of total sessions"). Sorted by
        /// appearance rate desc.
        let rituals: [String]
        /// Exercises appearing multiple times but below the ritual
        /// threshold, grouped by primary muscle. Tells the AI "here's
        /// what the user cycles through for this slot."
        let rotation: [String: [String]]
        let sessionShape: SessionShape
        /// Free-form stylistic descriptors — "push-to-failure" inferred
        /// from fractional-rep logging, etc. Empty array when no signal.
        let style: [String]
    }

    struct SessionShape: Codable {
        let avgExercises: Int
        let avgSetsPerExercise: Int
        let preferredRestSeconds: Int
    }

    /// Current strength baseline for an exercise the user trains
    /// regularly. Only exercises done 3+ times in the last 60 days are
    /// included — otherwise it's not really "their" weight yet.
    struct StrengthEntry: Codable {
        let e1rm: Int               // best estimated 1RM in window
        let working: Int            // most recent working-set weight
        let lastTrained: String     // "3d"
        let trend4wk: String        // "+5 lb" / "flat" / "-2.5 lb"
        let bodyweight: Bool        // pull-ups / dips / etc.
    }

    /// Per muscle — recovery read at a glance. Only groups the user
    /// actually trains are included; zero-zero rows are noise.
    /// `lastSource` distinguishes strength sessions from cross-activity
    /// load (climbing heavily taxes pull muscles even though no sets
    /// are logged), so the AI can reason about why a muscle is fatigued.
    struct MuscleStateEntry: Codable {
        let lastTrained: String     // "2d"
        let setsThisWeek: Int
        let status: String          // fresh/ready/recovering/sore
        let lastSource: String      // "strength" / "climbing" / "running" / ...
    }

    // MARK: - Tier 3

    struct RecentSession: Codable {
        let date: String            // "3d ago"
        let focus: [String]         // muscle groups
        let feeling: Int?
        let duration: Int?          // minutes
        let volume: Int             // total working-set volume (lbs)
        let topLifts: [String: String]  // exercise → "185×6"
    }

    struct RecoveryBlock: Codable {
        let sleep7d: Double?
        let hrv7d: Double?
        let rhrBaseline: Double?
        let sleepTrend: String?     // "stable" / "improving" / "declining"
        let hrvTrend: String?
    }

    struct CrossActivityEntry: Codable {
        let type: String            // "climbing" / "running" / ...
        let when: String            // "1d"
        let durationMin: Int
        /// Active kcal per minute, rounded. nil when HK didn't record
        /// calories or the workout was too short to compute reliably.
        let kcalPerMin: Int?
        /// "light" / "moderate" / "hard" / "unknown" — bucketed from
        /// kcalPerMin so the AI can distinguish a 20-min warm-up climb
        /// from a 90-min redpoint session without re-deriving.
        let intensity: String
    }

    // MARK: - Tier 4

    /// Top ~5 active AI-discovered patterns. Snapshot of the current
    /// Observation rows in the DB. AI can weigh these as soft priors.
    struct ObservationBlock: Codable {
        let kind: String
        let subject: String
        let text: String
        let confidence: String
        let lastSeenAgo: String
    }

    /// All active user-set rules. The AI is instructed to respect
    /// `exerciseOut` rules deterministically — never suggest an excluded
    /// exercise unless the user adds it back.
    struct RuleBlock: Codable {
        let kind: String
        let subject: String
        let target: String?
        let reason: String?
        let since: String           // "3d"
    }

    // MARK: - Aggregation

    /// Build the snapshot from raw sources. Pure function — no
    /// side-effects, no caching. Cheap enough to recompute per call
    /// (~20-50ms on a healthy dataset).
    @MainActor
    static func current(
        modelContext: ModelContext,
        program: TrainingProgram?,
        intelligence: UserIntelligence?,
        checkIn: CheckInInput,
        healthContext: HealthContext?,
        healthAverages: HealthKitService.HealthAverages? = nil,
        recentActivities: [ActivityTuple] = []
    ) -> UserState {
        let now = Date()

        // --- Sessions window: 8 weeks for preferences / strength, 7d
        // for this-week volume, 5 most recent for the "recent" tier.
        let sessions8wk = fetchSessions(since: 56, modelContext: modelContext)
        let sessions7d = sessions8wk.filter {
            $0.date >= Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        }
        let sessions60d = sessions8wk.filter {
            $0.date >= Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        }
        let recentSessions = Array(sessions8wk.prefix(5))

        let exerciseLookup = DefaultExercises.buildMuscleGroupLookup(from: modelContext)

        // --- Tier 2 (built first so Tier 1 can derive targetWorkingSets
        // from the user's actual rest-between-sets pattern). Reordering
        // here is a build-time concern only; the final struct still lists
        // tiers in their read-time priority order.
        let preferences = preferencesBlock(
            sessions: sessions8wk,
            exerciseLookup: exerciseLookup,
            now: now
        )

        // --- Tier 1
        let today = todayBlock(
            checkIn: checkIn,
            restSeconds: preferences.sessionShape.preferredRestSeconds,
            now: now
        )
        let constraints = constraintsBlock(program: program, intelligence: intelligence)

        let strength = strengthBlock(sessions: sessions60d, now: now)
        let muscleState = muscleStateBlock(
            sessions: sessions8wk,
            thisWeek: sessions7d,
            activities: recentActivities,
            exerciseLookup: exerciseLookup,
            now: now
        )

        // --- Tier 3
        let recent = recentBlock(sessions: recentSessions, now: now)
        let recovery = recoveryBlock(healthContext: healthContext, averages: healthAverages)
        let crossActivity = crossActivityBlock(activities: recentActivities, now: now)

        // --- Tier 4
        let observations = observationsBlock(modelContext: modelContext, now: now)
        let rules = rulesBlock(modelContext: modelContext, now: now)

        return UserState(
            today: today,
            constraints: constraints,
            preferences: preferences,
            strength: strength,
            muscleState: muscleState,
            recent: recent,
            recovery: recovery,
            crossActivity: crossActivity,
            observations: observations,
            rules: rules
        )
    }

    // MARK: - Input Types

    /// Snapshot of the transient check-in inputs the coach VM holds in
    /// memory. Passed in rather than reading from a shared store so
    /// `UserState` stays free of cross-VM coupling.
    struct CheckInInput {
        let feeling: Int
        let availableTime: Int?
        let concerns: String
    }

    typealias ActivityTuple = (
        type: String, date: Date, duration: TimeInterval,
        calories: Double?, source: String
    )
}

// MARK: - Tier Builders (private helpers)

private extension UserState {

    @MainActor
    static func fetchSessions(since days: Int, modelContext: ModelContext) -> [WorkoutSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= cutoff },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: Tier 1

    static func todayBlock(
        checkIn: CheckInInput,
        restSeconds: Int,
        now: Date
    ) -> TodayBlock {
        var overrides: [String: MuscleOverrideEntry] = [:]
        for (muscle, entry) in MuscleOverrideStore.load() {
            overrides[muscle] = MuscleOverrideEntry(
                status: entry.status,
                reportedAgo: relativeAgo(from: entry.setAt, now: now)
            )
        }
        return TodayBlock(
            feeling: checkIn.feeling,
            availableTime: checkIn.availableTime,
            concerns: checkIn.concerns.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            muscleOverrides: overrides,
            targetWorkingSets: targetWorkingSets(
                availableMinutes: checkIn.availableTime,
                restSeconds: restSeconds
            )
        )
    }

    /// Deterministic "how many working sets fit" budget. Replaces the
    /// AI's fuzzy mental math with a concrete integer the prompt reader
    /// is instructed to match.
    ///
    /// Model: per-set minutes = 1 (work) + rest/60. Overhead = 5 min
    /// (warm-ups + transitions). Clamp low so an absurdly tight session
    /// still returns at least 4 sets rather than 0 or negative.
    ///
    /// Returns nil when no time limit is set — the AI is then free to
    /// pick whatever feels right.
    static func targetWorkingSets(
        availableMinutes: Int?,
        restSeconds: Int
    ) -> Int? {
        guard let mins = availableMinutes, mins > 0 else { return nil }
        let rest = restSeconds > 0 ? restSeconds : 150
        let perSetMin = 1.0 + Double(rest) / 60.0
        let budget = Double(mins) - 5.0
        guard budget > 0 else { return 4 }
        return max(4, Int((budget / perSetMin).rounded(.down)))
    }

    static func constraintsBlock(
        program: TrainingProgram?,
        intelligence: UserIntelligence?
    ) -> Constraints {
        Constraints(
            injuries: intelligence?.injuries.nilIfEmpty,
            userNotes: intelligence?.userNotes.nilIfEmpty,
            goal: program?.goal.nilIfEmpty,
            experience: program?.experienceLevel.nilIfEmpty,
            daysPerWeek: program?.daysPerWeek
        )
    }

    // MARK: Tier 2

    /// Ritual threshold: appears in ≥60% of total sessions in the
    /// window. (The user picked this in our spec discussion — loose
    /// enough to include the staples they skip once or twice, tight
    /// enough to exclude occasional variety.)
    static let ritualAppearanceThreshold: Double = 0.60

    static func preferencesBlock(
        sessions: [WorkoutSession],
        exerciseLookup: [String: MuscleGroup],
        now: Date
    ) -> Preferences {
        let totalSessions = sessions.count

        // Count appearances per exercise. An exercise with logged sets
        // OR marked skipped still counts as "on the plan this session"
        // — we're measuring planning presence, not execution.
        var appearances: [String: Int] = [:]
        for session in sessions {
            var seen = Set<String>()
            for entry in session.entries {
                guard !seen.contains(entry.exerciseName) else { continue }
                seen.insert(entry.exerciseName)
                appearances[entry.exerciseName, default: 0] += 1
            }
        }

        // Rituals: ≥60% appearance, sorted by rate desc.
        let threshold = max(1, Int(ceil(Double(totalSessions) * ritualAppearanceThreshold)))
        let rituals = appearances
            .filter { $0.value >= threshold }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.key }

        // Rotation: below-ritual exercises that appeared 2+ times,
        // grouped by primary muscle. Singletons drop (not a pattern).
        let ritualSet = Set(rituals)
        var rotationRaw: [MuscleGroup: [(String, Int)]] = [:]
        for (name, count) in appearances where count >= 2 && !ritualSet.contains(name) {
            guard let muscle = exerciseLookup[name] else { continue }
            rotationRaw[muscle, default: []].append((name, count))
        }
        var rotation: [String: [String]] = [:]
        for (muscle, items) in rotationRaw {
            let sorted = items.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
            rotation[muscle.rawValue] = sorted
        }

        // Session shape: averages from the window. Rounded to ints to
        // stop trivial fractional drift — "3.17 sets" is noise.
        let shape = sessionShape(sessions: sessions)

        let style = inferStyle(sessions: sessions)

        return Preferences(
            rituals: rituals,
            rotation: rotation,
            sessionShape: shape,
            style: style
        )
    }

    static func sessionShape(sessions: [WorkoutSession]) -> SessionShape {
        guard !sessions.isEmpty else {
            return SessionShape(avgExercises: 0, avgSetsPerExercise: 0, preferredRestSeconds: 150)
        }
        let exercisesPerSession = sessions.map { $0.entries.filter { !$0.sets.isEmpty }.count }
        let avgExercises = exercisesPerSession.reduce(0, +) / max(1, exercisesPerSession.count)
        let setsPerExerciseAvg: Int = {
            let allCounts = sessions.flatMap { $0.entries.map { $0.sets.filter { !$0.isWarmup }.count } }
                .filter { $0 > 0 }
            guard !allCounts.isEmpty else { return 0 }
            return allCounts.reduce(0, +) / allCounts.count
        }()
        let userRest = UserDefaults.standard.double(forKey: "restTimerDuration")
        let rest = userRest > 0 ? Int(userRest) : 150
        return SessionShape(
            avgExercises: avgExercises,
            avgSetsPerExercise: setsPerExerciseAvg,
            preferredRestSeconds: rest
        )
    }

    /// Style heuristics. Keep this list tight — each entry should be
    /// something the AI can act on. If we start accumulating noise,
    /// move things into observations instead.
    static func inferStyle(sessions: [WorkoutSession]) -> [String] {
        var styles: [String] = []
        // Fractional reps = deliberately pushing to failure. Signal that
        // the AI should NOT flag rep drop-off or failed reps as a
        // problem (same flag we set in the system prefix, but now
        // derived from actual data rather than asserted).
        let failedRepCount = sessions.flatMap { $0.entries.flatMap { $0.sets } }
            .filter { $0.reps.truncatingRemainder(dividingBy: 1) != 0 }.count
        if failedRepCount >= 3 {
            styles.append("push-to-failure (uses fractional-rep logging)")
        }
        return styles
    }

    static func strengthBlock(sessions: [WorkoutSession], now: Date) -> [String: StrengthEntry] {
        // Gather all working sets per exercise, in chronological order.
        // Need chronological for lastTrained + trend calculation.
        var byExercise: [String: [(date: Date, set: SetLog)]] = [:]
        for session in sessions {
            for entry in session.entries {
                for set in entry.sets where !set.isWarmup {
                    byExercise[entry.exerciseName, default: []].append((session.date, set))
                }
            }
        }

        var out: [String: StrengthEntry] = [:]
        for (name, records) in byExercise {
            // Unique session count — need 3+ to qualify as "their" lift.
            let sessionDates = Set(records.map { Calendar.current.startOfDay(for: $0.date) })
            guard sessionDates.count >= 3 else { continue }

            let sorted = records.sorted { $0.date < $1.date }
            let e1rmValues = sorted.map {
                StatsEngine.estimatedOneRepMax(weight: $0.set.weight, reps: $0.set.reps)
            }
            let bestE1RM = Int((e1rmValues.max() ?? 0).rounded())
            // Working = latest session's top-weight working set
            let latestDate = sorted.last!.date
            let latestDaySets = sorted.filter {
                Calendar.current.isDate($0.date, inSameDayAs: latestDate)
            }.map(\.set)
            let latestTopWeight = Int((latestDaySets.map(\.weight).max() ?? 0).rounded())

            // Trend = latest e1RM vs. e1RM 4 weeks ago (closest match).
            let fourWkAgo = Calendar.current.date(byAdding: .weekOfYear, value: -4, to: latestDate) ?? latestDate
            let oldEntries = sorted.filter { $0.date <= fourWkAgo }
            let trend: String
            if let oldRef = oldEntries.last {
                let oldE1RM = StatsEngine.estimatedOneRepMax(
                    weight: oldRef.set.weight,
                    reps: oldRef.set.reps
                )
                let currentE1RM = e1rmValues.last ?? 0
                let delta = Int((currentE1RM - oldE1RM).rounded())
                if abs(delta) < 3 {
                    trend = "flat"
                } else if delta > 0 {
                    trend = "+\(delta) lb / 4wk"
                } else {
                    trend = "\(delta) lb / 4wk"
                }
            } else {
                trend = "new"
            }

            let isBW = latestTopWeight == 0
            out[name] = StrengthEntry(
                e1rm: isBW ? 0 : bestE1RM,
                working: latestTopWeight,
                lastTrained: relativeAgo(from: latestDate, now: now),
                trend4wk: trend,
                bodyweight: isBW
            )
        }
        return out
    }

    static func muscleStateBlock(
        sessions: [WorkoutSession],
        thisWeek: [WorkoutSession],
        activities: [ActivityTuple],
        exerciseLookup: [String: MuscleGroup],
        now: Date
    ) -> [String: MuscleStateEntry] {
        var lastTrained: [MuscleGroup: Date] = [:]
        var lastSource: [MuscleGroup: String] = [:]
        var setsThisWeek: [MuscleGroup: Int] = [:]

        // Strength sessions first — set source to "strength" so cross-
        // activity only overrides when it's more recent (the "what last
        // loaded this muscle" question, answered by date, not by kind).
        for session in sessions {
            for entry in session.entries where !entry.sets.isEmpty {
                guard let mg = exerciseLookup[entry.exerciseName] else { continue }
                if lastTrained[mg] == nil || session.date > lastTrained[mg]! {
                    lastTrained[mg] = session.date
                    lastSource[mg] = "strength"
                }
            }
        }
        for session in thisWeek {
            for entry in session.entries {
                guard let mg = exerciseLookup[entry.exerciseName] else { continue }
                setsThisWeek[mg, default: 0] += entry.sets.filter { !$0.isWarmup }.count
            }
        }

        // Cross-activity load from HealthKit. Climbing, running, etc.
        // load real muscles — a climb yesterday shouldn't leave pull
        // muscles showing "fresh" just because no sets were logged.
        // Gated on intensity: "light" sessions (low kcal/min) still show
        // up in the crossActivity list but don't reset the muscle clock,
        // since a 20-min warm-up climb shouldn't flip back from fresh
        // to sore. Moderate/hard/unknown all override when more recent.
        for activity in activities {
            let muscles = musclesLoadedBy(activityType: activity.type)
            guard !muscles.isEmpty else { continue }
            let (_, intensity) = classifyIntensity(
                calories: activity.calories,
                durationSec: activity.duration
            )
            if intensity == "light" { continue }
            for mg in muscles {
                if lastTrained[mg] == nil || activity.date > lastTrained[mg]! {
                    lastTrained[mg] = activity.date
                    lastSource[mg] = activity.type
                }
            }
        }

        var out: [String: MuscleStateEntry] = [:]
        for mg in MuscleGroup.allCases {
            let last = lastTrained[mg]
            let sets = setsThisWeek[mg] ?? 0
            // Skip muscles with no strength history AND no cross-activity
            // load in window AND no sets this week.
            guard last != nil || sets > 0 else { continue }

            let daysSince: Int
            if let last {
                daysSince = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 99
            } else {
                daysSince = 99
            }
            let status: String
            if daysSince >= 4 { status = "fresh" }
            else if daysSince >= 3 { status = "ready" }
            else if daysSince >= 2 { status = "recovering" }
            else { status = "sore" }

            out[mg.rawValue] = MuscleStateEntry(
                lastTrained: last.map { relativeAgo(from: $0, now: now) } ?? "never",
                setsThisWeek: sets,
                status: status,
                lastSource: lastSource[mg] ?? "strength"
            )
        }
        return out
    }

    /// Which muscles an HK activity loads enough to affect recovery.
    /// Conservative list — only muscles that are *meaningfully* taxed.
    /// Climbing mostly hammers pull + grip + core; running is lower-body
    /// + core. Unrecognized types return empty (no effect on muscleState).
    static func musclesLoadedBy(activityType: String) -> [MuscleGroup] {
        switch activityType.lowercased() {
        case "climbing", "rock climbing":
            return [.back, .biceps, .forearms, .shoulders, .core]
        case "running":
            return [.quads, .hamstrings, .calves, .core]
        case "cycling", "biking":
            return [.quads, .hamstrings, .calves]
        case "hiking":
            return [.quads, .hamstrings, .calves, .glutes]
        case "rowing":
            return [.back, .biceps, .quads, .hamstrings, .core]
        case "swimming":
            return [.back, .shoulders, .chest, .core]
        default:
            return []
        }
    }

    // MARK: Tier 3

    static func recentBlock(sessions: [WorkoutSession], now: Date) -> [RecentSession] {
        sessions.map { session in
            var topLifts: [String: String] = [:]
            for entry in session.sortedEntries.prefix(5) {
                if let top = StatsEngine.topSet(sets: entry.sets) {
                    let wStr = top.weight == 0 ? "BW" : "\(Int(top.weight))"
                    topLifts[entry.exerciseName] = "\(wStr)×\(top.reps.formattedReps)"
                }
            }
            return RecentSession(
                date: relativeAgo(from: session.date, now: now),
                focus: session.muscleGroups.map(\.rawValue),
                feeling: session.feeling,
                duration: session.duration.map { Int($0 / 60) },
                volume: Int(session.totalVolume),
                topLifts: topLifts
            )
        }
    }

    static func recoveryBlock(
        healthContext: HealthContext?,
        averages: HealthKitService.HealthAverages?
    ) -> RecoveryBlock {
        RecoveryBlock(
            sleep7d: averages?.avgSleep?.average ?? healthContext?.sleepHours,
            hrv7d: averages?.avgHRV?.average ?? healthContext?.hrv,
            rhrBaseline: averages?.avgRHR?.average ?? healthContext?.restingHR,
            sleepTrend: averages?.avgSleep?.trend,
            hrvTrend: averages?.avgHRV?.trend
        )
    }

    static func crossActivityBlock(
        activities: [ActivityTuple],
        now: Date
    ) -> [CrossActivityEntry] {
        activities.prefix(7).map { act in
            let minutes = Int(act.duration / 60)
            let (kcalPerMin, intensity) = classifyIntensity(
                calories: act.calories,
                durationSec: act.duration
            )
            return CrossActivityEntry(
                type: act.type,
                when: relativeAgo(from: act.date, now: now),
                durationMin: minutes,
                kcalPerMin: kcalPerMin,
                intensity: intensity
            )
        }
    }

    /// Classify a cross-activity by active-calorie burn rate. Uses
    /// generic thresholds that land reasonably across climbing, running,
    /// cycling, etc. — no per-sport tuning yet because Apple HK's active
    /// calorie output is already sport-normalized. Too-short sessions
    /// (<5 min) fall through to "unknown" since kcal/min is noisy when
    /// warm-up calories dominate the sample.
    ///
    /// Thresholds: <6 light · 6-9 moderate · ≥9 hard. Adjust if empirical
    /// data shows misclassification.
    static func classifyIntensity(
        calories: Double?,
        durationSec: TimeInterval
    ) -> (kcalPerMin: Int?, intensity: String) {
        guard let calories, calories > 0, durationSec >= 300 else {
            return (nil, "unknown")
        }
        let rate = calories / (durationSec / 60)
        let bucket: String
        if rate < 6 { bucket = "light" }
        else if rate < 9 { bucket = "moderate" }
        else { bucket = "hard" }
        return (Int(rate.rounded()), bucket)
    }

    // MARK: Tier 4

    @MainActor
    static func observationsBlock(modelContext: ModelContext, now: Date) -> [ObservationBlock] {
        // Top 5 active by lastReinforcedAt — the freshest, most-confirmed
        // AI-discovered patterns. Stale (>90d) ones auto-drop via the
        // refresh job (see IntelligenceViewModel.refreshIntelligence).
        let descriptor = FetchDescriptor<UserObservation>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.lastReinforcedAt, order: .reverse)]
        )
        let observations = (try? modelContext.fetch(descriptor)) ?? []
        return observations.prefix(5).map { obs in
            ObservationBlock(
                kind: obs.kindRaw,
                subject: obs.subject,
                text: obs.text,
                confidence: obs.confidenceRaw,
                lastSeenAgo: relativeAgo(from: obs.lastReinforcedAt, now: now)
            )
        }
    }

    @MainActor
    static func rulesBlock(modelContext: ModelContext, now: Date) -> [RuleBlock] {
        let descriptor = FetchDescriptor<UserRule>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rules = (try? modelContext.fetch(descriptor)) ?? []
        return rules.map { rule in
            RuleBlock(
                kind: rule.kindRaw,
                subject: rule.subject,
                target: rule.target,
                reason: rule.reason,
                since: relativeAgo(from: rule.createdAt, now: now)
            )
        }
    }

    // MARK: Helpers

    /// Relative time formatter for model consumption. "just now" when
    /// <1h, "Xh" under a day, "Xd" otherwise. Model doesn't need minute
    /// precision for anything we're describing.
    static func relativeAgo(from: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(from)
        if interval < 3600 { return "just now" }
        if interval < 86400 {
            return "\(Int(interval / 3600))h"
        }
        let days = Int(interval / 86400)
        return "\(days)d"
    }
}

// MARK: - String utilities

private extension String {
    var nilIfEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
