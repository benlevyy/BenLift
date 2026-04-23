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

    init(
        id: UUID = UUID(),
        exerciseName: String,
        order: Int,
        sets: [SetLog] = [],
        isSkipped: Bool = false
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.order = order
        self.sets = sets
        self.isSkipped = isSkipped
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

// MARK: - Living User Profile (DEPRECATED — replaced by UserIntelligence)

@Model
final class UserProfile {
    var id: UUID
    var profileText: String
    var lastUpdated: Date

    init(
        id: UUID = UUID(),
        profileText: String = "",
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.profileText = profileText
        self.lastUpdated = lastUpdated
    }
}

// MARK: - User Intelligence (AI-generated from data)

@Model
final class UserIntelligence {
    var id: UUID
    var lastRefreshed: Date

    // AI-generated structured sections (populated by Sonnet refresh)
    var activityPatterns: String
    var trainingPatterns: String
    var strengthProfile: String
    var recoveryProfile: String
    var exercisePreferences: String
    var notableObservations: String

    // Accumulates between refreshes (written by Haiku post-workout)
    var pendingObservations: String

    // User-provided fields (minimal input)
    var injuries: String
    var userNotes: String

    // Track staleness
    var workoutsSinceRefresh: Int

    init(
        id: UUID = UUID(),
        lastRefreshed: Date = .distantPast,
        activityPatterns: String = "",
        trainingPatterns: String = "",
        strengthProfile: String = "",
        recoveryProfile: String = "",
        exercisePreferences: String = "",
        notableObservations: String = "",
        pendingObservations: String = "",
        injuries: String = "",
        userNotes: String = "",
        workoutsSinceRefresh: Int = 0
    ) {
        self.id = id
        self.lastRefreshed = lastRefreshed
        self.activityPatterns = activityPatterns
        self.trainingPatterns = trainingPatterns
        self.strengthProfile = strengthProfile
        self.recoveryProfile = recoveryProfile
        self.exercisePreferences = exercisePreferences
        self.notableObservations = notableObservations
        self.pendingObservations = pendingObservations
        self.injuries = injuries
        self.userNotes = userNotes
        self.workoutsSinceRefresh = workoutsSinceRefresh
    }

    var hasBeenRefreshed: Bool {
        lastRefreshed != .distantPast
    }

    var isStale: Bool {
        Date().daysSince(lastRefreshed) >= 7 || workoutsSinceRefresh >= 5
    }

    var formattedForPrompt: String {
        var sections: [String] = []

        if !activityPatterns.isEmpty {
            sections.append("Activity patterns: \(activityPatterns)")
        }
        if !trainingPatterns.isEmpty {
            sections.append("Training patterns: \(trainingPatterns)")
        }
        if !strengthProfile.isEmpty {
            sections.append("Strength profile: \(strengthProfile)")
        }
        if !recoveryProfile.isEmpty {
            sections.append("Recovery profile: \(recoveryProfile)")
        }
        if !exercisePreferences.isEmpty {
            sections.append("Exercise preferences: \(exercisePreferences)")
        }
        if !notableObservations.isEmpty {
            sections.append("Notable observations: \(notableObservations)")
        }
        if !pendingObservations.isEmpty {
            sections.append("Recent observations (not yet synthesized): \(pendingObservations)")
        }
        if !injuries.isEmpty {
            sections.append("INJURIES/CONCERNS (user-reported): \(injuries)")
        }
        if !userNotes.isEmpty {
            sections.append("User notes: \(userNotes)")
        }

        return sections.joined(separator: "\n")
    }
}

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

/// What the AI learned about the user through pattern-finding during an
/// intelligence refresh. Unlike rules, these are probabilistic — the AI
/// can weigh them but isn't required to obey them. They supersede on
/// `(kind, subject)` match during subsequent refreshes (bumping
/// `lastReinforcedAt`) and auto-archive after 90 days without being
/// re-observed. Top 5 active ones ride in every plan prompt.
///
/// Named `UserObservation` (not bare `Observation`) to avoid collision
/// with Apple's `Observation` module (which SwiftData types namespace
/// themselves through).
@Model
final class UserObservation {
    var id: UUID
    var kindRaw: String
    /// Scoped identifier so supersede can dedupe — usually an exercise
    /// name, muscle group, or the literal string "global" for
    /// cross-cutting findings.
    var subject: String
    /// The prose the AI produced. Short, declarative, passed into
    /// prompts verbatim.
    var text: String
    var confidenceRaw: String
    var createdAt: Date
    var lastReinforcedAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        kind: ObservationKind,
        subject: String,
        text: String,
        confidence: ObservationConfidence = .medium,
        createdAt: Date = Date(),
        lastReinforcedAt: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.subject = subject
        self.text = text
        self.confidenceRaw = confidence.rawValue
        self.createdAt = createdAt
        self.lastReinforcedAt = lastReinforcedAt ?? createdAt
        self.isActive = isActive
    }

    var kind: ObservationKind {
        ObservationKind(rawValue: kindRaw) ?? .unknown
    }

    var confidence: ObservationConfidence {
        ObservationConfidence(rawValue: confidenceRaw) ?? .medium
    }

    /// True when the observation hasn't been reinforced in 90 days —
    /// the refresh job soft-archives these so the active set stays
    /// current.
    var isStale: Bool {
        Date().timeIntervalSince(lastReinforcedAt) > 90 * 24 * 3600
    }
}

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
