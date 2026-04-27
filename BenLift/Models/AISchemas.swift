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

struct ProgressionEvent: Codable, Identifiable {
    var id: String { "\(exercise)-\(type)" }
    let exercise: String
    let type: String // rep_pr, weight_pr, plateau, regression
    let detail: String
    let recommendation: String
}

struct VolumeAnalysisEntry: Codable {
    let actual: Int
    let weeklyTarget: Int
    let weeklyActual: Int
    let status: String
}

struct GoalProgressEntry: Codable, Identifiable {
    var id: String { goal }
    let goal: String
    let metric: String
    let current: Double
    let previous: Double
    let trend: String
    let projection: String
}

struct ProgramAdjustment: Codable, Identifiable {
    var id: String { "\(type)-\(detail.prefix(20))" }
    let type: String // exercise_swap, volume_adjustment
    let detail: String
    let priority: String // low, medium, high
}

struct RecoveryReport: Codable {
    let avgSleep: Double?
    let sleepTrend: String?
    let avgRestingHR: Double?
    let restingHRTrend: String?
    let note: String?
}

struct StrengthTrend: Codable, Identifiable {
    var id: String { exercise }
    let exercise: String
    let e1rm4wkAgo: Double?
    let e1rmNow: Double?
    let trend: String

    enum CodingKeys: String, CodingKey {
        case exercise
        case e1rm4wkAgo = "e1rm_4wk_ago"
        case e1rmNow = "e1rm_now"
        case trend
    }
}

struct VolumeComplianceEntry: Codable {
    let target: Int
    let actual: Int
    let status: String
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

// MARK: - Touchpoint 0+2 Combined: Recommendation + Plan in one call

/// One-shot response that returns both the recovery recommendation and the day's
/// workout plan in a single LLM call. Replaces the prior split flow (Sonnet
/// recommend -> Haiku plan) — ~2.2x faster, ~2.7x cheaper, equivalent quality.
struct RecommendAndPlanResponse: Codable {
    // Recommendation portion (mirrors RecoveryRecommendation)
    let muscleGroupStatus: [MuscleGroupStatus]
    let recommendedFocus: [String]
    let recommendedSessionName: String
    let reasoning: String

    // Plan portion (mirrors DailyPlanResponse)
    let exercises: [PlannedExercise]
    let sessionStrategy: String?
    let estimatedDuration: Int?
    let deloadNote: String?

    var asRecommendation: RecoveryRecommendation {
        RecoveryRecommendation(
            muscleGroupStatus: muscleGroupStatus,
            recommendedFocus: recommendedFocus,
            recommendedSessionName: recommendedSessionName,
            reasoning: reasoning
        )
    }

    var asPlan: DailyPlanResponse {
        DailyPlanResponse(
            exercises: exercises,
            sessionStrategy: sessionStrategy,
            estimatedDuration: estimatedDuration,
            deloadNote: deloadNote
        )
    }
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
        // Null gets resolved downstream by CoachViewModel.pickStartingWeight.
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

// MARK: - Touchpoint 3: Mid-Workout Adapt Response

struct MidWorkoutAdaptResponse: Codable {
    let exercises: [PlannedExercise]
    let rationale: String?
}

// MARK: - Touchpoint 4: Post-Workout Analysis Response

struct PostWorkoutAnalysisResponse: Codable {
    let summary: String
    let performanceVsplan: PerformanceVsPlan?
    let progressionEvents: [ProgressionEvent]
    let volumeAnalysis: [String: VolumeAnalysisEntry]?
    let recoveryNotes: String?
    let overallRating: String
    let coachNote: String
    let observations: [String]?    // AI-observed patterns to accumulate for next intelligence refresh
}

struct PerformanceVsPlan: Codable {
    let adherence: Double?
    let notes: String?
}

// MARK: - Touchpoint 5: Weekly Review Response

struct WeeklyReviewResponse: Codable {
    let weekSummary: WeekSummaryData
    let goalProgress: [GoalProgressEntry]?
    let weeklyVolumeCompliance: [String: VolumeComplianceEntry]?
    let strengthTrends: [StrengthTrend]?
    let programAdjustments: [ProgramAdjustment]?
    let recoveryReport: RecoveryReport?
    let coachNote: String
}

struct WeekSummaryData: Codable {
    let sessionsCompleted: Int
    let sessionsPlanned: Int
    let totalVolume: Double
    let totalDuration: Double?
    let avgFeeling: Double?
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
}

struct WatchSetResult: Codable {
    let setNumber: Int
    let weight: Double
    let reps: Double
    let timestamp: Date
    let isWarmup: Bool
}

struct WatchExerciseLibrary: Codable {
    let exercises: [WatchExerciseItem]
    let daysSinceLast: [String: Int]
    let todayCategory: String?
    let programSplit: [String]?
}

struct WatchExerciseItem: Codable, Identifiable {
    var id: String { name }
    let name: String
    let muscleGroup: MuscleGroup
    let equipment: Equipment
    let defaultWeight: Double?
}

// MARK: - daily_plan_v5 Response

/// Response shape for the v5 daily-plan prompt. Calendar decides muscle
/// upstream — this prompt only designs the session (exercises, sets, reps,
/// loads, order) with safety adjudication and weight anchoring.
struct DailyPlanV5Response: Codable {
    let recommendation: String
    let strategy: String
    let exercises: [PlannedExerciseV5]
    let estimatedDuration: Int
    let deloadNote: String?
    let selfCheck: SelfCheckBlock?
}

struct PlannedExerciseV5: Codable {
    let name: String
    let sets: Int
    let targetReps: String
    let suggestedWeight: Double?
    let weightAnchor: WeightAnchor
    let evidenceNote: String?
    let warmupSets: [WarmupSet]?
    let notes: String?
    let intent: String
}

struct WeightAnchor: Codable {
    let source: String      // exercise name | "bodyweight" | "no_history"
    let rationale: String
}

/// Slim subset of the prompt's verbose `selfCheck`. We capture the fields
/// we want to log/audit (set-count math, ritual omissions, hard-rule
/// evidence) and let the rest decode-skip via Codable's permissive default.
struct SelfCheckBlock: Codable {
    let setCountMath: String?
    let ritualsOmitted: [RitualOmission]?
    /// Map of rule name (lowReadiness | injury | exerciseOut) → literal
    /// evidence string. Kept as `[String: String]` so we don't have to
    /// model the rule-name keys statically.
    let hardRulesCheck: [String: String]?
}

struct RitualOmission: Codable {
    let ritual: String
    let safe: Bool
    let reason: String
}

// MARK: - iterate Response
//
// Two-shape union: either a plan-edit (swap/prioritize/load_adjust/
// add_finisher/remove) or a conversational explain. The decoder switches
// on the `responseType` discriminator. Encode round-trips through the
// inner case so downstream code can mutate and re-emit.

enum IterateResponse: Codable {
    case edit(IterateEdit)
    case explain(IterateExplain)

