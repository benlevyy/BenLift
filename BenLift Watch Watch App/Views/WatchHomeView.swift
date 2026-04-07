import SwiftUI

struct WatchHomeView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var receivedPlan: WatchWorkoutPlan?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Plan ready badge
                if let plan = receivedPlan {
                    Button {
                        workoutVM.startWorkout(with: plan)
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("\(plan.category.displayName) Plan Ready")
                            }
                            .font(.headline)

                            Text("\(plan.exercises.count) exercises")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(plan.category.color)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }

                // Category buttons
                ForEach(WorkoutCategory.allCases) { category in
                    categoryButton(category)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("BenLift")
        .onAppear {
            receivedPlan = WatchSyncService.shared.receivedPlan
        }
        .onReceive(NotificationCenter.default.publisher(for: .workoutPlanReceived)) { _ in
            receivedPlan = WatchSyncService.shared.receivedPlan
        }
    }

    private func categoryButton(_ category: WorkoutCategory) -> some View {
        let hasPlan = receivedPlan?.category == category

        return Button {
            if let plan = receivedPlan, plan.category == category {
                workoutVM.startWorkout(with: plan)
            } else {
                let defaults = defaultExercises(for: category)
                workoutVM.startWorkoutFromLibrary(category: category, exercises: defaults)
            }
        } label: {
            HStack {
                Text(category.displayName)
                    .font(.title3.bold())
                Spacer()
                if hasPlan {
                    Image(systemName: "sparkles")
                        .font(.caption)
                }
            }
            .padding()
            .background(category.color.opacity(0.3))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    /// Fallback exercises when no plan has been sent from iPhone
    private func defaultExercises(for category: WorkoutCategory) -> [WatchExerciseInfo] {
        let defs: [(String, Double, String)]
        switch category {
        case .push:
            defs = [
                ("Bench Press", 135, "primary compound"),
                ("DB Incline Press", 55, "secondary compound"),
                ("DB Shoulder Press", 45, "secondary compound"),
                ("Lateral Raises", 20, "isolation"),
                ("Tricep Overhead Extension", 47.5, "isolation"),
            ]
        case .pull:
            defs = [
                ("Pull-ups", 0, "primary compound"),
                ("Chest Supported Row", 55, "secondary compound"),
                ("Seated Row", 145, "secondary compound"),
                ("Face Pulls", 50, "isolation"),
                ("Incline Hammer Curl", 25, "isolation"),
            ]
        case .legs:
            defs = [
                ("Squat", 185, "primary compound"),
                ("Romanian Deadlift", 135, "secondary compound"),
                ("Split Squat", 25, "secondary compound"),
                ("Hamstring Curl", 100, "isolation"),
                ("Leg Extension", 180, "isolation"),
            ]
        }

        return defs.map { name, weight, intent in
            WatchExerciseInfo(
                name: name,
                sets: intent.contains("compound") ? 3 : 3,
                targetReps: intent.contains("compound") ? "6-8" : "10-15",
                suggestedWeight: weight,
                warmupSets: nil,
                notes: nil,
                intent: intent,
                lastWeight: nil,
                lastReps: nil
            )
        }
    }
}
