import SwiftUI
import WatchKit
import HealthKit
import Combine

/// The brain of the Watch workout flow.
/// Manages exercise progression, set logging, rest timer, heart rate, and results.
class WorkoutViewModel: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    // MARK: - Plan State
    @Published var currentPlan: WatchWorkoutPlan?
    @Published var currentExerciseIndex: Int = 0
    @Published var currentSetNumber: Int = 1
    @Published var isWarmupPhase: Bool = false

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
    @Published var completedEntries: [WatchExerciseResult] = []
    @Published var currentSets: [WatchSetResult] = []

    // MARK: - Rest Timer
    @Published var isResting: Bool = false
    @Published var restTimerRemaining: TimeInterval = 0
    @Published var restTimerDuration: TimeInterval = 150 // 2:30 default
    private var restTimer: Timer?

    // MARK: - Screen Navigation
    @Published var currentScreen: WatchScreen = .home

    // MARK: - Computed Properties

    var currentExercise: WatchExerciseInfo? {
        guard let plan = currentPlan,
              currentExerciseIndex < plan.exercises.count else { return nil }
        return plan.exercises[currentExerciseIndex]
    }

    var totalExercises: Int {
        currentPlan?.exercises.count ?? 0
    }

    var warmupSetsForCurrentExercise: [WarmupSet] {
        currentExercise?.warmupSets ?? []
    }

    var totalWarmupSets: Int {
        warmupSetsForCurrentExercise.count
    }

    var currentWarmupSetIndex: Int {
        // Count warmup sets already logged
        currentSets.filter(\.isWarmup).count
    }

    var targetSets: Int {
        currentExercise?.sets ?? 3
    }

    var workingSetsCompleted: Int {
        currentSets.filter { !$0.isWarmup }.count
    }

    var elapsedTime: TimeInterval {
        guard let start = workoutStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var totalVolume: Double {
        var volume = 0.0
        for entry in completedEntries {
            for set in entry.sets where !set.isWarmup {
                volume += set.weight * floor(set.reps)
            }
        }
        // Add current exercise sets
        for set in currentSets where !set.isWarmup {
            volume += set.weight * floor(set.reps)
        }
        return volume
    }

    var totalSetsCompleted: Int {
        let previous = completedEntries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
        return previous + workingSetsCompleted
    }

    // MARK: - Start Workout

    func startWorkout(with plan: WatchWorkoutPlan) {
        currentPlan = plan
        currentExerciseIndex = 0
        currentSetNumber = 1
        completedEntries = []
        currentSets = []
        isWorkoutActive = true
        workoutStartDate = Date()
        heartRateSamples = []
        currentHeartRate = 0
        averageHeartRate = 0
        activeCalories = 0

        loadExerciseDefaults()

        // Start with warmups if available
        isWarmupPhase = totalWarmupSets > 0

        // Start HKWorkoutSession for HR tracking + Activity Ring contribution
        startHealthKitSession()

        currentScreen = .exercise
        print("[BenLift/Watch] Started \(plan.category.displayName) workout: \(plan.exercises.count) exercises")
    }

    func startWorkoutFromLibrary(category: WorkoutCategory, exercises: [WatchExerciseInfo]) {
        let plan = WatchWorkoutPlan(category: category, exercises: exercises, sessionStrategy: nil)
        startWorkout(with: plan)
    }

    // MARK: - Load Exercise Defaults

    private func loadExerciseDefaults() {
        guard let exercise = currentExercise else { return }

        if isWarmupPhase && currentWarmupSetIndex < totalWarmupSets {
            let warmup = warmupSetsForCurrentExercise[currentWarmupSetIndex]
            currentWeight = warmup.weight
            currentReps = Double(warmup.reps)
        } else {
            // Use last set's weight or suggested weight
            if let lastWeight = exercise.lastWeight {
                currentWeight = lastWeight
            } else {
                currentWeight = exercise.suggestedWeight
            }
            currentReps = 0 // User enters reps
        }
    }

    // MARK: - Log Set

    func logSet() {
        guard currentExercise != nil else { return }

        let set = WatchSetResult(
            setNumber: currentSetNumber,
            weight: currentWeight,
            reps: currentReps,
            timestamp: Date(),
            isWarmup: isWarmupPhase
        )
        currentSets.append(set)

        let warmupLabel = isWarmupPhase ? " (warmup)" : ""
        print("[BenLift/Watch] Logged set \(currentSetNumber): \(Int(currentWeight))x\(currentReps.formattedReps)\(warmupLabel)")

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)

        // Advance state
        if isWarmupPhase {
            if currentWarmupSetIndex >= totalWarmupSets {
                // Done with warmups, switch to working sets
                isWarmupPhase = false
                currentSetNumber = 1
                loadExerciseDefaults()
            } else {
                currentSetNumber += 1
                loadExerciseDefaults()
            }
            // Short rest for warmups — go straight back, no timer
            return
        }

        currentSetNumber += 1

        // Start rest timer
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

    func skipRest() {
        finishRest()
    }

    private func finishRest() {
        restTimer?.invalidate()
        restTimer = nil
        isResting = false
        restTimerRemaining = 0

        // Check if we've completed target sets
        if workingSetsCompleted >= targetSets {
            currentScreen = .transition
        } else {
            currentScreen = .exercise
        }
    }

    // MARK: - Exercise Navigation

    func nextExercise() {
        // Save current exercise
        if let exercise = currentExercise {
            let entry = WatchExerciseResult(
                exerciseName: exercise.name,
                order: currentExerciseIndex,
                sets: currentSets
            )
            completedEntries.append(entry)
        }

        currentSets = []
        currentExerciseIndex += 1
        currentSetNumber = 1

        if currentExerciseIndex >= totalExercises {
            currentScreen = .summary
        } else {
            isWarmupPhase = totalWarmupSets > 0
            loadExerciseDefaults()
            currentScreen = .exercise
        }
    }

    func skipExercise() {
        nextExercise()
    }

    func addExtraSet() {
        // Go back to exercise screen to log another set
        currentScreen = .exercise
    }

    // MARK: - Finish Workout

    func finishWorkout() -> WatchWorkoutResult {
        // Save any in-progress exercise
        if let exercise = currentExercise, !currentSets.isEmpty {
            let entry = WatchExerciseResult(
                exerciseName: exercise.name,
                order: currentExerciseIndex,
                sets: currentSets
            )
            completedEntries.append(entry)
        }

        let duration = elapsedTime
        let result = WatchWorkoutResult(
            date: workoutStartDate ?? Date(),
            category: currentPlan?.category ?? .push,
            duration: duration,
            feeling: nil,
            concerns: nil,
            entries: completedEntries
        )

        // Send result to iPhone
        WatchSyncService.shared.sendWorkoutResult(result)

        // Haptic confirmation
        WKInterfaceDevice.current().play(.success)

        print("[BenLift/Watch] Workout finished: \(completedEntries.count) exercises, \(Int(totalVolume))lbs volume, \(TimeInterval(duration).formattedDuration)")

        // End HealthKit session
        endHealthKitSession()

        // Clean up timer but stay on summary — don't go home yet
        isWorkoutActive = false
        restTimer?.invalidate()
        // currentScreen stays on .summary — user calls dismissSummary() to go home

        return result
    }

    /// Called when user taps "Done" on the summary screen
    func dismissSummary() {
        completedEntries = []
        currentSets = []
        currentPlan = nil
        currentExerciseIndex = 0
        currentSetNumber = 1
        currentScreen = .home
    }

    // MARK: - Weight Adjustment (Digital Crown)

    func adjustWeight(by delta: Double) {
        currentWeight = max(0, currentWeight + delta)
    }

    func adjustReps(by delta: Double) {
        currentReps = max(0, currentReps + delta)
    }

    func logFailedRep() {
        // Subtract 0.5 to mark a failed rep
        if currentReps >= 0.5 {
            currentReps -= 0.5
        }
        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - HealthKit Workout Session

    private func startHealthKitSession() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[BenLift/Watch] HealthKit not available")
            return
        }

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
        builder.endCollection(withEnd: Date()) { success, error in
            if success {
                builder.finishWorkout { workout, error in
                    if let workout {
                        print("[BenLift/Watch] ✅ HKWorkout saved: \(workout.duration.formattedDuration), \(Int(workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0)) cal")
                    } else if let error {
                        print("[BenLift/Watch] ❌ Failed to finish workout: \(error)")
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

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Workout events collected
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else { continue }

            if quantityType == HKQuantityType.quantityType(forIdentifier: .heartRate) {
                let stats = workoutBuilder.statistics(for: quantityType)
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

                if let mostRecent = stats?.mostRecentQuantity()?.doubleValue(for: heartRateUnit) {
                    DispatchQueue.main.async {
                        self.currentHeartRate = mostRecent
                        self.heartRateSamples.append(mostRecent)
                        self.averageHeartRate = self.heartRateSamples.reduce(0, +) / Double(self.heartRateSamples.count)
                    }
                }
            }

            if quantityType == HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                let stats = workoutBuilder.statistics(for: quantityType)
                if let total = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                    DispatchQueue.main.async {
                        self.activeCalories = total
                    }
                }
            }
        }
    }
}

// MARK: - Watch Screen Enum

enum WatchScreen: Equatable {
    case home
    case exercise
    case restTimer
    case transition
    case summary
}
