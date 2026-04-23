import SwiftUI

/// The workout hub — shows all exercises, tap any to log sets.
///
/// Uses `List` so each row can expose a trailing swipe: skip on active rows,
/// restore on skipped rows. Swap is phone-only in Slice 1 (watch would need
/// an LLM path). Skipped rows ghost out at the bottom under "Skipped".
struct ExerciseListHubView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var showAddExercise = false

    var body: some View {
        let all = workoutVM.exerciseStates.enumerated().map { ($0, $1) }
        let incomplete = all.filter { !$0.1.isSkipped && !$0.1.isComplete }
        let skipped = all.filter { $0.1.isSkipped && !$0.1.isComplete }
        let complete = all.filter { $0.1.isComplete && !$0.1.isSkipped }

        List {
            Section {
                headerRow
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
            }

            if !incomplete.isEmpty {
                Section {
                    ForEach(incomplete, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            if !skipped.isEmpty {
                Section("Skipped") {
                    ForEach(skipped, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            if !complete.isEmpty {
                Section("Done") {
                    ForEach(complete, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            Section {
                // Both watch-owned and phone-mirrored sessions now get the
                // same action set — the watch-owned path mutates locally,
                // the mirrored path forwards commands to the phone.
                Button {
                    showAddExercise = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                        Text("Add Exercise")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.bordered)

                // Finish: on watch-owned sessions this goes through the
                // local summary screen flow; on mirrored sessions the
                // finishWorkout call forwards `.end` to the phone, which
                // persists the session + broadcasts the terminal snapshot.
                Button {
                    if workoutVM.workoutMode == .mirroredFromPhone {
                        workoutVM.finishWorkout()
                    } else {
                        workoutVM.currentScreen = .summary
                    }
                } label: {
                    Text("Finish Workout")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .navigationTitle(workoutVM.currentPlan?.sessionName ?? workoutVM.currentPlan?.category?.displayName ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddExercise) {
            WatchAddExerciseView(workoutVM: workoutVM)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
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
    }

    // MARK: - Exercise Row

    @ViewBuilder
    private func exerciseRow(state: WorkoutViewModel.ExerciseState, index: Int) -> some View {
        let row = rowButton(state: state, index: index)

        if state.isSkipped {
            row.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    workoutVM.unskipExercise(at: index)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            }
        } else if state.isComplete {
            row
        } else {
            row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    workoutVM.skipExercise(at: index)
                } label: {
                    Label("Skip", systemImage: "forward.end.fill")
                }
            }
        }
    }

    private func rowButton(state: WorkoutViewModel.ExerciseState, index: Int) -> some View {
        Button {
            guard !state.isSkipped else { return }
            workoutVM.selectExercise(at: index)
        } label: {
            HStack(spacing: 8) {
                statusIcon(state: state)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.info.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundColor(titleColor(for: state))
                        .strikethrough(state.isSkipped, color: .secondary)

                    Text("\(state.targetSets)×\(state.info.targetReps) @ \(Int(state.info.suggestedWeight))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .opacity(state.isSkipped ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusIcon(state: WorkoutViewModel.ExerciseState) -> some View {
        if state.isSkipped {
            Image(systemName: "forward.end.fill")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18)
        } else if state.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.body)
        } else if state.workingSetsCompleted > 0 {
            Text("\(state.workingSetsCompleted)/\(state.targetSets)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundColor(.blue)
                .frame(width: 28)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }

    private func titleColor(for state: WorkoutViewModel.ExerciseState) -> Color {
        if state.isSkipped { return .secondary }
        if state.isComplete { return .secondary }
        return .primary
    }
}
