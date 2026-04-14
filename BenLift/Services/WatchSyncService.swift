import Foundation
import WatchConnectivity

/// Shared WatchConnectivity service — add to BOTH iOS and watchOS targets.
/// On iOS: sends workout plans to Watch, receives results back.
/// On watchOS: receives plans, sends results back.
class WatchSyncService: NSObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isWorkoutActive = false  // Set by Watch via message when workout starts/ends

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
            self.isReachable = session.isReachable
            print("[BenLift/Sync] Reachability changed: \(session.isReachable)")
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
                    print("[BenLift/Sync] ← Watch workout ended")
                }
            default:
                print("[BenLift/Sync] Unknown message type: \(type)")
            }
        }
    }

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
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workoutPlanReceived = Notification.Name("workoutPlanReceived")
    static let workoutResultReceived = Notification.Name("workoutResultReceived")
}
