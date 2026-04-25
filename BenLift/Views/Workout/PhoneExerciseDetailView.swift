import SwiftUI

/// Set logging view for a single exercise during iPhone workout.
struct PhoneExerciseDetailView: View {
    @Bindable var workoutVM: PhoneWorkoutViewModel
    let exerciseIndex: Int
    var onAdaptExercise: () -> Void
    var onComplete: () -> Void

    private var state: PhoneWorkoutViewModel.ExerciseState? {
        guard exerciseIndex < workoutVM.exerciseStates.count else { return nil }
        return workoutVM.exerciseStates[exerciseIndex]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Exercise header
                exerciseHeader

                // Weight input
                weightSection

                // Reps input
                repsSection

                // Log Set button — optimistic UI, no spinner. Set appears in the
                // table instantly; the watch's snapshot reconciles in the background.
                let viewingMatchesActive = workoutVM.viewingExerciseIndex == workoutVM.activeExerciseIndex
                let invalidReps = workoutVM.currentReps <= 0 && !workoutVM.isWarmupPhase
                let isDisabled = invalidReps || !viewingMatchesActive

                Button {
                    Haptics.impact(.medium)
                    workoutVM.logSet()
                } label: {
                    Text("Log Set")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isDisabled ? Color.accentBlue.opacity(0.4) : Color.accentBlue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(isDisabled)

                // Logged sets table
                if let state, !state.loggedSets.isEmpty {
                    loggedSetsTable(state: state)
                }

                // Ghost data
                if let info = workoutVM.activeExerciseInfo,
                   let lastW = info.lastWeight, let lastR = info.lastReps {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption2)
                        Text("Last: \(Int(lastW)) × \(lastR.formattedReps)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondaryText)
                }

                // AI plan notes
                if let notes = workoutVM.activeExerciseInfo?.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.caption2)
                            .foregroundColor(.accentBlue)
                        Text(notes)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentBlue.opacity(0.05))
                    .cornerRadius(8)
                }

                // Bottom controls
                bottomControls
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            workoutVM.selectExercise(at: exerciseIndex)
        }
    }

    // MARK: - Exercise Header

    private var exerciseHeader: some View {
        VStack(spacing: 4) {
            Text(state?.info.name ?? "")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if workoutVM.isWarmupPhase {
                Text("Warm-up \(workoutVM.warmupSetIndex + 1) of \(workoutVM.totalWarmupSets)")
                    .font(.subheadline)
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.15))
                    .cornerRadius(6)
            } else {
                Text("Set \(workoutVM.workingSetsCompleted + 1) of \(workoutVM.targetSets)")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
    }

    // MARK: - Weight Section

    private var weightSection: some View {
        VStack(spacing: 8) {
            Text("Weight")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            HStack(spacing: 20) {
                RepeatingStepperButton {
                    workoutVM.adjustWeight(by: -workoutVM.effectiveWeightIncrement)
                } label: {
                    Image(systemName: "minus")
                        .font(.title2.bold())
                        .frame(width: 64, height: 64)
                        .background(Color.cardSurface)
                        .clipShape(Circle())
                }

                VStack(spacing: 0) {
                    Text("\(Int(workoutVM.currentWeight))")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: workoutVM.currentWeight)
                    Text("lbs")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
                .frame(minWidth: 110)

                RepeatingStepperButton {
                    workoutVM.adjustWeight(by: workoutVM.effectiveWeightIncrement)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .frame(width: 64, height: 64)
                        .background(Color.cardSurface)
                        .clipShape(Circle())
                }
            }
        }
        .padding()
        .background(Color.cardSurface.opacity(0.5))
        .cornerRadius(12)
    }

    // MARK: - Reps Section

    private var repsSection: some View {
        VStack(spacing: 8) {
            Text("Reps")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            HStack(spacing: 20) {
                RepeatingStepperButton {
                    workoutVM.adjustReps(by: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.title2.bold())
                        .frame(width: 64, height: 64)
                        .background(Color.cardSurface)
                        .clipShape(Circle())
                }

                Text(workoutVM.currentReps.formattedReps)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(
                        workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0
                            ? .failedRed : .primary
                    )
                    .frame(minWidth: 90)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: workoutVM.currentReps)

                RepeatingStepperButton {
                    workoutVM.adjustReps(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .frame(width: 64, height: 64)
                        .background(Color.cardSurface)
                        .clipShape(Circle())
                }

                // Failed rep toggle — kept distinct (smaller, destructive tint)
                // so it reads as an annotation, not a primary stepper.
                Button {
                    Haptics.warning()
                    workoutVM.toggleFailedRep()
                } label: {
                    Text("F")
                        .font(.title3.bold())
                        .foregroundColor(
                            workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0
                                ? .white : .failedRed
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            workoutVM.currentReps.truncatingRemainder(dividingBy: 1) != 0
                                ? Color.failedRed : Color.failedRed.opacity(0.15)
                        )
                        .clipShape(Circle())
                }
            }
        }
    }

    // MARK: - Logged Sets Table

    private func loggedSetsTable(state: PhoneWorkoutViewModel.ExerciseState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logged Sets")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            ForEach(Array(state.loggedSets.enumerated()), id: \.offset) { _, set in
                HStack {
                    if set.isWarmup {
                        Text("W")
                            .font(.caption2.bold())
                            .foregroundColor(.yellow)
                            .frame(width: 20)
                    } else {
                        Text("\(set.setNumber - state.loggedSets.filter(\.isWarmup).count)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.secondaryText)
                            .frame(width: 20)
                    }

                    Text("\(Int(set.weight)) lbs")
                        .font(.subheadline.monospacedDigit())

                    Text("×")
                        .font(.caption)
                        .foregroundColor(.secondaryText)

                    Text(set.reps.formattedReps)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundColor(set.reps.truncatingRemainder(dividingBy: 1) != 0 ? .failedRed : .primary)

                    Spacer()

                    Text(Int(set.weight * floor(set.reps)), format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondaryText)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(set.isWarmup ? Color.yellow.opacity(0.05) : Color.clear)
                .cornerRadius(4)
            }
        }
        .padding(12)
        .background(Color.cardSurface)
        .cornerRadius(10)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 12) {
            // Undo
            if let state, !state.loggedSets.isEmpty {
                Button {
                    workoutVM.undoLastSet()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.cardSurface)
                    .cornerRadius(8)
                }
            }

            // Skip warmups
            if workoutVM.isWarmupPhase {
                Button {
                    workoutVM.skipWarmups()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "forward.fill")
                        Text("Skip Warmups")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.cardSurface)
                    .cornerRadius(8)
                }
            }

            Spacer()

            // Swap exercise
            Button {
                onAdaptExercise()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Swap")
                }
                .font(.subheadline)
                .foregroundColor(.accentBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentBlue.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}
