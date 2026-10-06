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

    /// What the user typed about this exercise during the session — "elbow
    /// talking on set 2", "try 140 next time". Distinct from `notes`, which
    /// is the plan's own annotation ("was Bench Press", "Straps"). Persists
    /// to `ExerciseEntry.note`. Optional so older snapshots decode.
    var userNote: String? = nil

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
    /// Set (or clear, with nil) the user's note on an exercise.
    case setNote(exerciseIndex: Int, note: String?)
    /// Change how many working sets an exercise calls for, mid-session.
    /// `delta` of +1 is "add a set", -1 is "skip the one I'm not doing".
    /// The owner clamps; mirrors just send the intent.
    case adjustTargetSets(index: Int, delta: Int)
}

// MARK: - Rest timing

/// How long to rest after a working set.
///
/// The user's Settings value is the baseline; exercise intent scales it.
/// Before this, intent assigned *absolute* durations (180/120/75/60) on every
/// logged set, which clobbered the setting outright — and since almost every
/// planned exercise carries an intent, the Rest Timer stepper in Settings
/// genuinely did nothing. Multipliers are expressed relative to the 150s
/// default so leaving the setting alone reproduces the old numbers exactly.
enum RestTiming {
    static let defaultDuration: TimeInterval = 150

    static func multiplier(for intent: String?) -> Double {
        switch intent {
        case "primary compound": return 1.2    // 180s at the default base
        case "secondary compound": return 0.8  // 120s
        case "isolation": return 0.5           //  75s
        case "finisher": return 0.4            //  60s
        default: return 1.0
        }
    }

    /// Rounded to 5s — a rest timer that reads 2:37 looks like a bug, not a
    /// preference. Floored at 15s so a very short base can't produce a timer
    /// that expires before the user has racked the weight.
    static func duration(base: TimeInterval, intent: String?) -> TimeInterval {
        let scaled = base * multiplier(for: intent)
        return max(15, (scaled / 5).rounded() * 5)
    }
}
