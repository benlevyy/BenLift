import SwiftUI

/// Sheet for requesting AI exercise adaptation during a workout.
struct MidWorkoutAdaptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var workoutVM: PhoneWorkoutViewModel
    var program: TrainingProgram?
    @State private var selectedReason: AdaptReason = .equipmentTaken
    @State private var detailsText: String = ""

    private var targetExerciseName: String? {
        guard let idx = workoutVM.adaptTargetIndex, idx < workoutVM.exerciseStates.count else { return nil }
        return workoutVM.exerciseStates[idx].info.name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Context
                    if let name = targetExerciseName {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.accentBlue)
                            Text("Replace: \(name)")
                                .font(.headline)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentBlue.opacity(0.08))
                        .cornerRadius(10)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.accentBlue)
                            Text("Adjust Remaining Workout")
                                .font(.headline)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentBlue.opacity(0.08))
                        .cornerRadius(10)
                    }

                    // Reason picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reason")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondaryText)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(AdaptReason.allCases) { reason in
                                Button {
                                    selectedReason = reason
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: reason.icon)
                                            .font(.caption)
                                        Text(reason.displayName)
                                            .font(.caption.bold())
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(selectedReason == reason ? Color.accentBlue : Color.cardSurface)
                                    .foregroundColor(selectedReason == reason ? .white : .primary)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }

                    // Details
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Details (optional)")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondaryText)

                        TextField("e.g., both cable machines are taken", text: $detailsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Ask AI button
                    if workoutVM.adaptSuggestion == nil && !workoutVM.isAdapting {
                        Button {
                            Task {
                                await workoutVM.requestAdaptation(
                                    exerciseIndex: workoutVM.adaptTargetIndex,
                                    reason: selectedReason,
                                    details: detailsText.isEmpty ? nil : detailsText,
                                    program: program
                                )
                            }
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Ask AI")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentBlue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }

                    // Loading
                    if workoutVM.isAdapting {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Finding alternatives...")
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    }

                    // Error
                    if let error = workoutVM.adaptError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.failedRed)
                            .padding(10)
                            .background(Color.failedRed.opacity(0.1))
                            .cornerRadius(8)
                    }

                    // Suggestion result
                    if let suggestion = workoutVM.adaptSuggestion {
                        suggestionView(suggestion)
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("AI Adapt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        workoutVM.dismissAdaptation()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Suggestion View

    private func suggestionView(_ suggestion: MidWorkoutAdaptResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Rationale
            if let rationale = suggestion.rationale, !rationale.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundColor(.accentBlue)
                    Text(rationale)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
                .padding(10)
                .background(Color.accentBlue.opacity(0.05))
                .cornerRadius(8)
            }

            // Suggested exercises
            ForEach(suggestion.exercises, id: \.name) { exercise in
                HStack(spacing: 10) {
                    Circle()
                        .fill(intentColor(exercise.intent))
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .font(.subheadline.bold())
                        HStack(spacing: 4) {
                            Text("\(exercise.sets)×\(exercise.targetReps)")
                                .font(.caption.monospacedDigit())
                            if exercise.weight > 0 {
                                Text("@ \(Int(exercise.weight)) lbs")
                                    .font(.caption)
                                    .foregroundColor(.accentBlue)
                            }
                        }
                        if let notes = exercise.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption2)
                                .foregroundColor(.secondaryText)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.cardSurface)
                .cornerRadius(8)
            }

            // Accept / Dismiss
            HStack(spacing: 12) {
                Button {
                    workoutVM.acceptAdaptation()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Accept")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentBlue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button {
                    workoutVM.dismissAdaptation()
                    dismiss()
                } label: {
                    Text("Dismiss")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cardSurface)
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
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
