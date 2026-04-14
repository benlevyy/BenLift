import SwiftUI

/// Hub view showing all exercises during an iPhone workout.
struct PhoneExerciseListView: View {
    @Bindable var workoutVM: PhoneWorkoutViewModel
    var onSelectExercise: (Int) -> Void
    var onAdapt: () -> Void
    var onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Session name
                if let name = workoutVM.sessionName {
                    Text(name)
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Strategy note
                if let strategy = workoutVM.sessionStrategy {
                    Text(strategy)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardSurface)
                        .cornerRadius(8)
                }

                // Incomplete exercises
                let incomplete = workoutVM.exerciseStates.enumerated().filter { !$0.element.isComplete }
                let complete = workoutVM.exerciseStates.enumerated().filter { $0.element.isComplete }

                ForEach(incomplete, id: \.element.id) { index, state in
                    exerciseCard(state: state, index: index)
                }

                // Completed divider
                if !complete.isEmpty {
                    HStack(spacing: 8) {
                        Rectangle().fill(Color.secondaryText.opacity(0.2)).frame(height: 1)
                        Text("Completed")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                        Rectangle().fill(Color.secondaryText.opacity(0.2)).frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    ForEach(complete, id: \.element.id) { index, state in
                        exerciseCard(state: state, index: index)
                    }
                }

                // AI Adapt button
                Button {
                    workoutVM.adaptTargetIndex = nil
                    onAdapt()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                        Text("AI Suggest Swap")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.accentBlue.opacity(0.1))
                    .foregroundColor(.accentBlue)
                    .cornerRadius(10)
                }

                // Finish button
                Button {
                    onFinish()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Finish Workout")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.failedRed)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
            .padding()
        }
        .background(Color.appBackground)
    }

    // MARK: - Exercise Card

    private func exerciseCard(state: PhoneWorkoutViewModel.ExerciseState, index: Int) -> some View {
        Button {
            onSelectExercise(index)
        } label: {
            HStack(spacing: 12) {
                // Status indicator
                statusIndicator(state: state)

                // Exercise info
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.info.name)
                        .font(.subheadline.bold())
                        .foregroundColor(state.isComplete ? .secondaryText : .primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(state.targetSets)×\(state.info.targetReps)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondaryText)

                        if state.info.suggestedWeight > 0 {
                            Text("@ \(Int(state.info.suggestedWeight)) lbs")
                                .font(.caption)
                                .foregroundColor(.accentBlue)
                        }
                    }

                    // Volume if any sets logged
                    if state.totalVolume > 0 {
                        Text("\(Int(state.totalVolume)) lbs volume")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }

                Spacer()

                // Intent color dot
                Circle()
                    .fill(intentColor(state.info.intent))
                    .frame(width: 8, height: 8)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            .padding(12)
            .background(state.isComplete ? Color.cardSurface.opacity(0.5) : Color.cardSurface)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func statusIndicator(state: PhoneWorkoutViewModel.ExerciseState) -> some View {
        Group {
            if state.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.prGreen)
                    .font(.title3)
            } else if state.workingSetsCompleted > 0 {
                Text("\(state.workingSetsCompleted)/\(state.targetSets)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(.accentBlue)
                    .frame(width: 32, height: 32)
                    .background(Color.accentBlue.opacity(0.1))
                    .clipShape(Circle())
            } else {
                Circle()
                    .stroke(Color.secondaryText.opacity(0.3), lineWidth: 2)
                    .frame(width: 28, height: 28)
            }
        }
    }

    private func intentColor(_ intent: String?) -> Color {
        switch intent {
        case "primary compound": return .accentBlue
        case "secondary compound": return .pushBlue
        case "isolation": return .secondaryText
        case "finisher": return .legsOrange
        default: return .secondaryText
        }
    }
}
