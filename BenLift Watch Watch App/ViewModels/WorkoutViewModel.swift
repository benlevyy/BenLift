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
    private var restTimer: Timer?

    // MARK: - Screen Navigation
    @Published var currentScreen: WatchScreen = .home

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
        currentScreen = .exerciseList
        print("[BenLift/Watch] Started \(plan.category.displayName) workout: \(plan.exercises.count) exercises")
    }

    func startWorkoutFromLibrary(category: WorkoutCategory, exercises: [WatchExerciseInfo]) {
        let plan = WatchWorkoutPlan(category: category, exercises: exercises, sessionStrategy: nil)
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
            currentWeight = warmup.weight
            currentReps = Double(warmup.reps)
        } else {
            currentWeight = state.info.lastWeight ?? state.info.suggestedWeight
            currentReps = 0
        }

        currentScreen = .exercise
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
                currentWeight = nextWarmup.weight
                currentReps = Double(nextWarmup.reps)
            }
            exerciseStates[idx] = state
            // No rest timer for warmups
            return
        }

        exerciseStates[idx] = state

        // Start rest timer, then return to exercise list
        startRestTimer()
    }

    // MARK: - Rest Timer

    func startRestTimer() {
        isResting = true
        restTimerRemaining = restTimerDuration
        currentScreen = .restTimer

        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.restTimerRemaining -= 1
                if self.restTimerRemaining <= 30 && self.restTimerRemaining > 29 {
                    WKInterfaceDevice.current().play(.click)
                }
                if self.restTimerRemaining <= 0 {
                    self.finishRest()
                    WKInterfaceDevice.current().play(.notification)
                }
            }
        }
    }

    func skipRest() { finishRest() }

    private func finishRest() {
        restTimer?.invalidate()
        restTimer = nil
        isResting = false
        restTimerRemaining = 0

        // If current exercise is complete (hit target sets), go back to list
        // Otherwise stay on the exercise to keep logging
        if let idx = activeExerciseIndex, exerciseStates[idx].isComplete {
            currentScreen = .exerciseList
        } else {
            currentScreen = .exercise
        }
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
    }

    // MARK: - Skip / Back

    func backToList() {
        activeExerciseIndex = nil
        currentScreen = .exerciseList
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
        let category = currentPlan?.category ?? .push

        let result = WatchWorkoutResult(
            date: workoutStartDate ?? Date(),
            category: category,
            duration: duration,
            feeling: nil,
            concerns: nil,
            entries: entries
        )

        // Stop timer first
        restTimer?.invalidate()
        restTimer = nil
        isWorkoutActive = false

        // Send result
        WatchSyncService.shared.sendWorkoutResult(result)

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
            workoutBuilder?.beginCollection(withStart: startDate) { success, error in
                if success {
                    print("[BenLift/Watch] HKWorkoutSession started — HR tracking active")
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

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        print("[BenLift/Watch] Workout session: \(fromState.rawValue) → \(toState.rawValue)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[BenLift/Watch] ❌ Workout session error: \(error)")
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
