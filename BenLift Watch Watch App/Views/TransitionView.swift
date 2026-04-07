import SwiftUI

struct TransitionView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    var body: some View {
        let nextIndex = workoutVM.currentExerciseIndex + 1
        let hasNext = nextIndex < workoutVM.totalExercises
        let nextExercise = hasNext ? workoutVM.currentPlan?.exercises[nextIndex] : nil
        // Also check one after next for the skip button
        let hasMoreAfterNext = (nextIndex + 1) < workoutVM.totalExercises

        ScrollView {
            VStack(spacing: 14) {
                // Current exercise summary
                if let current = workoutVM.currentExercise {
                    VStack(spacing: 2) {
                        Text(current.name)
                            .font(.caption.bold())
                        Text("\(workoutVM.workingSetsCompleted) sets done")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                if let next = nextExercise {
                    Text("Up Next")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(next.name)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text("\(next.sets) × \(next.targetReps) @ \(Int(next.suggestedWeight))lbs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("All exercises done!")
                        .font(.headline)
                }

                // Action buttons
                VStack(spacing: 8) {
                    Button {
                        workoutVM.nextExercise()
                    } label: {
                        Text(hasNext ? "Continue" : "Finish")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 8) {
                        Button {
                            workoutVM.addExtraSet()
                        } label: {
                            Text("+Set")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)

                        if hasNext && hasMoreAfterNext {
                            Button {
                                // Save current, skip the next exercise entirely
                                workoutVM.nextExercise() // saves current, moves to next
                                workoutVM.skipExercise()  // immediately skips that next one
                            } label: {
                                Text("Skip Next")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            workoutVM.currentScreen = .summary
                        } label: {
                            Text("End")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
    }
}
