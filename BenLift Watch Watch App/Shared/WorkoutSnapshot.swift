import Foundation

/// The complete state of an in-progress workout. Broadcast from the OWNER (watch)
/// to MIRRORS (phone) after every state mutation. Mirrors render this verbatim —
/// they never compute their own state.
///
/// Absolute timestamps (workoutStartDate, restEndsAt, set timestamps) so that
/// background/foreground transitions don't drift.
struct WorkoutSnapshot: Codable {
    /// Monotonically increasing per-workout. Lets receivers ignore stale snapshots
    /// that arrive out of order.
    var version: Int

    /// True for the entire duration of the workout, false on the FINAL snapshot.
    var isActive: Bool

    var workoutStartDate: Date
    var sessionName: String?
    var muscleGroups: [String]            // raw values
    var category: WorkoutCategory?
    var sessionStrategy: String?

    var exercises: [SnapshotExercise]
    /// Index into `exercises` of the exercise the OWNER is currently logging on.
    /// Mirrors track their own "viewing" index independently.
    var activeExerciseIndex: Int?

    /// Absolute end time of the rest timer. nil = not resting.
    var restEndsAt: Date?
    /// Total duration of the current rest (for progress ring rendering).
    var restDuration: TimeInterval

    /// Latest HR / calorie samples from HealthKit (owner side only).
    var currentHeartRate: Double
    var activeCalories: Double

    /// Whether the in-progress session came from an AI-generated plan. Carried
    /// from `WatchWorkoutPlan.aiPlanUsed` so the phone-finish path persists the
    /// same flag as the WCSession sync-manager path would. Optional for
    /// back-compat with snapshots produced before this field existed.
    var aiPlanUsed: Bool?
}

/// One exercise in the snapshot. Mirrors the watch's `ExerciseState` shape but
/// uses value semantics for Codable transport.
struct SnapshotExercise: Codable, Identifiable {
    var id: String { name }
    var name: String
    var targetSets: Int
    var targetReps: String
    var suggestedWeight: Double
    var warmupSets: [WarmupSet]?
    var intent: String?
    var notes: String?
    var lastWeight: Double?
    var lastReps: Double?

    var loggedSets: [WatchSetResult]
    var isWarmupPhase: Bool
    /// User-initiated skip via swipe. Independent from `isComplete` — a skipped
    /// exercise doesn't count as completed sets, but shouldn't be re-surfaced
    /// as incomplete either. Optional so older snapshots decode as unskipped.
    var isSkipped: Bool?

    var effectivelySkipped: Bool { isSkipped ?? false }
    var workingSetsCompleted: Int { loggedSets.filter { !$0.isWarmup }.count }
    var warmupSetsCompleted: Int { loggedSets.filter(\.isWarmup).count }
    var totalWarmups: Int { warmupSets?.count ?? 0 }
    var isComplete: Bool { workingSetsCompleted >= targetSets }
    var totalVolume: Double {
        loggedSets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.weight * floor($1.reps) }
    }
}

/// Phone → Watch actions. Mirrors send these instead of mutating local state.
/// The owner processes them serially and broadcasts a fresh snapshot afterward.
enum WorkoutCommand: Codable {
    case logSet(exerciseIndex: Int, weight: Double, reps: Double, isWarmup: Bool)
    case undoSet(exerciseIndex: Int)
    case selectExercise(index: Int)
    case skipRest
    case adjustRestTimer(deltaSeconds: Int)
    case adaptExercise(index: Int, replacement: WatchExerciseInfo)
    case addExercise(info: WatchExerciseInfo)
    /// Terminate the in-progress workout. Optional 1...10 effort score
    /// (Apple Workout Effort scale, watchOS 11+) rides along so the HK
    /// owner can attach it to the saved HKWorkout via
    /// `HKWorkoutEffortRelationship`. nil = user skipped the prompt.
    case end(effortScore: Double?)
    /// Mirror is asking the owner to (re)send its current snapshot.
    /// Used on first connect or after backgrounding.
    case requestSnapshot
    /// Mark an exercise as skipped (user-initiated bail). Counts as "attempted,
    /// not logged" for analytics. Does NOT delete the exercise.
    case skipExercise(index: Int)
    /// Undo a prior skip — restore the exercise to the active pool.
    case unskipExercise(index: Int)
}
