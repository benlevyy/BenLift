import SwiftUI

struct ExerciseView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var crownReps: Double = 0

    var body: some View {
        let exercise = workoutVM.activeExerciseInfo

        ScrollView {
            VStack(spacing: 10) {
                // Exercise header
                VStack(spacing: 2) {
                    Text(exercise?.name ?? "")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if workoutVM.isWarmupPhase {
                        Text("Warm-up \(workoutVM.warmupSetIndex + 1) of \(workoutVM.totalWarmupSets)")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    } else {
                        Text("Set \(workoutVM.workingSetsCompleted + 1) of \(workoutVM.targetSets)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Weight with +/- buttons
                HStack(spacing: 12) {
                    Button {
                        workoutVM.adjustWeight(by: -workoutVM.weightIncrement)
                    } label: {
                        Image(systemName: "minus")
                            .font(.body.bold())
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 0) {
                        Text("\(Int(workoutVM.currentWeight))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("lbs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        workoutVM.adjustWeight(by: workoutVM.weightIncrement)
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Reps — Digital Crown + buttons + [F] for failed
                HStack(spacing: 10) {
                    Button {
                        workoutVM.adjustReps(by: -1)
                        crownReps = workoutVM.currentReps
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Text(workoutVM.currentReps.formattedReps)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0 ? .red : .primary)

                    Button {
                        workoutVM.adjustReps(by: 1)
                        crownReps = workoutVM.currentReps
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    // Failed rep toggle
                    Button {
                        workoutVM.toggleFailedRep()
                        crownReps = workoutVM.currentReps
                    } label: {
                        Text("F")
                            .font(.caption.bold())
                            .foregroundColor(workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0 ? .white : .red)
                            .frame(width: 26, height: 26)
                            .background(workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0 ? Color.red : Color.red.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .focusable()
                .digitalCrownRotation(
                    $crownReps,
                    from: 0,
                    through: 30,
                    by: 1,
                    sensitivity: .low
                )
                .onChange(of: crownReps) { _, newValue in
                    workoutVM.currentReps = max(0, newValue)
                }

                // Heart rate
                if workoutVM.currentHeartRate > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.caption2)
                        Text("\(Int(workoutVM.currentHeartRate)) bpm")
                            .font(.caption.monospacedDigit())
                    }
                }

                // Ghost data
                if let lastW = exercise?.lastWeight, let lastR = exercise?.lastReps {
                    Text("Last: \(Int(lastW)) × \(lastR.formattedReps)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Log Set
                Button {
                    workoutVM.logSet()
                } label: {
                    Text("Log Set")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(workoutVM.currentReps <= 0 && !workoutVM.isWarmupPhase)

                // Undo / Skip Warmup / Back
                HStack(spacing: 6) {
                    // Undo last set
                    if let ex = workoutVM.activeExercise, !ex.loggedSets.isEmpty {
                        Button {
                            workoutVM.undoLastSet()
                            crownReps = workoutVM.currentReps
                        } label: {
                            Text("Undo")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Skip warmups
                    if workoutVM.isWarmupPhase {
                        Button {
                            workoutVM.skipWarmups()
                        } label: {
                            Text("Skip W")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        workoutVM.backToList()
                    } label: {
                        Text("← Back")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            crownReps = workoutVM.currentReps
        }
    }
}
