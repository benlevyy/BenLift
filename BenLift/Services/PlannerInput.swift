import Foundation
import SwiftData

// MARK: - PlannerInput
//
// The single contract every planner path consumes:
// - Deterministic baseline (BaselinePlanner) — produces today's plan from
//   this struct in pure Swift, no LLM call.
// - LLM escalation (daily_plan_v5 prompt) — same struct serialized to JSON
//   and embedded in the system prompt's INPUT block.
// - Iterate prompt — uses a subset (strength + rituals + constraints) for
//   anchoring single-exercise edits.
//
// Built once per planning round by `PlannerInput.build(...)` from raw
// SwiftData + HealthKit + the calendar/PatternEngine. Held briefly in the
// VM, then thrown away. Not persisted — derived state.
//
// Field shapes mirror `evals/prompts/daily_plan_v5.md` line-for-line so
// the LLM call is just `JSONEncoder().encode(plannerInput)` with no
// translation layer in between. Swift contract == prompt contract.

struct PlannerInput: Codable {
    let targetMuscle: String                    // raw MuscleGroup value
    let targetMuscleSource: String              // "pinned" | "predicted" | "fallback"
    let predictionConfidence: Double?           // 0–1, nil unless source = "predicted"

    let futurePins: [FuturePin]
    let recentDays: [RecentDay]
    let recovery: Recovery
    let availableTime: Int                      // minutes
    let targetWorkingSets: Int                  // (availableTime - 5) / (1 + restSec/60)

    let strength: [String: StrengthEntry]       // exercise name → working/e1rm/trend
    let rituals: [String]                       // exercises in ≥60% of sessions
    let rotation: [String: [String]]            // muscle name → preferred alternates

    let constraints: Constraints
    let userProfile: UserProfile

    // MARK: - Subtypes

    struct FuturePin: Codable {
        let date: String                        // ISO8601 date-only
        let muscle: String
    }

    struct RecentDay: Codable {
        let date: String                        // ISO8601 date-only
        let muscle: String                      // primary, derived from exercise count
        let totalVolume: Int                    // lbs
        let topExercises: [String]              // 3 most-set-count names
        let effortScore: Int                    // 1–10 from feeling × 2
        let avgHR: Int?
    }

    struct Recovery: Codable {
        let feeling: Int                        // 1–5
        let sleepHours: Double?
        let restingHR: Int?
        let hrv: Int?
        let daysSinceLastTraining: Int
        let userNote: String?                   // freeform from CoachVM.concerns
    }

    struct StrengthEntry: Codable {
        let working: Double                     // most recent working-set weight
        let e1rm: Double                        // best estimated 1RM (60d window)
        let lastTrained: String                 // "3d", "1w" relative
        let trend4wk: String                    // "+5 lb / 4wk", "flat", etc.
        let bodyweight: Bool
    }

    struct Constraints: Codable {
        let injuries: String?                   // freeform; pulled from UserIntelligence
        let exerciseOut: [String]               // hard rule-outs from UserRule entities
    }

    struct UserProfile: Codable {
        let goal: String                        // TrainingProgram.goal
        let experience: String                  // TrainingProgram.experienceLevel
        let daysPerWeek: Int                    // TrainingProgram.daysPerWeek
    }
}

// MARK: - Aggregator
//
// `PlannerInput.build(...)` is the bridge between SwiftData / HealthKit /
// PatternEngine and the contract above. Pure-ish: it takes the raw inputs
// and the user's check-in state, returns a struct. No persistence, no
// long-running async work.
//
// HealthKit recovery (sleep, HRV, RHR) is fetched separately by the caller
// and passed in via `healthContext` — this keeps the function synchronous
// and testable.

extension PlannerInput {

