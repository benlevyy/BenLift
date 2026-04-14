import Foundation

/// App-scoped owner of `PhoneWorkoutViewModel` and the mirroring callbacks.
/// Initialized in `BenLiftApp.init` so the HK mirror-start handler and message
/// listener are live before `WorkoutMirroringService.setup()` registers with
/// HealthKit — closes the cold-launch race where the first mirrored session
/// event could be dropped into a nil callback.
@Observable
class PhoneMirroringController {
    let phoneWorkoutVM = PhoneWorkoutViewModel()
    var showPhoneWorkout = false

    init() {
        // Wire listeners BEFORE registering the HK handler.
        WorkoutMirroringService.shared.onMirroredWorkoutStarted = { [weak self] _ in
            guard let self else { return }
            phoneWorkoutVM.justFinishedAt = nil
            guard !phoneWorkoutVM.isWorkoutActive else { return }
            phoneWorkoutVM.startMirroredWorkout(plan: nil)
            showPhoneWorkout = true
        }
        WorkoutMirroringService.shared.onMessageReceived = { [weak self] message in
            self?.phoneWorkoutVM.handleMirroredMessage(message)
        }
        WorkoutMirroringService.shared.setup()
        print("[BenLift/PhoneMirroring] Controller ready — callbacks wired before HK setup")
    }

    /// Called from ContentView.onAppear to join a workout that was already active
    /// at launch (WCSession had time to deliver `isWorkoutActive=true` before us).
    func joinActiveWorkoutIfNeeded() {
        guard !phoneWorkoutVM.isWorkoutActive else { return }
        phoneWorkoutVM.justFinishedAt = nil
        phoneWorkoutVM.startMirroredWorkout(plan: nil)
        showPhoneWorkout = true
    }

    /// WCSession reports the Watch kicked off a workout. 5s guard drops in-flight
    /// "workoutStarted" messages that queued before a finish (phantoms) without
    /// blocking legitimate back-to-back sessions.
    func handleWatchSessionWorkoutStarted() {
        guard !phoneWorkoutVM.isWorkoutActive else { return }
        if let finishedAt = phoneWorkoutVM.justFinishedAt,
           Date().timeIntervalSince(finishedAt) < 5 {
            return
        }
        phoneWorkoutVM.justFinishedAt = nil
        phoneWorkoutVM.startMirroredWorkout(plan: nil)
        showPhoneWorkout = true
    }

    /// WCSession reports the Watch ended its workout.
    func handleWatchSessionWorkoutEnded() {
        guard phoneWorkoutVM.workoutMode == .mirroredFromWatch else { return }
        phoneWorkoutVM.workoutMode = .standalone
        phoneWorkoutVM.justFinishedAt = Date()
        showPhoneWorkout = false
        LiveActivityManager.shared.endAnyActivity()
    }

    /// Called when the VM's own `isWorkoutActive` flips to false (e.g. final
    /// snapshot arrives, or phone-initiated finish).
    func handlePhoneWorkoutEnded() {
        showPhoneWorkout = false
        LiveActivityManager.shared.endAnyActivity()
    }
}
