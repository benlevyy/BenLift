import Foundation
import SwiftData

// MARK: - Exercise

@Model
final class Exercise {
    var id: UUID
    var name: String
    var muscleGroup: MuscleGroup
    var equipment: Equipment
    var defaultWeight: Double?
    var isCustom: Bool

    init(
        id: UUID = UUID(),
        name: String,
        muscleGroup: MuscleGroup,
        equipment: Equipment,
        defaultWeight: Double? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
        self.equipment = equipment
        self.defaultWeight = defaultWeight
        self.isCustom = isCustom
    }
}

// MARK: - Workout Template

@Model
final class WorkoutTemplate {
    var id: UUID
    var name: String
    var category: WorkoutCategory
    @Relationship(deleteRule: .cascade, inverse: \TemplateExercise.template)
    var exercises: [TemplateExercise]

    init(
        id: UUID = UUID(),
        name: String,
        category: WorkoutCategory,
        exercises: [TemplateExercise] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.exercises = exercises
    }
}

@Model
final class TemplateExercise {
    var id: UUID
    var exerciseId: UUID
    var exerciseName: String
    var order: Int
    var targetSets: Int
    var targetReps: String
    var template: WorkoutTemplate?

    init(
        id: UUID = UUID(),
        exerciseId: UUID,
        exerciseName: String,
        order: Int,
        targetSets: Int = 3,
        targetReps: String = "8-10"
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.order = order
        self.targetSets = targetSets
        self.targetReps = targetReps
    }
}

// MARK: - Workout Session

@Model
final class WorkoutSession {
    var id: UUID
    var date: Date
    var category: WorkoutCategory?       // Legacy PPL — optional for new dynamic sessions
    var sessionName: String?              // AI-generated: "Heavy Legs + Rear Delts"
    var muscleGroupsData: Data?           // Encoded [MuscleGroup]
    var duration: Double?
    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.session)
    var entries: [ExerciseEntry]
    var feeling: Int?
    var concerns: String?
    var aiPlanUsed: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: WorkoutCategory? = nil,
        sessionName: String? = nil,
        muscleGroups: [MuscleGroup] = [],
        duration: Double? = nil,
        entries: [ExerciseEntry] = [],
        feeling: Int? = nil,
        concerns: String? = nil,
        aiPlanUsed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.sessionName = sessionName
        self.muscleGroupsData = Data.encodeJSON(muscleGroups)
        self.duration = duration
        self.entries = entries
        self.feeling = feeling
        self.concerns = concerns
        self.aiPlanUsed = aiPlanUsed
    }

    var muscleGroups: [MuscleGroup] {
        get { muscleGroupsData?.decodeJSON([MuscleGroup].self) ?? [] }
        set { muscleGroupsData = Data.encodeJSON(newValue) }
    }

    /// Display name: AI session name, or fallback to category, or muscle group list
    var displayName: String {
        if let name = sessionName, !name.isEmpty { return name }
        if let cat = category { return cat.displayName }
        let groups = muscleGroups
        if groups.isEmpty { return "Workout" }
        return groups.map(\.displayName).joined(separator: ", ")
    }

    var sortedEntries: [ExerciseEntry] {
        entries.sorted { $0.order < $1.order }
    }

    var totalVolume: Double {
        entries.reduce(0) { $0 + $1.totalVolume }
    }
}

@Model
final class ExerciseEntry {
    var id: UUID
    var exerciseName: String
    var order: Int
    @Relationship(deleteRule: .cascade, inverse: \SetLog.entry)
    var sets: [SetLog]
    var session: WorkoutSession?

    init(
        id: UUID = UUID(),
        exerciseName: String,
        order: Int,
        sets: [SetLog] = []
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.order = order
        self.sets = sets
    }

    var sortedSets: [SetLog] {
        sets.sorted { $0.setNumber < $1.setNumber }
    }

    var workingSets: [SetLog] {
        sets.filter { !$0.isWarmup }.sorted { $0.setNumber < $1.setNumber }
    }

    var totalVolume: Double {
        sets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.weight * floor($1.reps) }
    }
}

@Model
final class SetLog {
    var id: UUID
    var setNumber: Int
    var weight: Double
    var reps: Double
    var timestamp: Date
    var isWarmup: Bool
    var entry: ExerciseEntry?

    init(
        id: UUID = UUID(),
        setNumber: Int,
        weight: Double,
        reps: Double,
        timestamp: Date = Date(),
        isWarmup: Bool = false
    ) {
        self.id = id
        self.setNumber = setNumber
        self.weight = weight
        self.reps = reps
        self.timestamp = timestamp
        self.isWarmup = isWarmup
    }

    var isFailed: Bool {
        reps.truncatingRemainder(dividingBy: 1) != 0
    }
}

// MARK: - Training Program

@Model
final class TrainingProgram {
    var id: UUID
    var name: String
    var goal: String
    var specificTargets: String?
    var experienceLevel: String
    var daysPerWeek: Int
    var splitData: Data?
    var weeklyVolumeTargetsData: Data?
    var compoundPriorityData: Data?
    var progressionSchemeData: Data?
    var periodization: String
    var deloadFrequency: String
    var currentWeek: Int
    var createdAt: Date
    var isActive: Bool

    // MARK: - Coaching Profile (persistent context for AI)
    var otherActivities: String?       // e.g. "Bouldering Wed/Sun"
    var activitySchedule: String?      // e.g. "Boulder Wed evening, Sun morning"
    var musclePriorities: String?      // e.g. "Focus chest and shoulders, maintain legs"
    var ongoingConcerns: String?       // e.g. "Left shoulder impingement, hip instability on split squats"
    var recoveryNotes: String?         // e.g. "Sleep is usually 6-7hrs, worse on weeknights"
    var coachingStyle: String?         // e.g. "Push me hard but be conservative on shoulders"
    var customCoachNotes: String?      // any other persistent context for the AI

