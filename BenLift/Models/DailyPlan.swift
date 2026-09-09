import Foundation
import SwiftData

// MARK: - Progression

/// What the resolver did to a lift's load, relative to the last time it
/// was performed. Stored as a raw string because SwiftData can't persist
/// an enum with associated values.
enum ProgressionKind: String, Codable, CaseIterable {
    /// Every working set hit the top of the rep range cleanly — load went up.
    case progressed
    /// A set was missed, or reps landed inside the range — load stayed put.
    case held
    /// Held twice running at the same load — backed off to break the stall.
    case deloaded
    /// No prior performance to progress from (first time, or a new lift).
    case new
}

// MARK: - Cross-training flag

/// A hard non-lifting session in the recent past that collides with today's
/// muscle groups. Surfaced on the plan card as fact, never acted on
/// automatically beyond the always-safe adjustments in `appliedAdjustments`.
struct CrossTrainingFlag: Codable, Equatable {
    /// HealthKit activity name, e.g. "climbing", "running", "cycling".
    var activityType: String
    var date: Date
    var duration: TimeInterval
    /// Optional distance in miles — only meaningful for running/cycling.
    var distanceMiles: Double?
    /// One-line statement of fact: "Climbed 1h 20m yesterday".
    var headline: String
    /// Why it matters, in one sentence.
    var detail: String
    /// Adjustments the resolver already applied — true regardless of how
    /// hard the session actually was, since HealthKit can't tell us that.
    var appliedAdjustments: [String]
}

// MARK: - Plan snapshot

/// A frozen copy of a plan's lifts at a moment in time.
///
/// The live plan is mutated in place by chat edits, so "the plan before that
/// swap" doesn't exist anywhere unless it was captured. The resolver captures
/// one at creation (the pristine default), and every chat edit captures one
/// on the message that made it — which is what lets superseded cards in the
/// transcript collapse and still be reopened.
struct PlanSnapshot: Codable, Equatable {
    struct Lift: Codable, Equatable {
        var name: String
        var sets: Int
        var targetReps: String
        var weight: Double
        var note: String?
    }

    var title: String
    var lifts: [Lift]

    init(of plan: DailyPlan, title: String) {
        self.title = title
        self.lifts = plan.sortedLifts.map { lift in
            Lift(
                name: lift.name,
                sets: lift.sets,
                targetReps: lift.targetReps,
                weight: lift.weight,
                note: lift.usesStraps ? "straps" : lift.noteText
            )
        }
    }
}

// MARK: - Daily Plan

/// Today's resolved plan. Written once by `PlanResolver` on first open of
/// the day, then persisted — so reopening the app (or editing via chat)
/// never re-derives it and silently discards the user's changes.
@Model
final class DailyPlan {
    var id: UUID
    /// Start of the day this plan belongs to. One plan per day.
    var date: Date
    /// Push / pull / legs, when the rotation produced one.
    var categoryRaw: String?
    /// The split day this plan was resolved for ("Upper", "Push", ...). The
    /// category above only exists for push/pull/legs; this is the identity
    /// that works for every split. Optional so plans from before splits
    /// existed migrate cleanly.
    var dayName: String?
    var muscleGroupsData: Data?
    @Relationship(deleteRule: .cascade, inverse: \PlannedLift.plan)
    var lifts: [PlannedLift]
    /// Date of the session this plan was replayed from. Nil on a cold start
    /// where the plan came from the default template instead.
    var replayedFromDate: Date?
    /// Human-readable provenance for the card footer, e.g.
    /// "Replayed from Mon 1 Sep · 2 lifts progressed".
    var resolverNote: String?
    /// 1.0 normally; 0.9 when the last session of this type is >14 days old.
    var stalenessScale: Double
    var crossTrainingFlagData: Data?
    /// The plan exactly as the resolver produced it, before any chat edit —
    /// what the collapsed "Today's plan" row reopens to once edits have
    /// superseded it. Written once at resolve time, never updated.
    var originalSnapshotData: Data?
    /// Set once chat (or a manual edit) has touched the plan, so a later
    /// resolve knows not to clobber it.
    var wasEdited: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        category: WorkoutCategory? = nil,
        dayName: String? = nil,
        muscleGroups: [MuscleGroup] = [],
        lifts: [PlannedLift] = [],
        replayedFromDate: Date? = nil,
        resolverNote: String? = nil,
        stalenessScale: Double = 1.0,
        crossTrainingFlag: CrossTrainingFlag? = nil,
        wasEdited: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.categoryRaw = category?.rawValue
        self.dayName = dayName
        self.muscleGroupsData = Data.encodeJSON(muscleGroups)
        self.lifts = lifts
        self.replayedFromDate = replayedFromDate
        self.resolverNote = resolverNote
        self.stalenessScale = stalenessScale
        self.crossTrainingFlagData = crossTrainingFlag.flatMap { Data.encodeJSON($0) }
        self.wasEdited = wasEdited
        self.createdAt = createdAt
    }

    var category: WorkoutCategory? {
        get { categoryRaw.flatMap(WorkoutCategory.init(rawValue:)) }
        set { categoryRaw = newValue?.rawValue }
    }

    var muscleGroups: [MuscleGroup] {
        get { muscleGroupsData?.decodeJSON([MuscleGroup].self) ?? [] }
        set { muscleGroupsData = Data.encodeJSON(newValue) }
    }

    var crossTrainingFlag: CrossTrainingFlag? {
        get { crossTrainingFlagData?.decodeJSON(CrossTrainingFlag.self) }
        set { crossTrainingFlagData = newValue.flatMap { Data.encodeJSON($0) } }
    }

    var originalSnapshot: PlanSnapshot? {
        get { originalSnapshotData?.decodeJSON(PlanSnapshot.self) }
        set { originalSnapshotData = newValue.flatMap { Data.encodeJSON($0) } }
    }

    var sortedLifts: [PlannedLift] {
        lifts.sorted { $0.order < $1.order }
    }

    /// Card title — "Push", "Pull", "Legs", or the muscle list for a plan
    /// the rotation couldn't categorise.
    var displayName: String {
        if let dayName { return dayName }
        if let category { return category.displayName }
        let groups = muscleGroups
        if groups.isEmpty { return "Workout" }
        return groups.map(\.displayName).joined(separator: " + ")
    }

    /// Rough duration estimate for the card header. ~3 min per working set
    /// including rest, which is close enough for a "~52 min" label.
    var estimatedMinutes: Int {
        max(10, lifts.reduce(0) { $0 + $1.sets } * 3)
    }
}