    @MainActor
    static func build(
        modelContext: ModelContext,
        feeling: Int,
        availableTime: Int?,
        concerns: String,
        healthContext: HealthContext?,
        recentActivities: [PatternEngine.ActivityRecord],
        now: Date = Date()
    ) -> PlannerInput? {
        // Pull SwiftData entities the contract needs.
        let sessions = (try? modelContext.fetch(
            FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        )) ?? []
        let pins = (try? modelContext.fetch(FetchDescriptor<MuscleGroupPin>())) ?? []
        let seedPatterns = (try? modelContext.fetch(FetchDescriptor<SeedPattern>())) ?? []
        let exercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let exerciseLookup = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name, $0.muscleGroup) })

        // Calendar decides today's muscle. If the calendar can't decide and
        // the LLM hasn't run yet either, we have no input — caller falls
        // back to the existing recommend+plan flow.
        let (muscle, source, confidence) = PatternEngine.targetMuscleForToday(
            sessions: sessions,
            pins: pins,
            seedPatterns: seedPatterns,
            exerciseMuscleLookup: exerciseLookup,
            now: now
        )
        guard let targetMuscle = muscle else { return nil }

        // Active program for goal/experience/daysPerWeek.
        let program = (try? modelContext.fetch(
            FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.isActive == true })
        ).first) ?? nil

        // Intelligence carries injuries + freeform notes the AI has read off.
        let intelligence = (try? modelContext.fetch(FetchDescriptor<UserIntelligence>()).first) ?? nil

        // User-set hard rule-outs (e.g., "never Overhead Press").
        let rules = (try? modelContext.fetch(
            FetchDescriptor<UserRule>(predicate: #Predicate { $0.isActive == true })
        )) ?? []
        let exerciseOut = rules
            .filter { $0.kindRaw == "exerciseOut" }
            .map(\.subject)

        // Build sub-blocks.
        let cal = Calendar.current
        let isoDay = ISO8601DateFormatter.dayOnly
        let today = cal.startOfDay(for: now)

        // Strict future only — today's pin is already represented in
        // `targetMuscle`. Including it in futurePins would be redundant
        // and could confuse the LLM's volume-distribution reasoning.
        let futurePins = pins
            .filter { cal.startOfDay(for: $0.date) > today }
            .compactMap { pin -> FuturePin? in
                guard let m = pin.muscleGroup else { return nil }
                return FuturePin(date: isoDay.string(from: pin.date), muscle: m.rawValue)
            }
            .sorted { $0.date < $1.date }

        let recentDays = buildRecentDays(
            sessions: Array(sessions.prefix(20)),  // last 20, then trim to 3 with sessions
            exerciseLookup: exerciseLookup,
            isoDay: isoDay
        )

        let daysSinceLast = sessions.first.map {
            max(0, cal.dateComponents([.day], from: $0.date, to: today).day ?? 0)
        } ?? 99

        let recovery = Recovery(
            feeling: feeling,
            sleepHours: healthContext?.sleepHours,
            restingHR: healthContext?.restingHR.map { Int($0) },
            hrv: healthContext?.hrv.map { Int($0) },
            daysSinceLastTraining: daysSinceLast,
            userNote: concerns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : concerns
        )

        let mins = availableTime ?? 55  // sensible default when unset
        let restSec = preferredRestSeconds()
        let perSet = 1.0 + Double(restSec) / 60.0
        let budget = max(0, Double(mins) - 5.0)
        let workingSets = budget > 0 ? max(4, Int((budget / perSet).rounded(.down))) : 4

        let strengthMap = buildStrengthMap(sessions: sessions, now: now)
        let (rituals, rotation) = buildRitualsAndRotation(
            sessions: sessions,
            exerciseLookup: exerciseLookup,
            now: now
        )

        let injuriesText: String? = {
            guard let s = intelligence?.injuries, !s.isEmpty else { return nil }
            return s
        }()
        let constraints = Constraints(
            injuries: injuriesText,
            exerciseOut: exerciseOut
        )
        let userProfile = UserProfile(
            goal: program?.goal ?? "Hypertrophy",
            experience: program?.experienceLevel ?? "Intermediate",
            daysPerWeek: program?.daysPerWeek ?? 4
        )

        return PlannerInput(
            targetMuscle: targetMuscle.rawValue,
            targetMuscleSource: source.rawValue,
            predictionConfidence: confidence,
            futurePins: futurePins,
            recentDays: recentDays,
            recovery: recovery,
            availableTime: mins,
            targetWorkingSets: workingSets,
            strength: strengthMap,
            rituals: rituals,
            rotation: rotation,
            constraints: constraints,
            userProfile: userProfile
        )
    }
}

// MARK: - Sub-builders (private helpers)

private extension PlannerInput {

    /// Last 3 completed sessions, oldest first per the v5 contract. Each
    /// `recentDay` carries the primary muscle (exercise-count derived),
    /// session volume, top-3 exercises by set count, and a 1–10 effort
    /// score (feeling × 2, capped).
    static func buildRecentDays(
        sessions: [WorkoutSession],
        exerciseLookup: [String: MuscleGroup],
        isoDay: ISO8601DateFormatter
    ) -> [RecentDay] {
        let withMuscle = sessions.compactMap { s -> (WorkoutSession, MuscleGroup)? in
            guard let m = PatternEngine.primaryMuscle(of: s, lookup: exerciseLookup) else { return nil }
            return (s, m)
        }
        return withMuscle.prefix(3).reversed().map { (s, muscle) in
            // Top exercises by set count.
            let entriesBySetCount = s.entries.sorted { lhs, rhs in
                lhs.sets.filter { !$0.isWarmup }.count > rhs.sets.filter { !$0.isWarmup }.count
            }
            let topNames = entriesBySetCount.prefix(3).map(\.exerciseName)

            // Total volume = sum(working sets × weight × reps).
            let volume = s.entries.reduce(0.0) { acc, e in
                acc + e.sets.filter { !$0.isWarmup }
                    .reduce(0.0) { $0 + $1.weight * $1.reps }
            }

            return RecentDay(
                date: isoDay.string(from: s.date),
                muscle: muscle.rawValue,
                totalVolume: Int(volume),
                topExercises: topNames,
                effortScore: min(10, (s.feeling ?? 3) * 2),
                avgHR: nil  // not tracked per-session yet; HealthKit context is on Recovery
            )
        }
    }

