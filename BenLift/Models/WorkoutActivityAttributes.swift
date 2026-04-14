import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    // Static: set once at workout start
    let sessionName: String
    let totalExercises: Int
    let startDate: Date

    struct ContentState: Codable, Hashable {
        let currentExerciseName: String
        let currentExerciseIndex: Int
        let setsCompleted: Int
        let totalSets: Int
        let restEndDate: Date?     // nil when not resting; absolute end time when resting
        let isResting: Bool
        let heartRate: Int
        let elapsedSeconds: Int
        let totalVolume: Int
        let exercisesCompleted: Int
    }
}
