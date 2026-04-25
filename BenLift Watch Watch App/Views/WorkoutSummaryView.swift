import SwiftUI

struct WorkoutSummaryView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var hasEnded = false
    @State private var isSaving = false
    /// Three-step flow: confirm → effort → saved.
    @State private var phase: Phase = .confirm
    @State private var effortScore: Int = 6

    enum Phase { case confirm, effort, saved }

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

                } else if phase == .saved || hasEnded {
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

                } else if phase == .effort {
                    effortSection
                } else {
                    Text("Finish?")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .padding(.top, 8)

                    liveStatsSection

                    Button {
                        // Capture stats now, then move to effort prompt.
                        // finishWorkout() runs after the user picks (or skips)
                        // so HKWorkout / WCSession persist together with the
                        // effort rating attached.
                        savedExerciseCount = workoutVM.exerciseStates.filter { !$0.loggedSets.isEmpty }.count
                        savedSetCount = workoutVM.totalSetsCompleted
                        savedVolume = workoutVM.totalVolume
                        savedDuration = workoutVM.elapsedTime
                        savedAvgHR = workoutVM.averageHeartRate
                        savedCalories = workoutVM.activeCalories

                        withAnimation { phase = .effort }
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

    // MARK: - Effort Picker

    /// 1–10 RPE-style picker matching Apple's Workout Effort scale (watchOS 11+).
    /// Persisted via HKWorkoutEffortRelationship so it appears in the Fitness app.
    private var effortSection: some View {
        VStack(spacing: 8) {
            Text("Effort")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.top, 4)

            Text(effortLabel(effortScore))
                .font(.caption2)
                .foregroundColor(.gray)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(effortScore) / 10.0)
                    .stroke(effortColor(effortScore), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: effortScore)
                Text("\(effortScore)")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
            }
            .frame(width: 90, height: 90)
            .focusable(true)
            .digitalCrownRotation(
                .init(get: { Double(effortScore) }, set: { effortScore = max(1, min(10, Int($0.rounded()))) }),
                from: 1, through: 10, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
            )

            HStack(spacing: 6) {
                Button {
                    if effortScore > 1 { effortScore -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    if effortScore < 10 { effortScore += 1 }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                commitFinish(effort: Double(effortScore))
            } label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)

            Button {
                commitFinish(effort: nil)
            } label: {
                Text("Skip")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    private func commitFinish(effort: Double?) {
        isSaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            workoutVM.finishWorkout(effortScore: effort)
            isSaving = false
            hasEnded = true
            phase = .saved
        }
    }

    private func effortLabel(_ score: Int) -> String {
        switch score {
        case 1...2: return "Easy"
        case 3...4: return "Light"
        case 5...6: return "Moderate"
        case 7...8: return "Hard"
        case 9: return "Very Hard"
        default: return "All Out"
        }
    }

    private func effortColor(_ score: Int) -> Color {
        switch score {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
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
