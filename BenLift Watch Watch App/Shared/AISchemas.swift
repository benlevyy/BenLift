import Foundation

// MARK: - Recovery Recommendation (Touchpoint 0: What should I train today?)

struct RecoveryRecommendation: Codable {
    let muscleGroupStatus: [MuscleGroupStatus]
    let recommendedFocus: [String]           // muscle group names to target
    let recommendedSessionName: String        // "Heavy Legs + Rear Delts"
    let reasoning: String                     // 2-3 sentence explanation
}

struct MuscleGroupStatus: Codable, Identifiable {
    var id: String { muscleGroup }
    let muscleGroup: String
    let status: String                        // "fresh", "ready", "recovering", "sore"
    let daysSinceTraining: Double?
    let weeklySetsDone: Int?
    let note: String?                         // "climbed yesterday - grip fatigued"

    var statusColor: String {
        switch status {
        case "fresh": return "green"
        case "ready": return "blue"
        case "recovering": return "yellow"
        case "sore": return "red"
        default: return "gray"
        }
    }

    var statusLevel: Double {
        switch status {
        case "fresh": return 1.0
        case "ready": return 0.75
        case "recovering": return 0.4
        case "sore": return 0.15
        default: return 0.5
        }
    }
}

// MARK: - Shared Sub-Schemas

struct VolumeTarget: Codable {
    let sets: Int
    let repRange: String
}

// MARK: - Touchpoint 1: Program Generation Response

struct ProgramResponse: Codable {
    let program: ProgramData
}

struct ProgramData: Codable {
    let name: String
    let split: [String]
    let weeklySchedule: [String: String]?
    let periodization: String
    let deloadFrequency: String
    let focusAreas: [String]?
    let weeklyVolumeTargets: [String: VolumeTarget]
    let compoundPriority: [String]
    let progressionScheme: [String: String]
    let notes: String?
}

// MARK: - Touchpoint 2: Daily Plan Response

struct DailyPlanResponse: Codable {
    let exercises: [PlannedExercise]
    let sessionStrategy: String?
    let estimatedDuration: Int?
    let deloadNote: String?
}

struct PlannedExercise: Identifiable {
    var id: String { name }
    let name: String
    let sets: Int
    let targetReps: String
    let suggestedWeight: Double?
    let repScheme: String?
    let warmupSets: [WarmupSet]?
    let notes: String?
    let intent: String?

    /// Safe weight accessor — returns 0 for bodyweight exercises
    var weight: Double { suggestedWeight ?? 0 }
}

extension PlannedExercise: Codable {
    enum CodingKeys: String, CodingKey {
        case name, sets, targetReps, suggestedWeight, repScheme, warmupSets, notes, intent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sets = try container.decode(Int.self, forKey: .sets)
        targetReps = try container.decode(String.self, forKey: .targetReps)
        repScheme = try container.decodeIfPresent(String.self, forKey: .repScheme)
        warmupSets = try container.decodeIfPresent([WarmupSet].self, forKey: .warmupSets)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)

        // Handle suggestedWeight as Double, String, or null. Hard-cap at 2000 lb —
        // no legitimate human lift exceeds this, so any larger value is an LLM
        // hallucination or a comma-stripped concatenation ("15,000 lbs" → 15000).
        let maxPlausible: Double = 2000
        if let d = try? container.decodeIfPresent(Double.self, forKey: .suggestedWeight) {
            suggestedWeight = (d.isFinite && d <= maxPlausible) ? d : nil
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .suggestedWeight) {
            // Try to extract number from strings like "Bodyweight + 0 lbs"
            let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let val = Double(digits), val.isFinite, val <= maxPlausible {
                suggestedWeight = val
            } else {
                suggestedWeight = nil
            }
        } else {
            suggestedWeight = nil
        }
    }
}

struct WarmupSet: Codable {
    let weight: Double?
    let reps: Int

    var displayWeight: Double { weight ?? 0 }
}

// MARK: - Watch Transfer Models

