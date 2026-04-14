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
    let version: Int

    /// True for the entire duration of the workout, false on the FINAL snapshot.
    let isActive: Bool

    let workoutStartDate: Date
    let sessionName: String?
    let muscleGroups: [String]            // raw values
    let category: WorkoutCategory?
    let sessionStrategy: String?

    let exercises: [SnapshotExercise]
    /// Index into `exercises` of the exercise the OWNER is currently logging on.
    /// Mirrors track their own "viewing" index independently.
    let activeExerciseIndex: Int?

    /// Absolute end time of the rest timer. nil = not resting.
    let restEndsAt: Date?
    /// Total duration of the current rest (for progress ring rendering).
    let restDuration: TimeInterval

    /// Latest HR / calorie samples from HealthKit (owner side only).
    let currentHeartRate: Double
    let activeCalories: Double
}

/// One exercise in the snapshot. Mirrors the watch's `ExerciseState` shape but
/// uses value semantics for Codable transport.
struct SnapshotExercise: Codable, Identifiable {
    var id: String { name }
    let name: String
    let targetSets: Int
    let targetReps: String
    let suggestedWeight: Double
    let warmupSets: [WarmupSet]?
    let intent: String?
    let notes: String?
    let lastWeight: Double?
    let lastReps: Double?

    let loggedSets: [WatchSetResult]
    let isWarmupPhase: Bool

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
    case end
    /// Mirror is asking the owner to (re)send its current snapshot.
    /// Used on first connect or after backgrounding.
    case requestSnapshot
}
