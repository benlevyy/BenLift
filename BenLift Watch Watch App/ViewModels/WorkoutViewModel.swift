import SwiftUI
import WatchKit
import HealthKit
import Combine

/// Manages the Watch workout: exercise list hub, set logging, rest timer, HR, results.
class WorkoutViewModel: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {

    // MARK: - Plan State
    @Published var currentPlan: WatchWorkoutPlan?
    @Published var exerciseStates: [ExerciseState] = []
    @Published var activeExerciseIndex: Int? = nil // which exercise is being logged right now

    // MARK: - Heart Rate & HealthKit
    @Published var currentHeartRate: Double = 0
    @Published var averageHeartRate: Double = 0
    @Published var activeCalories: Double = 0
    private var heartRateSamples: [Double] = []
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    // MARK: - Input State
    @Published var currentWeight: Double = 0
    @Published var currentReps: Double = 0
    @Published var weightIncrement: Double = 5.0

    // MARK: - Workout State
    @Published var isWorkoutActive: Bool = false
    @Published var workoutStartDate: Date?

    // MARK: - Rest Timer
    @Published var isResting: Bool = false
    @Published var restTimerRemaining: TimeInterval = 0
    @Published var restTimerDuration: TimeInterval = 150
    /// Absolute end-time of the current rest. Source of truth for the snapshot.
    /// `restTimerRemaining` is the local watch UI's countdown derived from this.
    private var restEndsAt: Date?
    private var restTimer: Timer?

    // MARK: - Screen Navigation
    @Published var currentScreen: WatchScreen = .home

    // MARK: - Snapshot Versioning
    /// Monotonic counter that lets the phone discard out-of-order snapshots.
    private var snapshotVersion: Int = 0

    // MARK: - Exercise State Tracking

    struct ExerciseState: Identifiable {
        let id: String // exercise name
        let info: WatchExerciseInfo
        var loggedSets: [WatchSetResult] = []
        var isWarmupPhase: Bool

        var targetSets: Int { info.sets }
        var workingSetsCompleted: Int { loggedSets.filter { !$0.isWarmup }.count }
        var isComplete: Bool { workingSetsCompleted >= targetSets }
        var warmupSetsCompleted: Int { loggedSets.filter(\.isWarmup).count }
        var totalWarmups: Int { info.warmupSets?.count ?? 0 }