    private enum CodingKeys: String, CodingKey { case responseType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .responseType)
        let single = try decoder.singleValueContainer()
        switch kind {
        case "edit":
            self = .edit(try single.decode(IterateEdit.self))
        case "explain":
            self = .explain(try single.decode(IterateExplain.self))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .responseType,
                in: c,
                debugDescription: "Unknown iterate responseType: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .edit(let e): try single.encode(e)
        case .explain(let e): try single.encode(e)
        }
    }
}

struct IterateEdit: Codable {
    let responseType: String   // "edit"
    let editKind: String       // "swap" | "prioritize" | "load_adjust" | "add_finisher" | "remove"
    let edits: [PlanEdit]
    let rationale: String
    let watchOuts: String?
}

struct PlanEdit: Codable {
    let action: String                       // "replace" | "insert" | "delete" | "modify"
    let targetExerciseName: String?
    let newExercise: PlannedExerciseV5?      // null for delete
}

struct IterateExplain: Codable {
    let responseType: String   // "explain"
    let answer: String
}

// MARK: - bootstrap Response
//
// One-time program design from onboarding answers. Seeds calendar pattern,
// exercise rotation per muscle, weekly volume targets, progression scheme.

struct BootstrapResponse: Codable {
    let programName: String
    let split: String                              // full_body | upper_lower | ppl | ppl_ul | custom
    let weeklyPattern: [String: String]            // "monday" → "chest, shoulders, triceps"
    let rotationPerMuscle: [String: [String]]
    let weeklyVolumeTargets: [String: BootstrapVolumeTarget]
    let progressionScheme: ProgressionScheme
    let ruleOuts: [String]
    let rationale: String
}

/// Distinct from the existing `VolumeTarget` (which carries `sets` + `repRange`
/// for the older program-generation flow). Bootstrap volume targets have a
/// `rationale` string instead of a rep range.
struct BootstrapVolumeTarget: Codable {
    let sets: Int
    let rationale: String
}

struct ProgressionScheme: Codable {
    let compounds: String
    let isolation: String
}

/// Onboarding input passed to the bootstrap prompt. Codable so we can
/// serialize directly to JSON for the `{{ONBOARDING_JSON}}` template slot.
struct BootstrapInput: Codable {
    let goal: String              // "hypertrophy" | "strength" | "general_fitness" | "sport_specific"
    let daysPerWeek: Int          // 3 | 4 | 5 | 6
    let experience: String        // "never" | "<1yr" | "1-3yr" | "3+yr"
    let equipment: String         // "full_gym" | "home_dumbbells" | "bodyweight"
    let focusAreas: [String]
    let injuriesOrAvoid: String?
    let crossTraining: String?
    let preferences: String?
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

// MARK: - Intelligence Refresh Response

struct IntelligenceRefreshResponse: Codable {
    let activityPatterns: String
    let trainingPatterns: String
    let strengthProfile: String
    let recoveryProfile: String
    let exercisePreferences: String
    let notableObservations: String
}