// MARK: - Planned Lift

@Model
final class PlannedLift {
    var id: UUID
    var name: String
    var order: Int
    var sets: Int
    /// Rep target as authored, e.g. "8-12" or "6". Parsed by `repRange`.
    var targetReps: String
    var weight: Double
    var muscleGroupRaw: String?
    /// "primary compound" / "secondary compound" / "isolation" / "finisher".
    var intentRaw: String?
    var progressionRaw: String
    /// Signed load change from the last performance, in lbs.
    var progressionDelta: Double
    /// Short subtitle for the row, e.g. "was Bench Press".
    var noteText: String?
    /// Set when a cross-training flag put this lift on straps.
    var usesStraps: Bool
    var plan: DailyPlan?

    init(
        id: UUID = UUID(),
        name: String,
        order: Int,
        sets: Int,
        targetReps: String,
        weight: Double,
        muscleGroup: MuscleGroup? = nil,
        intent: String? = nil,
        progression: ProgressionKind = .new,
        progressionDelta: Double = 0,
        noteText: String? = nil,
        usesStraps: Bool = false
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.sets = sets
        self.targetReps = targetReps
        self.weight = weight
        self.muscleGroupRaw = muscleGroup?.rawValue
        self.intentRaw = intent
        self.progressionRaw = progression.rawValue
        self.progressionDelta = progressionDelta
        self.noteText = noteText
        self.usesStraps = usesStraps
    }

    var muscleGroup: MuscleGroup? {
        get { muscleGroupRaw.flatMap(MuscleGroup.init(rawValue:)) }
        set { muscleGroupRaw = newValue?.rawValue }
    }

    var progression: ProgressionKind {
        get { ProgressionKind(rawValue: progressionRaw) ?? .new }
        set { progressionRaw = newValue.rawValue }
    }

    /// Parsed low/high bounds of `targetReps`. "8-12" → (8, 12); "6" → (6, 6).
    /// Returns nil for anything unparseable, which callers treat as
    /// "can't evaluate progression".
    var repRange: (low: Int, high: Int)? {
        Self.parseRepRange(targetReps)
    }

    static func parseRepRange(_ raw: String) -> (low: Int, high: Int)? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: "-", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) {
            return (min(lo, hi), max(lo, hi))
        }
        if let single = Int(cleaned) { return (single, single) }
        return nil
    }
}

// MARK: - Watch handoff

extension DailyPlan {
    /// Convert to the payload the Watch and the phone runner both consume.
    /// Returns nil for an empty plan so Start can't launch a session with
    /// nothing in it.
    func toWatchPlan(
        recentExercises: [String] = [],
        recentWeights: [String: Double] = [:]
    ) -> WatchWorkoutPlan? {
        guard !lifts.isEmpty else { return nil }

        let exercises = sortedLifts.map { lift in
            WatchExerciseInfo(
                name: lift.name,
                sets: lift.sets,
                targetReps: lift.targetReps,
                suggestedWeight: lift.weight,
                warmupSets: nil,
                notes: lift.usesStraps ? "Straps" : lift.noteText,
                intent: lift.intentRaw,
                lastWeight: nil,
                lastReps: nil,
                equipment: DefaultExercises.all.first { $0.name == lift.name }?.equipment
            )
        }

        let restTimer = UserDefaults.standard.double(forKey: "restTimerDuration")
        let increment = UserDefaults.standard.double(forKey: "weightIncrement")

        return WatchWorkoutPlan(
            sessionName: displayName,
            muscleGroups: muscleGroups.map(\.rawValue),
            category: category,
            exercises: exercises,
            sessionStrategy: resolverNote,
            restTimerDuration: restTimer > 0 ? restTimer : 150,
            weightIncrement: increment > 0 ? increment : 5.0,
            // The plan is deterministic unless chat touched it — this flag
            // is what History uses to mark a session as AI-influenced.
            aiPlanUsed: wasEdited,
            recentExercises: recentExercises.isEmpty ? nil : recentExercises,
            recentWeights: recentWeights.isEmpty ? nil : recentWeights
        )
    }
}
