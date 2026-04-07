import SwiftUI

struct WorkoutSummaryView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var hasEnded = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 12) {
            if isSaving {
                // Saving state
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                Text("Saving...")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top, 8)
                Spacer()

            } else if hasEnded {
                // Done state
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)

                Text("Saved!")
                    .font(.title3.bold())
                    .foregroundColor(.white)

                statsSection

                Text("Sent to iPhone")
                    .font(.caption2)
                    .foregroundColor(.gray)

                Button {
                    workoutVM.dismissSummary()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                Spacer()

            } else {
                // Pre-end state
                Text("Finish?")
                    .font(.title3.bold())
                    .foregroundColor(.white)

                statsSection

                Button {
                    isSaving = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        workoutVM.finishWorkout()
                        isSaving = false
                        hasEnded = true
                    }
                } label: {
                    Text("End Workout")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    workoutVM.currentScreen = .exerciseList
                } label: {
                    Text("Go Back")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 8)
    }

    private var statsSection: some View {
        VStack(spacing: 6) {
            let exerciseCount = workoutVM.exerciseStates.filter { !$0.loggedSets.isEmpty }.count
            statRow("Exercises", "\(exerciseCount)")
            statRow("Sets", "\(workoutVM.totalSetsCompleted)")
            statRow("Volume", "\(Int(workoutVM.totalVolume)) lbs")
            statRow("Duration", workoutVM.elapsedTime.formattedDuration)

            if workoutVM.averageHeartRate > 0 {
                statRow("Avg HR", "\(Int(workoutVM.averageHeartRate)) bpm")
            }
            if workoutVM.activeCalories > 0 {
                statRow("Calories", "\(Int(workoutVM.activeCalories)) cal")
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.1))
        .cornerRadius(10)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundColor(.white)
        }
    }
}
