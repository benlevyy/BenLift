import Foundation
import SwiftData
import Combine

/// App-level manager that persists Watch workout results to SwiftData
/// immediately when received, regardless of which view is active.
/// Lives for the app's lifetime — initialized in BenLiftApp.
class WorkoutSyncManager {
    private let container: ModelContainer
    private var cancellable: AnyCancellable?

    init(container: ModelContainer) {
        self.container = container

        // Listen for workout results from WatchSyncService
        cancellable = NotificationCenter.default
            .publisher(for: .workoutResultReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.processReceivedResult()
            }

        // Check for any pending result that arrived before we started listening
        // (e.g. transferUserInfo delivered during app launch before this init)
        DispatchQueue.main.async { [weak self] in
            self?.processReceivedResult()
        }

        print("[BenLift/SyncManager] Initialized — listening for workout results")
    }

    private func processReceivedResult() {
        guard let result = WatchSyncService.shared.receivedWorkoutResult else { return }

        // Clear immediately to avoid double-processing
        WatchSyncService.shared.receivedWorkoutResult = nil

        let context = ModelContext(container)
        persistWorkout(result, in: context)
    }

    private func persistWorkout(_ result: WatchWorkoutResult, in context: ModelContext) {
        // Don't save empty workouts (user ended without logging anything)
        let nonEmptyEntries = result.entries.filter { !$0.sets.isEmpty }
        if nonEmptyEntries.isEmpty {
            print("[BenLift/SyncManager] Empty workout result (no sets logged), skipping")
            return
        }

        // Check for duplicate — don't save if a session with the same date already exists
        let resultDate = result.date
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { session in
                session.date == resultDate
            }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            print("[BenLift/SyncManager] Duplicate workout result (same date), skipping")
            return
        }

        let muscleGroups = (result.muscleGroups ?? []).compactMap { MuscleGroup(rawValue: $0) }
        let session = WorkoutSession(
            date: result.date,
            category: result.category,
            sessionName: result.sessionName,
            muscleGroups: muscleGroups,
            duration: result.duration,
            feeling: result.feeling,
            concerns: result.concerns,
            aiPlanUsed: false
        )

        for entry in result.entries {
            let exerciseEntry = ExerciseEntry(
                exerciseName: entry.exerciseName,
                order: entry.order
            )
            for set in entry.sets {
                let setLog = SetLog(
                    setNumber: set.setNumber,
                    weight: set.weight,
                    reps: set.reps,
                    timestamp: set.timestamp,
                    isWarmup: set.isWarmup
                )
                exerciseEntry.sets.append(setLog)
            }
            session.entries.append(exerciseEntry)
        }

        context.insert(session)
        do {
            try context.save()
            print("[BenLift/SyncManager] Saved workout: \(result.entries.count) exercises, \(session.displayName)")

            // Safety net — make sure any active Live Activity ends
            DispatchQueue.main.async {
                LiveActivityManager.shared.endAnyActivity()
            }

            // Notify views that a session was saved
            NotificationCenter.default.post(
                name: .workoutSessionSaved,
                object: session.id
            )
        } catch {
            print("[BenLift/SyncManager] Failed to save: \(error)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workoutSessionSaved = Notification.Name("workoutSessionSaved")
}
