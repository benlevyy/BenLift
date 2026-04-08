import SwiftUI

/// The workout hub — shows all exercises, tap any to log sets.
struct ExerciseListHubView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Elapsed time + HR
                HStack {
                    Text(workoutVM.elapsedTime.formattedMinSec)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)

                    Spacer()

                    if workoutVM.currentHeartRate > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text("\(Int(workoutVM.currentHeartRate))")
                                .font(.caption.bold().monospacedDigit())
                        }
                    }

                    Spacer()

                    Text("\(Int(workoutVM.totalVolume)) lbs")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)

                // Exercise rows — incomplete first, then completed
                let incomplete = workoutVM.exerciseStates.enumerated().filter { !$0.element.isComplete }
                let complete = workoutVM.exerciseStates.enumerated().filter { $0.element.isComplete }

                ForEach(incomplete, id: \.element.id) { index, state in
                    exerciseButton(state: state, index: index)
                }

                if !complete.isEmpty {
                    HStack {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                        Text("Done").font(.caption2).foregroundColor(.secondary)
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    ForEach(complete, id: \.element.id) { index, state in
                        exerciseButton(state: state, index: index)
                    }
                }

                // Add exercise
                Button {
                    showAddExercise = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                        Text("Add Exercise")
                            .font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                // Finish button
                Button {
                    workoutVM.currentScreen = .summary
                } label: {
                    Text("Finish Workout")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(workoutVM.currentPlan?.sessionName ?? workoutVM.currentPlan?.category?.displayName ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddExercise) {
            WatchAddExerciseView(workoutVM: workoutVM)
        }
    }

    @State private var showAddExercise = false

    private func exerciseButton(state: WorkoutViewModel.ExerciseState, index: Int) -> some View {
        Button {
            workoutVM.selectExercise(at: index)
        } label: {
            HStack(spacing: 8) {
                // Status indicator
                if state.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.body)
                } else if state.workingSetsCompleted > 0 {
                    // Partial — show fraction
                    Text("\(state.workingSetsCompleted)/\(state.targetSets)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundColor(.blue)
                        .frame(width: 28)
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.info.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundColor(state.isComplete ? .secondary : .primary)

                    Text("\(state.targetSets)×\(state.info.targetReps) @ \(Int(state.info.suggestedWeight))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(state.isComplete ? Color.clear : Color.gray.opacity(0.12))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