        var totalVolume: Double {
            loggedSets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.weight * floor($1.reps) }
        }
    }

    // MARK: - Computed

    var activeExercise: ExerciseState? {
        guard let idx = activeExerciseIndex, idx < exerciseStates.count else { return nil }
        return exerciseStates[idx]
    }

    var activeExerciseInfo: WatchExerciseInfo? {
        activeExercise?.info
    }

    /// Cable exercises use 2.5 lb pin increments; everything else uses the user's
    /// configured increment (default 5 lb plates).
    var effectiveWeightIncrement: Double {
        if let name = activeExerciseInfo?.name, name.localizedCaseInsensitiveContains("cable") {
            return 2.5
        }
        return weightIncrement
    }

    var currentSetNumber: Int {
        guard let ex = activeExercise else { return 1 }
        return ex.workingSetsCompleted + 1
    }

    var isWarmupPhase: Bool {
        activeExercise?.isWarmupPhase ?? false
    }

    var warmupSetIndex: Int {
        activeExercise?.warmupSetsCompleted ?? 0
    }

    var totalWarmupSets: Int {
        activeExercise?.totalWarmups ?? 0
    }

    var targetSets: Int {
        activeExercise?.targetSets ?? 3
    }

    var workingSetsCompleted: Int {
        activeExercise?.workingSetsCompleted ?? 0
    }

    var elapsedTime: TimeInterval {
        guard let start = workoutStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var totalVolume: Double {
        exerciseStates.reduce(0) { $0 + $1.totalVolume }
    }

    var totalSetsCompleted: Int {
        exerciseStates.reduce(0) { $0 + $1.workingSetsCompleted }
    }

    var allExercisesComplete: Bool {
        exerciseStates.allSatisfy(\.isComplete)
    }

    var incompleteCount: Int {
        exerciseStates.filter { !$0.isComplete }.count
    }

    // MARK: - Start Workout

    func startWorkout(with plan: WatchWorkoutPlan) {
        currentPlan = plan
        exerciseStates = plan.exercises.map { info in
            ExerciseState(
                id: info.name,
                info: info,
                isWarmupPhase: (info.warmupSets?.count ?? 0) > 0
            )
        }
        activeExerciseIndex = nil
        isWorkoutActive = true
        workoutStartDate = Date()
        heartRateSamples = []
        currentHeartRate = 0
        averageHeartRate = 0
        activeCalories = 0

        // Apply settings from the plan (sent by iPhone)
        if let timer = plan.restTimerDuration, timer > 0 {
            restTimerDuration = timer
        }
        if let increment = plan.weightIncrement, increment > 0 {
            weightIncrement = increment
        }
        print("[BenLift/Watch] Settings: rest=\(restTimerDuration)s, increment=\(weightIncrement)lbs")

        startHealthKitSession()
        WatchSyncService.shared.sendWorkoutStarted()
        listenForRemoteFinish()
        currentScreen = .exerciseList
        print("[BenLift/Watch] Started \(plan.sessionName ?? plan.category?.displayName ?? "Custom") workout: \(plan.exercises.count) exercises")
        // Initial snapshot — phone mirror will receive on first connect
        broadcastSnapshot()
    }

    func startWorkoutFromLibrary(category: WorkoutCategory, exercises: [WatchExerciseInfo]) {
        let plan = WatchWorkoutPlan(
            sessionName: category.displayName,
            muscleGroups: category.muscleGroups.map(\.rawValue),
            category: category,
            exercises: exercises,
            sessionStrategy: nil
        )
        startWorkout(with: plan)
    }

    // MARK: - Select Exercise (from list)

    func selectExercise(at index: Int) {
        guard index < exerciseStates.count else { return }
        activeExerciseIndex = index

        let state = exerciseStates[index]
        // Load defaults
        if state.isWarmupPhase && state.warmupSetsCompleted < state.totalWarmups {
            let warmup = state.info.warmupSets![state.warmupSetsCompleted]
            currentWeight = warmup.displayWeight
            currentReps = Double(warmup.reps)
        } else {
            currentWeight = state.info.lastWeight ?? state.info.suggestedWeight
            currentReps = 0
        }

        currentScreen = .exercise

        broadcastSnapshot()
    }

    // MARK: - Log Set

    func logSet() {
        guard let idx = activeExerciseIndex else { return }
        var state = exerciseStates[idx]

        let setResult = WatchSetResult(
            setNumber: state.loggedSets.count + 1,
            weight: currentWeight,
            reps: currentReps,
            timestamp: Date(),
            isWarmup: state.isWarmupPhase
        )
        state.loggedSets.append(setResult)

        let label = state.isWarmupPhase ? " (warmup)" : ""
        print("[BenLift/Watch] Logged: \(state.info.name) \(Int(currentWeight))x\(currentReps.formattedReps)\(label)")

        WKInterfaceDevice.current().play(.click)

        // Check warmup phase
        if state.isWarmupPhase {
            if state.warmupSetsCompleted >= state.totalWarmups {
                state.isWarmupPhase = false
                // Load working weight
                currentWeight = state.info.lastWeight ?? state.info.suggestedWeight
                currentReps = 0
            } else {
                // Next warmup
                let nextWarmup = state.info.warmupSets![state.warmupSetsCompleted]
                currentWeight = nextWarmup.displayWeight
                currentReps = Double(nextWarmup.reps)
            }
            exerciseStates[idx] = state
            // No rest timer for warmups
            broadcastSnapshot()
            return
        }

        exerciseStates[idx] = state

        // Set rest duration based on exercise intent
        if let intent = state.info.intent {
            switch intent {
            case "primary compound": restTimerDuration = 180   // 3:00
            case "secondary compound": restTimerDuration = 120 // 2:00
            case "isolation": restTimerDuration = 75            // 1:15
            case "finisher": restTimerDuration = 60             // 1:00
            default: break // keep current setting
            }
        }

        startRestTimer()
        // startRestTimer broadcasts the snapshot for us
    }

    // MARK: - Rest Timer

    func startRestTimer() {
        isResting = true
        restTimerRemaining = restTimerDuration
        restEndsAt = Date().addingTimeInterval(restTimerDuration)
        currentScreen = .restTimer

        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.restTimerRemaining -= 1

                // Buzz at 30s remaining
                if self.restTimerRemaining <= 30 && self.restTimerRemaining > 29 {
                    WKInterfaceDevice.current().play(.click)
                }
                // Buzz when timer hits 0 — but keep counting into negative
                if self.restTimerRemaining <= 0 && self.restTimerRemaining > -1 {
                    WKInterfaceDevice.current().play(.notification)
                }
                // Timer keeps running — user taps "Go" when ready
            }
        }
        broadcastSnapshot()
    }

    func skipRest() { finishRest() }

    func adjustRestTimer(by seconds: Double) {
        restTimerRemaining += seconds
        if let current = restEndsAt {
            restEndsAt = current.addingTimeInterval(seconds)
        }
        broadcastSnapshot()
    }

    private func finishRest() {
        restTimer?.invalidate()
        restTimer = nil
        isResting = false
        restTimerRemaining = 0
        restEndsAt = nil

        // If current exercise is complete (hit target sets), go back to list
        // Otherwise stay on the exercise to keep logging
        if let idx = activeExerciseIndex, exerciseStates[idx].isComplete {
            currentScreen = .exerciseList
        } else {
            currentScreen = .exercise
        }
        broadcastSnapshot()
    }

    // MARK: - Skip Warmups

    func skipWarmups() {
        guard let idx = activeExerciseIndex else { return }
        exerciseStates[idx].isWarmupPhase = false
        // Load working weight
        let state = exerciseStates[idx]
        currentWeight = state.info.lastWeight ?? state.info.suggestedWeight
        currentReps = 0
        print("[BenLift/Watch] Skipped warmups for \(state.info.name)")
        broadcastSnapshot()
    }

    // MARK: - Add Exercise Mid-Workout

    func addExercise(_ info: WatchExerciseInfo) {
        let state = ExerciseState(
            id: info.name,
            info: info,
            isWarmupPhase: false
        )
        exerciseStates.append(state)
        print("[BenLift/Watch] Added exercise mid-workout: \(info.name)")
        broadcastSnapshot()
    }

    // MARK: - Skip / Back

    func backToList() {
        activeExerciseIndex = nil
        currentScreen = .exerciseList
    }

    // MARK: - Remote Finish Listener

    private var remoteFinishCancellable: AnyCancellable?

    private func listenForRemoteFinish() {
        remoteFinishCancellable = NotificationCenter.default
            .publisher(for: .remoteFinishRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isWorkoutActive else { return }
                print("[BenLift/Watch] Remote finish requested from iPhone")
                self.finishWorkout()
                // Phone is showing the post-workout sheet — dismiss the watch UI to home.
                self.dismissSummary()
            }
    }

    // MARK: - Finish Workout

    func finishWorkout() {
        // Capture data before any state changes
        let entries = exerciseStates.enumerated().compactMap { index, state -> WatchExerciseResult? in
            guard !state.loggedSets.isEmpty else { return nil }
            return WatchExerciseResult(
                exerciseName: state.info.name,
                order: index,
                sets: state.loggedSets
            )
        }

        let duration = workoutStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let volume = exerciseStates.reduce(0.0) { $0 + $1.totalVolume }
        let category = currentPlan?.category

        let result = WatchWorkoutResult(
            date: workoutStartDate ?? Date(),
            sessionName: currentPlan?.sessionName,
            muscleGroups: currentPlan?.muscleGroups,
            category: category,
            duration: duration,
            feeling: nil,
            concerns: nil,
            entries: entries
        )

        // Stop timer first
        restTimer?.invalidate()
        restTimer = nil
        restEndsAt = nil
        isWorkoutActive = false

        // Final snapshot with isActive=false — phone mirror sees this and dismisses
        broadcastSnapshot(active: false)

        // Send result via WatchConnectivity for SwiftData persistence on phone
        WatchSyncService.shared.sendWorkoutResult(result)
        WatchSyncService.shared.sendWorkoutEnded()

        // Haptic
        WKInterfaceDevice.current().play(.success)

        print("[BenLift/Watch] Workout finished: \(entries.count) exercises, \(Int(volume))lbs, \(TimeInterval(duration).formattedDuration)")

        // End HealthKit safely
        endHealthKitSession()
    }

    func dismissSummary() {
        exerciseStates = []
        activeExerciseIndex = nil
        currentPlan = nil
        workoutStartDate = nil
        currentScreen = .home
    }

    // MARK: - Weight / Reps

    func adjustWeight(by delta: Double) {
        currentWeight = max(0, currentWeight + delta)
    }

    func adjustReps(by delta: Double) {
        currentReps = max(0, currentReps + delta)
    }

    /// Toggle failed rep: 8 → 8.5 (failed) → 8 (unfailed)
    func toggleFailedRep() {
        if currentReps.truncatingRemainder(dividingBy: 1) != 0 {
            // Already has .5 — remove it
            currentReps = floor(currentReps)
        } else {
            // Add .5 to mark failed
            currentReps += 0.5
        }
        WKInterfaceDevice.current().play(.failure)
    }

    /// Undo the last logged set for the current exercise
    func undoLastSet() {
        guard let idx = activeExerciseIndex,
              !exerciseStates[idx].loggedSets.isEmpty else { return }

        let removed = exerciseStates[idx].loggedSets.removeLast()
        // Restore weight/reps from undone set
        currentWeight = removed.weight
        currentReps = removed.reps
        // If we undid back into warmup phase
        if removed.isWarmup {
            exerciseStates[idx].isWarmupPhase = true
        }
        WKInterfaceDevice.current().play(.click)
        print("[BenLift/Watch] Undid set: \(Int(removed.weight))×\(removed.reps.formattedReps)")

        broadcastSnapshot()
    }

    func logFailedRep() {
        if currentReps >= 0.5 {
            currentReps -= 0.5
        }
        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - HealthKit Workout Session

    private func startHealthKitSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workoutBuilder = workoutSession?.associatedWorkoutBuilder()
            workoutSession?.delegate = self
            workoutBuilder?.delegate = self
            workoutBuilder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

            let startDate = Date()
            workoutSession?.startActivity(with: startDate)
            workoutBuilder?.beginCollection(withStart: startDate) { [weak self] success, error in
                if success {
                    print("[BenLift/Watch] HKWorkoutSession started — HR tracking active")
                    // Start mirroring to companion iPhone
                    self?.workoutSession?.startMirroringToCompanionDevice { mirrorSuccess, mirrorError in
                        if mirrorSuccess {
                            print("[BenLift/Watch] Mirroring started to companion device")
                        } else if let mirrorError {
                            print("[BenLift/Watch] Mirroring failed: \(mirrorError)")
                        }
                    }
                } else if let error {
                    print("[BenLift/Watch] ❌ Failed to begin collection: \(error)")
                }
            }
        } catch {
            print("[BenLift/Watch] ❌ Failed to create workout session: \(error)")
        }
    }

    private func endHealthKitSession() {
        guard let session = workoutSession, let builder = workoutBuilder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { success, _ in
            if success {
                builder.finishWorkout { workout, _ in
                    if let workout {
                        print("[BenLift/Watch] ✅ HKWorkout saved: \(workout.duration.formattedDuration)")
                    }
                }
            }
        }
        workoutSession = nil
        workoutBuilder = nil
    }

    // MARK: - Mirroring: Send Messages to iPhone

    private var lastHRSendTime: Date = .distantPast
    private var isProcessingRemote = false  // Prevents echo loops

    /// Build a fresh snapshot reflecting the current state. Called from broadcastSnapshot.
    func buildSnapshot(active: Bool? = nil) -> WorkoutSnapshot {
        snapshotVersion += 1
        let snapshotExercises = exerciseStates.map { state in
            SnapshotExercise(
                name: state.info.name,
                targetSets: state.info.sets,
                targetReps: state.info.targetReps,
                suggestedWeight: state.info.suggestedWeight,
                warmupSets: state.info.warmupSets,
                intent: state.info.intent,
                notes: state.info.notes,
                lastWeight: state.info.lastWeight,
                lastReps: state.info.lastReps,
                loggedSets: state.loggedSets,
                isWarmupPhase: state.isWarmupPhase
            )
        }
        return WorkoutSnapshot(
            version: snapshotVersion,
            isActive: active ?? isWorkoutActive,
            workoutStartDate: workoutStartDate ?? Date(),
            sessionName: currentPlan?.sessionName,
            muscleGroups: currentPlan?.muscleGroups ?? [],
            category: currentPlan?.category,
            sessionStrategy: currentPlan?.sessionStrategy,
            exercises: snapshotExercises,
            activeExerciseIndex: activeExerciseIndex,
            restEndsAt: restEndsAt,
            restDuration: restTimerDuration,
            currentHeartRate: currentHeartRate,
            activeCalories: activeCalories
        )
    }

    /// Build the latest snapshot and push it to the phone. Call this at the end of
    /// EVERY state mutation (both local actions and processed commands).
    func broadcastSnapshot(active: Bool? = nil) {
        let snapshot = buildSnapshot(active: active)
        sendMirroredMessage(.snapshot(snapshot))
    }

    func sendMirroredMessage(_ message: WorkoutMessage) {
        guard let data = message.encoded() else { return }
        workoutSession?.sendToRemoteWorkoutSession(data: data) { success, error in
            if let error {
                print("[BenLift/Watch] Mirror send error: \(error.localizedDescription)")
            }
        }
    }

    private func handleRemoteMessage(_ message: WorkoutMessage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch message {
            case .command(let cmd):
                self.processCommand(cmd)
            case .snapshot:
                // Watch is the owner — never accepts snapshots from the mirror.
                break
            }
        }
    }

    /// Process a command from the phone mirror. Each command maps to an existing
    /// local action; broadcastSnapshot at the end ensures the phone re-renders.
    private func processCommand(_ cmd: WorkoutCommand) {
        switch cmd {
        case .logSet(let idx, let weight, let reps, _):
            guard idx < exerciseStates.count else { return }
            // If the phone wants to log to a different exercise than the active one,
            // switch the active first (per Q1: phone has independent navigation, but
            // logging implicitly takes ownership of the exercise).
            if activeExerciseIndex != idx {
                selectExercise(at: idx)
            }
            currentWeight = weight
            currentReps = reps
            logSet()

        case .undoSet(let idx):
            if activeExerciseIndex != idx, idx < exerciseStates.count {
                activeExerciseIndex = idx
            }
            undoLastSet()

        case .selectExercise(let idx):
            guard idx < exerciseStates.count else { return }
            selectExercise(at: idx)

        case .skipRest:
            skipRest()

        case .adjustRestTimer(let delta):
            adjustRestTimer(by: Double(delta))

        case .adaptExercise(let idx, let replacement):
            guard idx < exerciseStates.count else { return }
            exerciseStates[idx] = ExerciseState(
                id: replacement.name,
                info: replacement,
                isWarmupPhase: (replacement.warmupSets?.count ?? 0) > 0
            )
            print("[BenLift/Watch] Exercise \(idx) replaced with \(replacement.name) via phone")
            broadcastSnapshot()

        case .addExercise(let info):
            addExercise(info)
            broadcastSnapshot()

        case .end:
            print("[BenLift/Watch] ← phone requested .end")
            finishWorkout()
            // User ended on phone — they're already seeing the post-workout sheet there.
            // Skip the watch's local Summary screen and return straight to home.
            dismissSummary()

        case .requestSnapshot:
            print("[BenLift/Watch] ← phone requested snapshot")
            broadcastSnapshot()
        }
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        print("[BenLift/Watch] Workout session: \(fromState.rawValue) → \(toState.rawValue)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[BenLift/Watch] ❌ Workout session error: \(error)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        print("[BenLift/Watch] ← Mirrored data received: \(data.count) packet(s)")
        for datum in data {
            if let message = WorkoutMessage.decode(from: datum) {
                handleRemoteMessage(message)
            } else {
                print("[BenLift/Watch] ⚠️ Failed to decode mirrored packet (\(datum.count) bytes)")
            }
        }
    }

    // MARK: - HKLiveWorkoutBuilderDelegate

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else { continue }

            if quantityType == HKQuantityType.quantityType(forIdentifier: .heartRate) {
                let stats = workoutBuilder.statistics(for: quantityType)
                let unit = HKUnit.count().unitDivided(by: .minute())
                if let hr = stats?.mostRecentQuantity()?.doubleValue(for: unit) {
                    DispatchQueue.main.async {
                        self.currentHeartRate = hr
                        self.heartRateSamples.append(hr)
                        self.averageHeartRate = self.heartRateSamples.reduce(0, +) / Double(self.heartRateSamples.count)

                        // Throttle HR snapshot broadcasts to every 5 seconds
                        if Date().timeIntervalSince(self.lastHRSendTime) >= 5 {
                            self.lastHRSendTime = Date()
                            self.broadcastSnapshot()
                        }
                    }
                }
            }

            if quantityType == HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                let stats = workoutBuilder.statistics(for: quantityType)
                if let cal = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                    DispatchQueue.main.async { self.activeCalories = cal }
                }
            }
        }
    }
}

// MARK: - Watch Screen

enum WatchScreen: Equatable {
    case home
    case exerciseList  // the hub — pick any exercise
    case exercise      // logging sets for a specific exercise
    case restTimer
    case summary
}