struct WatchWorkoutPlan: Codable {
    let sessionName: String?
    let muscleGroups: [String]            // muscle group raw values
    let category: WorkoutCategory?        // legacy, optional
    let exercises: [WatchExerciseInfo]
    let sessionStrategy: String?
    var restTimerDuration: Double?
    var weightIncrement: Double?
    /// Whether this plan was AI-generated. Carried through the watch and back
    /// out in `WatchWorkoutResult` / `WorkoutSnapshot` so both persistence
    /// paths (phone-finish and sync-manager) agree on the saved flag.
    /// Optional so older payloads decode. Default-nil so callers (like the
    /// watch's `startEmptyWorkout`) that don't know the flag can omit it.
    var aiPlanUsed: Bool? = nil
    /// Names of the user's most-used exercises from recent history, ranked
    /// high→low. Feeds the "Recent" section at the top of the watch's
    /// add-exercise picker so the user doesn't have to scroll the full
    /// library to find their usual movements. Optional so older plans (and
    /// the watch's own `startEmptyWorkout`) decode cleanly.
    var recentExercises: [String]? = nil
    /// Last working weight per exercise name, lower-cased keys, from the
    /// phone's history. The watch carries its own hardcoded library with
    /// textbook weights — a bench is 135 whoever you are — so an exercise
    /// added mid-workout on the watch used to arrive with a number that had
    /// nothing to do with what the user actually lifts. This is how it gets
    /// the real one. Optional so older payloads decode.
    var recentWeights: [String: Double]? = nil
}

struct WatchExerciseInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let sets: Int
    let targetReps: String
    let suggestedWeight: Double
    let warmupSets: [WarmupSet]?
    let notes: String?
    let intent: String?
    let lastWeight: Double?
    let lastReps: Double?
    /// Optional — when present, drives per-exercise weight increment (2.5 vs 5).
    /// Nil means the watch falls back to the user's global `weightIncrement` setting.
    let equipment: Equipment?

    var weight: Double { suggestedWeight }
}

struct WatchWorkoutResult: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let sessionName: String?
    let muscleGroups: [String]?           // muscle group raw values
    let category: WorkoutCategory?        // legacy, optional
    let duration: TimeInterval
    let feeling: Int?
    let concerns: String?
    let entries: [WatchExerciseResult]
    /// Propagated from `WatchWorkoutPlan.aiPlanUsed` so the WCSession persist
    /// path saves the same flag as the mirrored-snapshot persist path would.
    /// Optional for backward-compat.
    let aiPlanUsed: Bool?
}

struct WatchExerciseResult: Codable {
    let exerciseName: String
    let order: Int
    let sets: [WatchSetResult]
    /// User-initiated skip via swipe. Carried so skipped-but-unlogged exercises
    /// survive into `WorkoutSession` history instead of being filtered as empty.
    /// Optional so older payloads in flight at upgrade time decode cleanly.
    let isSkipped: Bool?
    /// The user's in-session note on this exercise, if any. Optional for
    /// the same reason.
    var userNote: String? = nil
    /// The rep range and load the plan prescribed. The resolver needs the
    /// range to tell "hit the top" from "landed mid-range"; without it every
    /// lift holds. Watch-saved sessions never carried these before.
    var targetReps: String? = nil
    var prescribedWeight: Double? = nil
}

struct WatchSetResult: Codable {
    let setNumber: Int
    let weight: Double
    let reps: Double
    let timestamp: Date
    let isWarmup: Bool
}

// MARK: - Health Context (sent to Claude)

struct HealthContext: Codable {
    var sleepHours: Double?
    var restingHR: Double?
    var hrv: Double?
    var bodyWeight: Double?
    var vo2Max: Double?
}

// MARK: - Precomputed Stats (sent to Claude)

struct ExerciseStats: Codable {
    let exerciseName: String
    let estimatedOneRepMax: Double
    let recentTopSetWeight: Double
    let recentTopSetReps: Double
    let trendDirection: String // up, down, flat
    let sessionsAtCurrentWeight: Int
}

struct CategoryStats: Codable {
    let weeklyVolume: Double
    let sessionCount: Int
    let avgFeeling: Double?
    let lastSessionDate: Date?
}
