import SwiftUI

struct WorkoutSummaryView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var hasEnded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !hasEnded {
                    // Pre-end: show stats and End button
                    Text("Workout Complete")
                        .font(.headline)

                    statsSection

                    Button {
                        _ = workoutVM.finishWorkout()
                        hasEnded = true
                    } label: {
                        Text("End Workout")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    // Post-end: show final stats and Done
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)

                    Text("Saved!")
                        .font(.headline)

                    statsSection

                    Text("Results sent to iPhone")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        workoutVM.dismissSummary()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
        }
    }

    private var statsSection: some View {
        VStack(spacing: 8) {
            let exerciseCount = workoutVM.completedEntries.count + (workoutVM.currentSets.isEmpty ? 0 : 1)
            statRow("Exercises", value: "\(exerciseCount)")
            statRow("Sets", value: "\(workoutVM.totalSetsCompleted)")
            statRow("Volume", value: "\(Int(workoutVM.totalVolume)) lbs")
            statRow("Duration", value: workoutVM.elapsedTime.formattedDuration)

            if workoutVM.averageHeartRate > 0 {
                statRow("Avg HR", value: "\(Int(workoutVM.averageHeartRate)) bpm")
            }
            if workoutVM.activeCalories > 0 {
                statRow("Calories", value: "\(Int(workoutVM.activeCalories)) cal")
            }
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body.bold().monospacedDigit())
        }
    }
}
