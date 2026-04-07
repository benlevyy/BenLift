import SwiftUI

struct ExerciseView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var crownReps: Double = 0

    var body: some View {
        let exercise = workoutVM.currentExercise

        ScrollView {
            VStack(spacing: 10) {
                // Exercise header
                VStack(spacing: 2) {
                    Text(exercise?.name ?? "")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if workoutVM.isWarmupPhase {
                        Text("Warm-up \(workoutVM.currentWarmupSetIndex + 1) of \(workoutVM.totalWarmupSets)")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    } else {
                        Text("Set \(workoutVM.workingSetsCompleted + 1) of \(workoutVM.targetSets)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Weight with +/- buttons (no crown)
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

                // Reps — Digital Crown + buttons
                HStack(spacing: 14) {
                    Button {
                        workoutVM.adjustReps(by: -1)
                        crownReps = workoutVM.currentReps
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                workoutVM.logFailedRep()
                                crownReps = workoutVM.currentReps
                            }
                    )

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

                // Heart rate (live)
                if workoutVM.currentHeartRate > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.caption2)
                        Text("\(Int(workoutVM.currentHeartRate))")
                            .font(.caption.bold().monospacedDigit())
                        Text("bpm")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Ghost data
                if let lastW = exercise?.lastWeight, let lastR = exercise?.lastReps {
                    Text("Last: \(Int(lastW)) × \(lastR.formattedReps)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Log Set button
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

                // Skip / Next
                HStack(spacing: 8) {
                    Button {
                        workoutVM.skipExercise()
                    } label: {
                        Text("Skip")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        workoutVM.currentScreen = .transition
                    } label: {
                        Text("Next →")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .disabled(workoutVM.workingSetsCompleted == 0)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            crownReps = workoutVM.currentReps
        }
        .onChange(of: workoutVM.currentExerciseIndex) {
            crownReps = workoutVM.currentReps
        }
    }
}
