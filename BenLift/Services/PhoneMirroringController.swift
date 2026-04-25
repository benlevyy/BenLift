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

    /// Debounce window for `startMirrorSession` across the three entry points
    /// (HK handler, WCSession lifecycle, ContentView.onAppear). Without this,
    /// a normal watch start fires HK+WCSession within ~200ms and each racer
    /// independently calls `startMirroredWorkout`, resetting the VM snapshot
    /// to nil and silently dropping any state that arrived in between.
    private var lastMirrorStartAt: Date = .distantPast
    private let mirrorStartDebounce: TimeInterval = 1.0

    private var phoneCommandObserver: NSObjectProtocol?
    private var vitalsObserver: NSObjectProtocol?

    init() {
        // Wire listeners BEFORE registering the HK handler.
        WorkoutMirroringService.shared.onMirroredWorkoutStarted = { [weak self] _ in
            self?.startMirrorSession(source: "HK")
        }
        WorkoutMirroringService.shared.onMessageReceived = { [weak self] message in
            self?.phoneWorkoutVM.handleMirroredMessage(message)
        }
        // When WCSession reachability recovers during an active workout,
        // pull a fresh snapshot so the phone isn't rendering stale state
        // (the watch may have mutated during the gap).
        WatchSyncService.shared.onReachabilityRecovered = { [weak self] in
            guard let self, self.phoneWorkoutVM.isWorkoutActive else { return }
            print("[BenLift/PhoneMirroring] Reachability recovered — requesting fresh snapshot")
            self.phoneWorkoutVM.requestFreshSnapshot()
        }
        // Watch-originated commands during a phone-owned session arrive
        // via WCSession into `WatchSyncService.receivedPhoneCommand`. We
        // dispatch on the main queue so the VM mutation runs on the UI
        // thread (handleRemoteCommand is @MainActor).
        phoneCommandObserver = NotificationCenter.default.addObserver(
            forName: .phoneCommandReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on main queue (per `queue: .main`), and the VM's
            // `handleRemoteCommand` is `@MainActor` — safe to call directly.
            guard let cmd = WatchSyncService.shared.receivedPhoneCommand else { return }
            WatchSyncService.shared.receivedPhoneCommand = nil  // one-shot
            MainActor.assumeIsolated {
                self?.phoneWorkoutVM.handleRemoteCommand(cmd)
            }
        }
        // Live vitals from the watch's sensor-only HK session. Ephemeral —
        // we don't queue these, so if the phone is backgrounded we just
        // miss a tick. The VM falls back to snapshot HR after 10s silence.
        vitalsObserver = NotificationCenter.default.addObserver(
            forName: .vitalsReceived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let hr = note.userInfo?["hr"] as? Double ?? 0
            let cal = note.userInfo?["cal"] as? Double ?? 0
            MainActor.assumeIsolated {
                self?.phoneWorkoutVM.applyLiveVitals(hr: hr, calories: cal)
            }
        }
        WorkoutMirroringService.shared.setup()
        print("[BenLift/PhoneMirroring] Controller ready — callbacks wired before HK setup")
    }

    deinit {
        if let phoneCommandObserver {
            NotificationCenter.default.removeObserver(phoneCommandObserver)
        }
        if let vitalsObserver {
            NotificationCenter.default.removeObserver(vitalsObserver)
        }
    }

    /// Single funnel for every mirror-start trigger. Debounces across entry
    /// points so the 3 callers (HK, WCSession, onAppear) can safely all call
    /// it on a normal watch start without racing to reset the VM's snapshot.
    private func startMirrorSession(source: String) {
        // Already up and running — nothing to do.
        guard !phoneWorkoutVM.isWorkoutActive else {
            print("[BenLift/PhoneMirroring] \(source): already active, skip")
            return
        }
        // Recently finished — this is probably a phantom event riding the tail
        // of the prior session's HK/WCSession tear-down. Window is wider than
        // HK stream skew (~100ms) but tight enough for legit back-to-back use.
        if let finishedAt = phoneWorkoutVM.justFinishedAt,
           Date().timeIntervalSince(finishedAt) < 5 {
            print("[BenLift/PhoneMirroring] \(source): within 5s of finish, skip phantom")
            return
        }
        // Another start path fired within the debounce window. Drop to avoid
        // trampling the in-flight startMirroredWorkout/snapshot arrival.
        let now = Date()
        if now.timeIntervalSince(lastMirrorStartAt) < mirrorStartDebounce {
            print("[BenLift/PhoneMirroring] \(source): within debounce, skip")
            return
        }
        lastMirrorStartAt = now
        phoneWorkoutVM.justFinishedAt = nil
        phoneWorkoutVM.startMirroredWorkout(plan: nil)
        showPhoneWorkout = true
        print("[BenLift/PhoneMirroring] \(source): mirror session started")
    }

    /// Called from ContentView.onAppear to join a workout that was already active
    /// at launch (WCSession had time to deliver `isWorkoutActive=true` before us).
    func joinActiveWorkoutIfNeeded() {
        startMirrorSession(source: "onAppear")
    }

    /// WCSession reports the Watch kicked off a workout. 5s guard drops in-flight
    /// "workoutStarted" messages that queued before a finish (phantoms) without
    /// blocking legitimate back-to-back sessions.
    func handleWatchSessionWorkoutStarted() {
        startMirrorSession(source: "WCSession")
    }

    /// User-initiated phone-owned start, called from TodayView when the
    /// watch isn't available (or the user taps "Start here now" in the
    /// waiting overlay). Skips the debounce + phantom guards — the tap is
    /// intentional, not a race condition — but still refuses to steamroll
    /// an already-active session.
    @MainActor
    func startStandaloneSession(plan: WatchWorkoutPlan?) {
        guard !phoneWorkoutVM.isWorkoutActive else {
            print("[BenLift/PhoneMirroring] standalone: already active, skip")
            return
        }
        phoneWorkoutVM.justFinishedAt = nil
        phoneWorkoutVM.startStandaloneWorkout(plan: plan)
        showPhoneWorkout = true
        print("[BenLift/PhoneMirroring] standalone: session started")
    }

    /// WCSession reports the Watch ended its workout. Only close the
    /// phone-side mirror UI if we were actually mirroring — a standalone
    /// session shouldn't be torn down because a *different* watch-initiated
    /// workout wrapped up somewhere else.
    func handleWatchSessionWorkoutEnded() {
        guard phoneWorkoutVM.workoutMode == .mirroredFromWatch else { return }
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
