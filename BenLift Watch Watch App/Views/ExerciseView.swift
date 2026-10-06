import SwiftUI

struct ExerciseView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var crownReps: Double = 0
    // Set true before any programmatic crownReps = … so the next onChange tick is ignored.
    @State private var suppressCrownSync: Bool = false
    // Grabs the Digital Crown for the rep adjuster on appear so the outer
    // ScrollView doesn't compete for crown input.
    @FocusState private var repsFocused: Bool

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
                        // Skip-a-set / add-a-set, either side of the count they
                        // change. The control row below is already full, and
                        // these belong next to the number anyway.
                        HStack(spacing: 10) {
                            setCountButton("minus", enabled: workoutVM.canSkipSet, delta: -1)

                            Text("Set \(workoutVM.workingSetsCompleted + 1) of \(workoutVM.targetSets)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()

                            setCountButton("plus", enabled: workoutVM.canAddSet, delta: 1)
                        }
                    }
                }

                // Weight with +/- buttons
                HStack(spacing: 12) {
                    Button {
                        workoutVM.adjustWeight(by: -workoutVM.effectiveWeightIncrement)
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
                        workoutVM.adjustWeight(by: workoutVM.effectiveWeightIncrement)
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
                        suppressCrownSync = true
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
                        suppressCrownSync = true
                        crownReps = workoutVM.currentReps
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    // Failed rep toggle
                    Button {
                        workoutVM.toggleFailedRep()
                        suppressCrownSync = true
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
                .focused($repsFocused)
                .digitalCrownRotation(
                    $crownReps,
                    from: 0,
                    through: 30,
                    by: 1,
                    sensitivity: .low
                )
                .onChange(of: crownReps) { _, newValue in
                    // Buttons sync crownReps → currentReps programmatically; that write
                    // would otherwise fire here and .rounded() would erase the .5 that
                    // the F button just set.
                    if suppressCrownSync {
                        suppressCrownSync = false
                        return
                    }
                    // Crown produces fractional values mid-rotation; round so the rep
                    // count stays integer. Fractional (failed) reps are only set via
                    // the F button, never by scrolling.
                    workoutVM.currentReps = max(0, newValue.rounded())
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

                // Note typed on the phone — read-only here.
                if let note = workoutVM.activeExercise?.userNote, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .italic()
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                // Log Set
                Button {
                    workoutVM.logSet()
                } label: {
                    Text(workoutVM.nextSetIsWarmup ? "Log Warm-up" : "Log Set")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(workoutVM.nextSetIsWarmup ? .yellow : .accentColor)
                .disabled(workoutVM.currentReps <= 0 && !workoutVM.nextSetIsWarmup)

                // Undo / Skip Warmup / Back
                HStack(spacing: 6) {
                    // Undo last set
                    if let ex = workoutVM.activeExercise, !ex.loggedSets.isEmpty {
                        Button {
                            workoutVM.undoLastSet()
                            suppressCrownSync = true
                            crownReps = workoutVM.currentReps
                        } label: {
                            Text("Undo")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Warm-up flag — the counterpart to [F] on the reps row,
                    // and the only way to mark one now that plans no longer
                    // generate warm-up sets.
                    if !workoutVM.isWarmupPhase {
                        Button {
                            workoutVM.markNextSetAsWarmup.toggle()
                        } label: {
                            Text("W")
                                .font(.caption2.bold())
                        }
                        .buttonStyle(.bordered)
                        .tint(workoutVM.markNextSetAsWarmup ? .yellow : .gray)
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
            // Any route in — a tapped row, a rest ending, the phone moving
            // on — lands here with the weight loaded, never 0.
            workoutVM.ensureInputsPrimed()
            suppressCrownSync = true
            crownReps = workoutVM.currentReps
            repsFocused = true
        }
        .onChange(of: workoutVM.activeExerciseIndex) { _, _ in
            workoutVM.ensureInputsPrimed()
            suppressCrownSync = true
            crownReps = workoutVM.currentReps
        }
    }

    private func setCountButton(
        _ systemName: String,
        enabled: Bool,
        delta: Int
    ) -> some View {
        Button {
            workoutVM.adjustTargetSets(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? .accentColor : .secondary)
                .frame(width: 22, height: 22)
                .background(Color.gray.opacity(enabled ? 0.3 : 0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(delta > 0 ? "Add a set" : "Skip a set")
    }
}
