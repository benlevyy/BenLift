import Foundation
import WatchConnectivity

// ⚠️ SHARED FILE — KEEP IN LOCKSTEP WITH THE WATCH COPY AT
// `BenLift Watch Watch App/Shared/WatchSyncService.swift`.
// These two files are compiled separately by each target today; any change here
// must be mirrored there verbatim (the only platform differences are gated by
// `#if os(iOS)` / `#if os(watchOS)` below). A future Xcode refactor should
// unify these into a single file with membership in both targets.

/// Shared WatchConnectivity service. On iOS: sends plans to Watch, receives results
/// back. On watchOS: receives plans, sends results back. Lifecycle signals
/// (workoutStarted/Ended) flow both ways.
class WatchSyncService: NSObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isWorkoutActive = false  // Set by Watch via message when workout starts/ends

    #if os(iOS)
    /// Fires when reachability transitions false → true while a workout is
    /// active. Hook from PhoneMirroringController to request a fresh snapshot
    /// so the phone doesn't render stale state after a BT/wrist-wake gap.
    var onReachabilityRecovered: (() -> Void)?
    /// Previous reachability value — needed to detect the rising edge.
    private var lastReachable: Bool = false
    #endif

    // iOS: received workout result from Watch
    var receivedWorkoutResult: WatchWorkoutResult? {
        didSet { NotificationCenter.default.post(name: .workoutResultReceived, object: nil) }
    }

    // watchOS: received workout plan from iPhone
    var receivedPlan: WatchWorkoutPlan? {
        didSet { NotificationCenter.default.post(name: .workoutPlanReceived, object: nil) }
    }

    // watchOS: cached exercise library + metadata
    var exerciseLibrary: WatchExerciseLibrary?

    // watchOS: latest snapshot from a PHONE-owned session. When the user
    // starts a workout on the phone (watch unavailable or chose not to
    // engage HK mirroring), the phone broadcasts snapshots here so the
    // watch can render the same session — "act as one" even though the
    // phone is the single source of truth.
    var receivedPhoneSnapshot: WorkoutSnapshot?

    // iOS: latest command a phone-owned workout received from the watch.
    // Phone reads + clears this to apply the mutation; watch used sendMessage
    // (or transferUserInfo fallback) to deliver it. Kept as a simple latest-
    // command slot plus a notification so the mirroring controller can
    // route immediately.
    var receivedPhoneCommand: WorkoutCommand? {
        didSet { NotificationCenter.default.post(name: .phoneCommandReceived, object: nil) }
    }

    private override init() {
        super.init()
    }

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else {
            print("[BenLift/Sync] WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        print("[BenLift/Sync] WCSession activating...")
    }

    // MARK: - iOS → Watch: Send Workout Plan

    func sendWorkoutPlan(_ plan: WatchWorkoutPlan) {
        guard WCSession.default.activationState == .activated else {
            print("[BenLift/Sync] ❌ Session not activated")
            return
        }

        do {
            let data = try JSONEncoder().encode(plan)
            let payload = data.base64EncodedString()
            WCSession.default.transferUserInfo([
                "type": "workoutPlan",
                "payload": payload,
            ])
            print("[BenLift/Sync] → Sent workout plan to Watch (\(data.count) bytes, \(plan.exercises.count) exercises)")
        } catch {
            print("[BenLift/Sync] ❌ Failed to encode plan: \(error)")
        }
    }

    // MARK: - iOS → Watch: Broadcast Phone-Owned Snapshot
    //
    // When the phone owns a workout (no watch / user tapped "Start here
    // now"), the watch still wants to show what's happening — "start
    // anywhere, see anywhere." We piggyback on `updateApplicationContext`
    // so the latest state always wins (older snapshots get replaced) and
    // the watch gets it on next activation even if it was asleep.

    #if os(iOS)
    func sendPhoneOwnedSnapshot(_ snapshot: WorkoutSnapshot) {
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            let payload = data.base64EncodedString()
            try WCSession.default.updateApplicationContext([
                "type": "phoneOwnedSnapshot",
                "payload": payload,
            ])
        } catch {
            print("[BenLift/Sync] ❌ Failed to send phone-owned snapshot: \(error)")
        }
    }
    #endif

    // MARK: - watchOS → iPhone: Send Command for phone-owned session
    //
    // Watch is a full participant now, not a read-only view. When the user
    // taps log / skip / swap / finish on the watch during a phone-owned
    // session, we send the `WorkoutCommand` to the phone over WCSession;
    // phone processes it through the same standalone mutators, then
    // broadcasts the updated snapshot back. sendMessage is used when the
    // phone is reachable (realtime), transferUserInfo as persistent
    // fallback so a command queued during a flap still applies once the
    // phone wakes up.

    // MARK: - watchOS → iPhone: Stream live vitals (phone-owned session)
    //
    // When the watch runs a sensor-only HKWorkoutSession on behalf of a
    // phone-owned workout, HR and active calories have nowhere to go via
    // HK mirroring (no mirrored session exists — the phone is the app-level
    // owner but not the HK owner). We push them over WCSession as a real-
    // time message instead. Ephemeral: if unreachable we drop. HR is not
    // worth queueing via transferUserInfo (stale HR is useless).

    #if os(watchOS)
    func sendVitals(heartRate: Double, calories: Double) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["type": "vitals", "hr": heartRate, "cal": calories],
            replyHandler: nil,
            errorHandler: nil
        )
    }
    #endif

    #if os(watchOS)
    func sendPhoneCommand(_ command: WorkoutCommand) {
        guard WCSession.default.activationState == .activated else {
            print("[BenLift/Sync] ❌ Session not activated, can't send phone command")
            return
        }
        do {
            let data = try JSONEncoder().encode(command)
            let payload = data.base64EncodedString()
            let dict: [String: Any] = ["type": "phoneCommand", "payload": payload]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(dict, replyHandler: nil, errorHandler: { err in
                    print("[BenLift/Sync] sendMessage(phoneCommand) failed: \(err). Queuing via transferUserInfo.")
                    WCSession.default.transferUserInfo(dict)
                })
            } else {
                WCSession.default.transferUserInfo(dict)
            }
        } catch {
            print("[BenLift/Sync] ❌ Failed to encode phone command: \(error)")
        }
    }
    #endif

    // MARK: - iOS → Watch: Send Exercise Library (via applicationContext)

    func sendExerciseLibrary(_ library: WatchExerciseLibrary) {
        guard WCSession.default.activationState == .activated else { return }

        do {
            let data = try JSONEncoder().encode(library)
            let payload = data.base64EncodedString()
            try WCSession.default.updateApplicationContext([
                "type": "exerciseLibrary",
                "payload": payload,
            ])
            print("[BenLift/Sync] → Sent exercise library to Watch (\(library.exercises.count) exercises)")
        } catch {
            print("[BenLift/Sync] ❌ Failed to send exercise library: \(error)")
        }
    }

    // MARK: - watchOS → iPhone: Send Workout Result

    func sendWorkoutResult(_ result: WatchWorkoutResult) {
        guard WCSession.default.activationState == .activated else {
            print("[BenLift/Sync] ❌ Session not activated, can't send result")
            return
        }

        do {
            let data = try JSONEncoder().encode(result)
            let payload = data.base64EncodedString()
            WCSession.default.transferUserInfo([
                "type": "workoutResult",
                "payload": payload,
            ])
            print("[BenLift/Sync] → Sent workout result to iPhone (\(data.count) bytes)")
        } catch {
            print("[BenLift/Sync] ❌ Failed to encode result: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            #if os(iOS)
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.lastReachable = session.isReachable
            print("[BenLift/Sync] Session activated: paired=\(session.isPaired), installed=\(session.isWatchAppInstalled), reachable=\(session.isReachable)")
            #else
            print("[BenLift/Sync] Watch session activated: reachable=\(session.isReachable)")
            #endif
        }
        if let error {
            print("[BenLift/Sync] ❌ Activation error: \(error)")
        }
    }

    // Required on iOS only
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("[BenLift/Sync] Session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("[BenLift/Sync] Session deactivated, reactivating...")
        session.activate()
    }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            #if os(iOS)
            let becameReachable = !self.lastReachable && session.isReachable
            self.lastReachable = session.isReachable
            #endif
            self.isReachable = session.isReachable
            print("[BenLift/Sync] Reachability changed: \(session.isReachable)")
            #if os(iOS)
            if becameReachable && self.isWorkoutActive {
                // Rising edge during an active workout — the phone may have
                // missed snapshots while disconnected. Let the mirror layer
                // pull a fresh one.
                self.onReachabilityRecovered?()
            }
            #endif
        }
    }

    // MARK: - Receive transferUserInfo

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Lightweight signals (no payload)
        if let type = userInfo["type"] as? String, userInfo["payload"] == nil {
            DispatchQueue.main.async {
                switch type {
                case "workoutEnded":
                    self.isWorkoutActive = false
                    #if os(watchOS)
                    // Watch listens for remote-finish so the WorkoutViewModel
                    // can shut down if the phone initiated the end while we
                    // were briefly unreachable.
                    NotificationCenter.default.post(name: .remoteFinishRequested, object: nil)
                    #endif
                    print("[BenLift/Sync] ← Workout ended (queued)")
                default:
                    print("[BenLift/Sync] Unknown signal userInfo: \(type)")
                }
            }
            return
        }

        guard let type = userInfo["type"] as? String,
              let payloadString = userInfo["payload"] as? String,
              let payloadData = Data(base64Encoded: payloadString) else {
            print("[BenLift/Sync] ❌ Invalid userInfo format")
            return
        }

        let decoder = JSONDecoder()

        switch type {
        case "workoutPlan":
            if let plan = try? decoder.decode(WatchWorkoutPlan.self, from: payloadData) {
                DispatchQueue.main.async {
                    self.receivedPlan = plan
                    print("[BenLift/Sync] ← Received workout plan: \(plan.exercises.count) exercises")
                }
            }

        case "workoutResult":
            if let result = try? decoder.decode(WatchWorkoutResult.self, from: payloadData) {
                DispatchQueue.main.async {
                    self.receivedWorkoutResult = result
                    print("[BenLift/Sync] ← Received workout result: \(result.entries.count) exercises")
                }
            }

        case "phoneCommand":
            // Watch-originated command that queued up (sendMessage failed
            // / wasn't reachable). Same decode + deliver path as the
            // realtime sendMessage branch above.
            #if os(iOS)
            handlePhoneCommandPayload(payloadString)
            #endif

        default:
            print("[BenLift/Sync] Unknown userInfo type: \(type)")
        }
    }

    // MARK: - Receive sendMessage (real-time)

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let type = message["type"] as? String {
            switch type {
            case "workoutStarted":
                DispatchQueue.main.async {
                    self.isWorkoutActive = true
                    print("[BenLift/Sync] ← Watch workout started")
                }
            case "workoutEnded":
                DispatchQueue.main.async {
                    self.isWorkoutActive = false
                    #if os(watchOS)
                    NotificationCenter.default.post(name: .remoteFinishRequested, object: nil)
                    #endif
                    print("[BenLift/Sync] ← Workout ended (remote)")
                }
            case "phoneCommand":
                // Watch-originated command for a phone-owned session.
                // Only the phone cares about this; the watch just sent it
                // and already dispatched local state optimistically (if at
                // all).
                #if os(iOS)
                handlePhoneCommandPayload(message["payload"] as? String)
                #endif
            case "vitals":
                // Real-time HR / calorie stream from the watch during a
                // phone-owned session. Routed through a notification so
                // the PhoneWorkoutViewModel can overlay into the snapshot
                // without WatchSyncService knowing about VM shape.
                #if os(iOS)
                let hr = message["hr"] as? Double ?? 0
                let cal = message["cal"] as? Double ?? 0
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .vitalsReceived,
                        object: nil,
                        userInfo: ["hr": hr, "cal": cal]
                    )
                }
                #endif
            default:
                print("[BenLift/Sync] Unknown message type: \(type)")
            }
        }
    }

    /// Decode + deliver a phone command payload (base64-encoded JSON of
    /// `WorkoutCommand`). Same shape whether it arrived over sendMessage
    /// or transferUserInfo — both paths use the same dictionary keys.
    #if os(iOS)
    private func handlePhoneCommandPayload(_ payloadString: String?) {
        guard let payloadString,
              let data = Data(base64Encoded: payloadString),
              let cmd = try? JSONDecoder().decode(WorkoutCommand.self, from: data) else {
            print("[BenLift/Sync] ❌ Couldn't decode phoneCommand payload")
            return
        }
        DispatchQueue.main.async {
            self.receivedPhoneCommand = cmd
            print("[BenLift/Sync] ← Phone command from watch: \(cmd)")
        }
    }
    #endif

    // MARK: - Watch → iPhone: Send workout status (call from Watch side)

    func sendWorkoutStarted() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["type": "workoutStarted"], replyHandler: nil, errorHandler: nil)
    }

    func sendWorkoutEnded() {
        // Try real-time first (instant if reachable)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "workoutEnded"], replyHandler: nil, errorHandler: { error in
                print("[BenLift/Sync] sendMessage(workoutEnded) failed: \(error). Falling back to transferUserInfo")
            })
        }
        // Always also queue via transferUserInfo so it survives reachability flaps
        WCSession.default.transferUserInfo(["type": "workoutEnded"])
        print("[BenLift/Sync] → Queued workoutEnded (reachable=\(WCSession.default.isReachable))")
    }

    // MARK: - Receive applicationContext

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let type = applicationContext["type"] as? String,
              let payloadString = applicationContext["payload"] as? String,
              let payloadData = Data(base64Encoded: payloadString) else { return }

        if type == "exerciseLibrary" {
            if let library = try? JSONDecoder().decode(WatchExerciseLibrary.self, from: payloadData) {
                DispatchQueue.main.async {
                    self.exerciseLibrary = library
                    print("[BenLift/Sync] ← Received exercise library: \(library.exercises.count) exercises")
                }
            }
        } else if type == "phoneOwnedSnapshot" {
            // Phone is the owner of an active workout; we're the passive
            // display. Reuses the same `WorkoutSnapshot` the watch-owned
            // path uses — watch UI renders from snapshot either way.
            if let snap = try? JSONDecoder().decode(WorkoutSnapshot.self, from: payloadData) {
                DispatchQueue.main.async {
                    self.receivedPhoneSnapshot = snap
                    NotificationCenter.default.post(name: .phoneOwnedSnapshotReceived, object: nil)
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workoutPlanReceived = Notification.Name("workoutPlanReceived")
    static let workoutResultReceived = Notification.Name("workoutResultReceived")
    /// Watch listens for this to finish a session the phone initiated end on.
    /// Declared in the shared file so both targets see the identifier.
    static let remoteFinishRequested = Notification.Name("remoteFinishRequested")
    /// Watch-side hook: the phone broadcast a fresh snapshot of its owned
    /// workout. Watch's WorkoutViewModel listens so it can refresh state.
    static let phoneOwnedSnapshotReceived = Notification.Name("phoneOwnedSnapshotReceived")
    /// iOS-side hook: a watch-originated command arrived for the phone's
    /// owned session. PhoneMirroringController listens and dispatches to
    /// the VM's `handleRemoteCommand`.
    static let phoneCommandReceived = Notification.Name("phoneCommandReceived")
    /// iOS-side hook: the watch streamed live vitals (HR + active energy)
    /// for a phone-owned session. PhoneWorkoutViewModel listens to overlay
    /// into the current snapshot.
    static let vitalsReceived = Notification.Name("vitalsReceived")
}