    init(
        id: UUID = UUID(),
        name: String,
        goal: String,
        specificTargets: String? = nil,
        experienceLevel: String = "intermediate",
        daysPerWeek: Int = 5,
        periodization: String = "linear",
        deloadFrequency: String = "every 4 weeks",
        currentWeek: Int = 1,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.specificTargets = specificTargets
        self.experienceLevel = experienceLevel
        self.daysPerWeek = daysPerWeek
        self.periodization = periodization
        self.deloadFrequency = deloadFrequency
        self.currentWeek = currentWeek
        self.createdAt = Date()
        self.isActive = isActive
    }

    // MARK: Codable Accessors

    var split: [String] {
        get { splitData?.decodeJSON([String].self) ?? [] }
        set { splitData = Data.encodeJSON(newValue) }
    }

    var weeklyVolumeTargets: [String: VolumeTarget] {
        get { weeklyVolumeTargetsData?.decodeJSON([String: VolumeTarget].self) ?? [:] }
        set { weeklyVolumeTargetsData = Data.encodeJSON(newValue) }
    }

    var compoundPriority: [String] {
        get { compoundPriorityData?.decodeJSON([String].self) ?? [] }
        set { compoundPriorityData = Data.encodeJSON(newValue) }
    }

    var progressionScheme: [String: String] {
        get { progressionSchemeData?.decodeJSON([String: String].self) ?? [:] }
        set { progressionSchemeData = Data.encodeJSON(newValue) }
    }

    func todayCategory() -> WorkoutCategory? {
        let weekday = Calendar.current.component(.weekday, from: Date())
        // Convert: 1=Sun -> index 6, 2=Mon -> index 0, ..., 7=Sat -> index 5
        let index = (weekday + 5) % 7
        guard index < split.count else { return nil }
        return WorkoutCategory(rawValue: split[index])
    }
}

// MARK: - Post-Workout Analysis

@Model
final class PostWorkoutAnalysis {
    var id: UUID
    var sessionId: UUID
    var summary: String
    var overallRating: OverallRating
    var progressionEventsData: Data?
    var volumeAnalysisData: Data?
    var recoveryNotes: String?
    var coachNote: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        summary: String,
        overallRating: OverallRating,
        recoveryNotes: String? = nil,
        coachNote: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.summary = summary
        self.overallRating = overallRating
        self.recoveryNotes = recoveryNotes
        self.coachNote = coachNote
        self.createdAt = Date()
    }

    var progressionEvents: [ProgressionEvent] {
        get { progressionEventsData?.decodeJSON([ProgressionEvent].self) ?? [] }
        set { progressionEventsData = Data.encodeJSON(newValue) }
    }

    var volumeAnalysis: [String: VolumeAnalysisEntry] {
        get { volumeAnalysisData?.decodeJSON([String: VolumeAnalysisEntry].self) ?? [:] }
        set { volumeAnalysisData = Data.encodeJSON(newValue) }
    }
}

// MARK: - Weekly Review

@Model
final class WeeklyReview {
    var id: UUID
    var weekStartDate: Date
    var sessionsCompleted: Int
    var sessionsPlanned: Int
    var totalVolume: Double
    var goalProgressData: Data?
    var volumeComplianceData: Data?
    var strengthTrendsData: Data?
    var programAdjustmentsData: Data?
    var recoveryReportData: Data?
    var coachNote: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        weekStartDate: Date,
        sessionsCompleted: Int,
        sessionsPlanned: Int,
        totalVolume: Double,
        coachNote: String
    ) {
        self.id = id
        self.weekStartDate = weekStartDate
        self.sessionsCompleted = sessionsCompleted
        self.sessionsPlanned = sessionsPlanned
        self.totalVolume = totalVolume
        self.coachNote = coachNote
        self.createdAt = Date()
    }

    var goalProgress: [GoalProgressEntry] {
        get { goalProgressData?.decodeJSON([GoalProgressEntry].self) ?? [] }
        set { goalProgressData = Data.encodeJSON(newValue) }
    }

    var volumeCompliance: [String: VolumeComplianceEntry] {
        get { volumeComplianceData?.decodeJSON([String: VolumeComplianceEntry].self) ?? [:] }
        set { volumeComplianceData = Data.encodeJSON(newValue) }
    }

    var strengthTrends: [StrengthTrend] {
        get { strengthTrendsData?.decodeJSON([StrengthTrend].self) ?? [] }
        set { strengthTrendsData = Data.encodeJSON(newValue) }
    }

    var programAdjustments: [ProgramAdjustment] {
        get { programAdjustmentsData?.decodeJSON([ProgramAdjustment].self) ?? [] }
        set { programAdjustmentsData = Data.encodeJSON(newValue) }
    }

    var recoveryReport: RecoveryReport? {
        get { recoveryReportData?.decodeJSON(RecoveryReport.self) }
        set { recoveryReportData = newValue.flatMap { Data.encodeJSON($0) } }
    }
}

// MARK: - Activity Log (non-lifting activities from HealthKit)

@Model
final class ActivityLog {
    var id: UUID
    var date: Date
    var activityType: String   // "climbing", "running", "cycling", etc.
    var duration: Double       // seconds
    var calories: Double?
    var source: String         // "HealthKit" or "manual"

    init(
        id: UUID = UUID(),
        date: Date,
        activityType: String,
        duration: Double,
        calories: Double? = nil,
        source: String = "HealthKit"
    ) {
        self.id = id
        self.date = date
        self.activityType = activityType
        self.duration = duration
        self.calories = calories
        self.source = source
    }
}
