import Foundation
import HealthKit

/// iPhone-side receiver for HKWorkoutSession mirroring from Watch.
/// Initialized at app launch to be ready when Watch starts mirroring.
@Observable
class WorkoutMirroringService: NSObject, HKWorkoutSessionDelegate {
    static let shared = WorkoutMirroringService()

    let healthStore = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?

    // Published state
    var isMirroredWorkoutActive = false
    var latestHeartRate: Double = 0
    var latestCalories: Double = 0

    // Callback for received messages
    var onMessageReceived: ((WorkoutMessage) -> Void)?

    // Callback when a mirrored workout starts (for auto-presenting UI)
    var onMirroredWorkoutStarted: ((_ plan: WatchWorkoutPlan?) -> Void)?

    override init() {
        super.init()
    }

    /// Call early in app lifecycle (BenLiftApp.init) to register the mirroring handler.
    func setup() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[BenLift/Mirroring] HealthKit not available")
            return
        }

        healthStore.workoutSessionMirroringStartHandler = { [weak self] mirroredSession in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleMirroredSessionStart(mirroredSession)
            }
        }

        print("[BenLift/Mirroring] Setup complete — listening for mirrored sessions")
    }

    private func handleMirroredSessionStart(_ session: HKWorkoutSession) {
        print("[BenLift/Mirroring] Mirrored session received from Watch")
        mirroredSession = session
        session.delegate = self
        isMirroredWorkoutActive = true

        // Notify that a mirrored workout started
        onMirroredWorkoutStarted?(nil)
    }

    // Debounce: drop identical commands sent within 250ms of each other.
    // Prevents the "user mashes Skip Rest because UI didn't update" command flood.
    private var lastSentSignature: String?
    private var lastSentAt: Date = .distantPast
    private let debounceWindow: TimeInterval = 0.25

    /// Send a message to the Watch via the mirrored session. Returns `true`
    /// when the send was *attempted* (there is an active mirrored session and
    /// the payload wasn't deduped). Callers use this signal to decide whether
    /// an optimistic UI hint (e.g. a pending set) is worth appending — false
    /// means the watch will never see it and we'd be lying to the user.
    @discardableResult
    func sendToWatch(_ message: WorkoutMessage) -> Bool {
        guard let session = mirroredSession, let data = message.encoded() else {
            print("[BenLift/Mirroring] ⚠️ Cannot send \(message) — no active mirrored session")
            return false
        }

        // Debounce duplicates (only for commands; snapshots are owner-only).
        // Uses a structured signature that explicitly names the case + key args
        // so commands that differ only in payload (e.g. skip on different
        // indices) are NOT dedupe'd together. Previously this used
        // `"\(message)"` which relied on Swift's enum stringification being
        // stable and payload-inclusive — not guaranteed across toolchains.
        if case .command(let cmd) = message {
            let signature = Self.debounceSignature(for: cmd)
            if signature == lastSentSignature,
               Date().timeIntervalSince(lastSentAt) < debounceWindow {
                return false
            }
            lastSentSignature = signature
            lastSentAt = Date()
        }

        session.sendToRemoteWorkoutSession(data: data) { success, error in
            if let error {
                print("[BenLift/Mirroring] ❌ Send error for \(message): \(error)")
            } else {
                print("[BenLift/Mirroring] → Sent \(message) to Watch (\(data.count) bytes)")
            }
        }
        return true
    }

    /// Explicit per-case signature. Each command carries whatever identifying
    /// payload matters (index, weight, etc.) so two distinct user actions can
    /// never accidentally share a signature and get deduped into one.
    private static func debounceSignature(for cmd: WorkoutCommand) -> String {
        switch cmd {
        case .logSet(let i, let w, let r, let isWarmup):
            return "logSet:\(i):\(w):\(r):\(isWarmup)"
        case .undoSet(let i):
            return "undoSet:\(i)"
        case .selectExercise(let i):
            return "selectExercise:\(i)"
        case .skipRest:
            return "skipRest"
        case .adjustRestTimer(let delta):
            return "adjustRestTimer:\(delta)"
        case .adaptExercise(let i, let replacement):
            return "adaptExercise:\(i):\(replacement.name)"
        case .addExercise(let info):
            return "addExercise:\(info.name)"
        case .end(let effort):
            return "end:\(effort.map { String($0) } ?? "nil")"
        case .requestSnapshot:
            return "requestSnapshot"
        case .skipExercise(let i):
            return "skipExercise:\(i)"
        case .unskipExercise(let i):
            return "unskipExercise:\(i)"
        }
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didChangeTo toState: HKWorkoutSessionState,
                       from fromState: HKWorkoutSessionState,
                       date: Date) {
        print("[BenLift/Mirroring] Session state: \(fromState.rawValue) -> \(toState.rawValue)")

        if toState == .ended {
            DispatchQueue.main.async {
                self.isMirroredWorkoutActive = false
                self.mirroredSession = nil
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[BenLift/Mirroring] Session error: \(error)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        for datum in data {
            if let message = WorkoutMessage.decode(from: datum) {
                DispatchQueue.main.async {
                    self.handleReceivedMessage(message)
                }
            }
        }
    }

    private func handleReceivedMessage(_ message: WorkoutMessage) {
        // Capture HR from the latest snapshot for any UI that reads it directly.
        if case .snapshot(let snap) = message {
            latestHeartRate = snap.currentHeartRate
            latestCalories = snap.activeCalories
            print("[BenLift/Mirroring] ← Snapshot v\(snap.version) (active=\(snap.isActive), exercises=\(snap.exercises.count), restEndsAt=\(snap.restEndsAt?.description ?? "nil"))")
        }
        // Forward to PhoneWorkoutViewModel
        onMessageReceived?(message)
    }
}
