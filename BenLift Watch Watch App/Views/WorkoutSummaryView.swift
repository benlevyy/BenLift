import SwiftUI

struct WorkoutSummaryView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var hasEnded = false
    @State private var isSaving = false

    // Capture stats before finishWorkout clears anything
    @State private var savedExerciseCount = 0
    @State private var savedSetCount = 0
    @State private var savedVolume = 0.0
    @State private var savedDuration: TimeInterval = 0
    @State private var savedAvgHR = 0.0
    @State private var savedCalories = 0.0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .padding(.top, 30)
                    Text("Saving...")
                        .font(.headline)
                        .foregroundColor(.white)

                } else if hasEnded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                        .padding(.top, 8)

                    Text("Saved!")
                        .font(.title3.bold())
                        .foregroundColor(.white)

                    savedStatsSection

                    Text("Sent to iPhone")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.top, 2)

                    Button {
                        workoutVM.dismissSummary()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)

                } else {
                    Text("Finish?")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .padding(.top, 8)

                    liveStatsSection

                    Button {
                        // Capture stats NOW before finishWorkout
                        savedExerciseCount = workoutVM.exerciseStates.filter { !$0.loggedSets.isEmpty }.count
                        savedSetCount = workoutVM.totalSetsCompleted
                        savedVolume = workoutVM.totalVolume
                        savedDuration = workoutVM.elapsedTime
                        savedAvgHR = workoutVM.averageHeartRate
                        savedCalories = workoutVM.activeCalories

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
    }

    // Stats from live ViewModel (before ending)
    private var liveStatsSection: some View {
        VStack(spacing: 4) {
            let count = workoutVM.exerciseStates.filter { !$0.loggedSets.isEmpty }.count
            statRow("Exercises", "\(count)")
            statRow("Sets", "\(workoutVM.totalSetsCompleted)")
            statRow("Volume", "\(Int(workoutVM.totalVolume)) lbs")
            statRow("Duration", workoutVM.elapsedTime.formattedDuration)
            if workoutVM.averageHeartRate > 0 {
                statRow("Avg HR", "\(Int(workoutVM.averageHeartRate)) bpm")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
    }

    // Stats from captured values (after ending)
    private var savedStatsSection: some View {
        VStack(spacing: 4) {
            statRow("Exercises", "\(savedExerciseCount)")
            statRow("Sets", "\(savedSetCount)")
            statRow("Volume", "\(Int(savedVolume)) lbs")
            statRow("Duration", TimeInterval(savedDuration).formattedDuration)
            if savedAvgHR > 0 {
                statRow("Avg HR", "\(Int(savedAvgHR)) bpm")
            }
            if savedCalories > 0 {
                statRow("Calories", "\(Int(savedCalories)) cal")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundColor(.white)
        }
    }
}