    /// Build `strength[exercise]` for every exercise the user has done 3+
    /// times in the last 60 days. Mirrors the rules used in UserState.swift
    /// so the contract stays consistent across paths.
    static func buildStrengthMap(sessions: [WorkoutSession], now: Date) -> [String: StrengthEntry] {
        let sixtyDaysAgo = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let recent = sessions.filter { $0.date >= sixtyDaysAgo }

        var byExercise: [String: [(date: Date, set: SetLog)]] = [:]
        for s in recent {
            for e in s.entries {
                for set in e.sets where !set.isWarmup {
                    byExercise[e.exerciseName, default: []].append((s.date, set))
                }
            }
        }

        var out: [String: StrengthEntry] = [:]
        for (name, records) in byExercise {
            let uniqueDays = Set(records.map { Calendar.current.startOfDay(for: $0.date) })
            guard uniqueDays.count >= 3 else { continue }

            let sorted = records.sorted { $0.date < $1.date }
            let e1rms = sorted.map {
                StatsEngine.estimatedOneRepMax(weight: $0.set.weight, reps: $0.set.reps)
            }
            let bestE1RM = e1rms.max() ?? 0
            let latestDate = sorted.last!.date
            let latestDaySets = sorted.filter {
                Calendar.current.isDate($0.date, inSameDayAs: latestDate)
            }.map(\.set)
            let latestWorking = latestDaySets.map(\.weight).max() ?? 0

            let fourWkAgo = Calendar.current.date(byAdding: .weekOfYear, value: -4, to: latestDate) ?? latestDate
            let oldEntries = sorted.filter { $0.date <= fourWkAgo }
            let trend: String
            if let oldRef = oldEntries.last {
                let oldE1RM = StatsEngine.estimatedOneRepMax(weight: oldRef.set.weight, reps: oldRef.set.reps)
                let delta = Int((e1rms.last ?? 0 - oldE1RM).rounded())
                if abs(delta) < 3 { trend = "flat" }
                else if delta > 0 { trend = "+\(delta) lb / 4wk" }
                else { trend = "\(delta) lb / 4wk" }
            } else {
                trend = "new"
            }

            out[name] = StrengthEntry(
                working: latestWorking,
                e1rm: latestWorking == 0 ? 0 : bestE1RM,
                lastTrained: relativeAgo(from: latestDate, now: now),
                trend4wk: trend,
                bodyweight: latestWorking == 0
            )
        }
        return out
    }

    /// Frequency-based rituals (≥60% of last 8wk sessions) + per-muscle
    /// rotation (2+ appearances below the ritual threshold). Same algorithm
    /// as UserState.preferencesBlock — kept duplicated rather than coupled
    /// because the planner contract may evolve independently.
    static func buildRitualsAndRotation(
        sessions: [WorkoutSession],
        exerciseLookup: [String: MuscleGroup],
        now: Date
    ) -> (rituals: [String], rotation: [String: [String]]) {
        let eightWkAgo = Calendar.current.date(byAdding: .day, value: -56, to: now) ?? now
        let recent = sessions.filter { $0.date >= eightWkAgo }
        let total = recent.count
        guard total > 0 else { return ([], [:]) }

        var appearances: [String: Int] = [:]
        for s in recent {
            var seen = Set<String>()
            for e in s.entries where !seen.contains(e.exerciseName) {
                seen.insert(e.exerciseName)
                appearances[e.exerciseName, default: 0] += 1
            }
        }
        let threshold = max(1, Int(ceil(Double(total) * 0.6)))
        let rituals = appearances
            .filter { $0.value >= threshold }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.key }

        let ritualSet = Set(rituals)
        var rotationByMuscle: [MuscleGroup: [(String, Int)]] = [:]
        for (name, count) in appearances where count >= 2 && !ritualSet.contains(name) {
            guard let m = exerciseLookup[name] else { continue }
            rotationByMuscle[m, default: []].append((name, count))
        }
        var rotation: [String: [String]] = [:]
        for (mg, items) in rotationByMuscle {
            rotation[mg.rawValue] = items
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .map(\.0)
        }
        return (rituals, rotation)
    }

    static func preferredRestSeconds() -> Int {
        let stored = UserDefaults.standard.double(forKey: "restTimerDuration")
        return stored > 0 ? Int(stored) : 150
    }

    static func relativeAgo(from: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(from)
        if interval < 3600 { return "just now" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Date formatter helper

private extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
