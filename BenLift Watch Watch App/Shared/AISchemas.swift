import Foundation

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

struct PlannedExercise: Codable, Identifiable {
    var id: String { name }
    let name: String
    let sets: Int
    let targetReps: String
    let suggestedWeight: Double
    let repScheme: String?
    let warmupSets: [WarmupSet]?
    let notes: String?
    let intent: String?
}

struct WarmupSet: Codable {
    let weight: Double
    let reps: Int
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
    let category: WorkoutCategory
    let exercises: [WatchExerciseInfo]
    let sessionStrategy: String?
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
}

struct WatchWorkoutResult: Codable {
    let date: Date
    let category: WorkoutCategory
    let duration: TimeInterval
    let feeling: Int?
    let concerns: String?
    let entries: [WatchExerciseResult]
}

struct WatchExerciseResult: Codable {
    let exerciseName: String
    let order: Int
    let sets: [WatchSetResult]
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
