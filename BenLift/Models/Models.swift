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
    /// True when the user explicitly skipped this exercise during the session
    /// (as opposed to "never started" or "completed"). Lets history/analytics
    /// distinguish a bail from an omission. Default false for safe migration
    /// of rows written before this field existed.
    var isSkipped: Bool = false
    /// The rep range this entry was prescribed, e.g. "8-12". Without it a
    /// logged 3x10 is ambiguous — we can't tell whether 10 was the top of
    /// the range (progress the load) or the middle (hold it). Optional so
    /// rows written before double progression existed migrate cleanly;
    /// `PlanResolver` holds the weight when it's nil rather than guessing.
    var targetReps: String?
    /// The load the plan called for, as distinct from what was logged.
    /// Lets the resolver tell "did the prescribed weight" from "worked up
    /// to something else".
    var prescribedWeight: Double?
    /// What the user wrote about this exercise during (or after) the
    /// session — "elbow talking on set 2", "bar path felt off". Shown in
    /// history and on the runner the next time the lift comes round.
    /// Optional so rows written before notes existed migrate cleanly.
    var note: String?

    init(
        id: UUID = UUID(),
        exerciseName: String,
        order: Int,
        sets: [SetLog] = [],
        isSkipped: Bool = false,
        targetReps: String? = nil,
        prescribedWeight: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.order = order
        self.sets = sets
        self.isSkipped = isSkipped
        self.targetReps = targetReps
        self.prescribedWeight = prescribedWeight
        self.note = note
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

    // MARK: - Goal
    /// The single plain-text field the user writes about what they're
    /// training for. Replaces the nine overlapping free-text columns below
    /// (goal / specificTargets / musclePriorities / otherActivities /
    /// activitySchedule / ongoingConcerns / recoveryNotes / coachingStyle /
    /// customCoachNotes), which are kept only so existing rows migrate and
    /// can be folded into this on first launch.
    ///
    /// Read by chat on every turn. Deliberately NOT read by `PlanResolver` —
    /// the plan is rotation + replay, and stays that way.
    var goalText: String = ""

    // MARK: - Coaching Profile (DEPRECATED — folded into `goalText`)
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

// MARK: - Weekly Review

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

// MARK: - User Intelligence (AI-generated from data)

// MARK: - UserRule (explicit user decisions the AI MUST respect)

/// Durable assertion: "never suggest Split Squat," "always prefer DB
/// shoulder press over barbell," etc. These are deterministic hard
/// constraints, not probabilistic observations. A rule set today is
/// respected in the very next plan call (no waiting for the AI to
/// re-observe the pattern) and persists until explicitly archived —
/// either by user action, by the user re-adding the excluded exercise,
/// or by time-decay after 90 days without reinforcement.
///
/// Stored as `kindRaw` / `isActive` primitives so unknown future rule
/// kinds round-trip without crashing, and soft-archive is a flag rather
/// than a delete (history preserved for "Exercise Preferences" UI).
@Model
final class UserRule {
    var id: UUID
    var kindRaw: String
    /// Exercise name, muscle group, or other target the rule applies to.
    var subject: String
    /// For relational rules like `preferOver` — the thing being
    /// preferred instead of the subject. nil for unary rules.
    var target: String?
    /// Human-readable reason surfaced in the UI + passed to the AI. Can
    /// be empty for auto-promoted rules.
    var reason: String?
    var createdAt: Date
    /// Bumped every time the user's behavior re-confirms the rule —
    /// e.g. another swap away from the excluded exercise. Drives the
    /// 90-day decay check.
    var lastReinforcedAt: Date
    /// Soft-archive flag. Archived rules stay in the DB (for history /
    /// audit) but are excluded from prompts and active-rule UI.
    var isActive: Bool

    init(
        id: UUID = UUID(),
        kind: UserRuleKind,
        subject: String,
        target: String? = nil,
        reason: String? = nil,
        createdAt: Date = Date(),
        lastReinforcedAt: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.subject = subject
        self.target = target
        self.reason = reason
        self.createdAt = createdAt
        self.lastReinforcedAt = lastReinforcedAt ?? createdAt
        self.isActive = isActive
    }

    var kind: UserRuleKind {
        UserRuleKind(rawValue: kindRaw) ?? .unknown
    }
}

/// Categories of durable user decisions. String rawValues so unknown
/// future kinds decode cleanly as `.unknown` during migrations.
enum UserRuleKind: String, Codable, CaseIterable {
    /// Don't suggest this exercise until the user adds it back.
    case exerciseOut
    /// Prefer `target` over `subject` when both address the same slot.
    case preferOver
    /// Equipment restriction — "only cable/machine for this muscle"
    /// carried as a free-form subject for now.
    case equipment
    /// Programming preference — "keep me in 3×8-12" etc., subject holds
    /// the text. Unstructured for now; can split if frequency justifies.
    case programming
    case unknown
}

// MARK: - Observation (AI-discovered patterns — probabilistic)

enum ObservationKind: String, Codable, CaseIterable {
    /// Correlation between two signals ("HRV dips after climbing").
    case correlation
    /// Recurring behavior pattern ("bench PRs cluster Mon/Tue").
    case pattern
    /// Programming insight ("user responds better to DB than barbell").
    case programming
    /// Recovery-specific finding.
    case recovery
    /// Cross-cutting note that doesn't fit the others.
    case note
    case unknown
}

enum ObservationConfidence: String, Codable, CaseIterable {
    case low, medium, high
}
