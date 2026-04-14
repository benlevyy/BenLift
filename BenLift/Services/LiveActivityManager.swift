import ActivityKit
import Foundation

/// Manages the workout Live Activity lifecycle (Lock Screen + Dynamic Island).
@Observable
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<WorkoutActivityAttributes>?

    var isActivityActive: Bool {
        currentActivity != nil
    }

    func startActivity(sessionName: String, totalExercises: Int) {
        let authInfo = ActivityAuthorizationInfo()
        print("[BenLift/LiveActivity] areActivitiesEnabled: \(authInfo.areActivitiesEnabled), frequentPushesEnabled: \(authInfo.frequentPushesEnabled)")
        guard authInfo.areActivitiesEnabled else {
            print("[BenLift/LiveActivity] Activities not enabled — check Settings > BenLift > Live Activities")
            return
        }

        // End any existing activity first
        if currentActivity != nil {
            endActivityImmediately()
        }

        let attributes = WorkoutActivityAttributes(
            sessionName: sessionName,
            totalExercises: totalExercises,
            startDate: Date()
        )

        let initialState = WorkoutActivityAttributes.ContentState(
            currentExerciseName: "Starting...",
            currentExerciseIndex: 0,
            setsCompleted: 0,
            totalSets: 0,
            restEndDate: nil,
            isResting: false,
            heartRate: 0,
            elapsedSeconds: 0,
            totalVolume: 0,
            exercisesCompleted: 0
        )

        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            print("[BenLift/LiveActivity] Started: \(sessionName), id: \(currentActivity?.id ?? "nil")")
        } catch let error as ActivityAuthorizationError {
            print("[BenLift/LiveActivity] Auth error: \(error), reason: \(error.localizedDescription)")
        } catch {
            print("[BenLift/LiveActivity] Failed to start: \(error), type: \(type(of: error))")
        }
    }

    func update(state: WorkoutActivityAttributes.ContentState) {
        guard let activity = currentActivity else { return }
        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.update(content)
        }
    }

    func endActivity(finalState: WorkoutActivityAttributes.ContentState? = nil) {
        guard let activity = currentActivity else { return }
        let activityToEnd = activity
        currentActivity = nil
        Task {
            if let finalState {
                let content = ActivityContent(state: finalState, staleDate: nil)
                await activityToEnd.end(content, dismissalPolicy: .immediate)
            } else {
                await activityToEnd.end(nil, dismissalPolicy: .immediate)
            }
            print("[BenLift/LiveActivity] Ended (immediate)")
        }
    }

    /// Ends any active Live Activity unconditionally — safety net for finish paths.
    func endAnyActivity() {
        endActivity(finalState: nil)
        // Also end any orphaned activities from previous app launches
        Task {
            for activity in Activity<WorkoutActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func endActivityImmediately() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }
}
