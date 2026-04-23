import SwiftUI

/// Hub view showing all exercises during an iPhone workout.
///
/// Built on `List` so each row can expose swipe-actions — trailing swipe skips
/// (or restores), leading swipe fires an AI-picked swap via `onSwap`. Skipped
/// rows show ghosted + strikethrough and live in their own section below the
/// active pool so the user isn't re-distracted by them.
struct PhoneExerciseListView: View {
    @Bindable var workoutVM: PhoneWorkoutViewModel
    var onSelectExercise: (Int) -> Void
    var onAdapt: () -> Void
    var onSwap: (Int) -> Void
    var onFinish: () -> Void
    /// Tracks presentation of the add-exercise sheet. Lives on the hub
    /// because that's the only place the add button appears — exercise
    /// detail pushes below it in the nav stack and shouldn't multiplex
    /// its own add flow.
    @State private var showAddExercise = false

    private var sections: (incomplete: [(Int, PhoneWorkoutViewModel.ExerciseState)],
                           skipped: [(Int, PhoneWorkoutViewModel.ExerciseState)],
                           complete: [(Int, PhoneWorkoutViewModel.ExerciseState)]) {
        let all = workoutVM.exerciseStates.enumerated().map { ($0, $1) }
        let incomplete = all.filter { !$0.1.effectivelySkipped && !$0.1.isComplete }
        let skipped = all.filter { $0.1.effectivelySkipped && !$0.1.isComplete }
        let complete = all.filter { $0.1.isComplete && !$0.1.effectivelySkipped }
        return (incomplete, skipped, complete)
    }

    var body: some View {
        let groups = sections

        List {
            // Session header lives inside the list so it scrolls with content,
            // keeping vertical density consistent. A Section with no rows would
            // add unnecessary separator whitespace.
            if let name = workoutVM.sessionName {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(name)
                            .font(.title3.bold())
                        if let strategy = workoutVM.sessionStrategy {
                            Text(strategy)
                                .font(.caption)
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                }
            }

            // Active exercises — primary focus
            if !groups.incomplete.isEmpty {
                Section {
                    ForEach(groups.incomplete, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            // User-skipped exercises — ghosted, restorable
            if !groups.skipped.isEmpty {
                Section("Skipped") {
                    ForEach(groups.skipped, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            // Fully-logged exercises
            if !groups.complete.isEmpty {
                Section("Completed") {
                    ForEach(groups.complete, id: \.0) { index, state in
                        exerciseRow(state: state, index: index)
                    }
                }
            }

            // Footer actions — add / AI adapt / finish. Kept in-list so
            // they're reachable by thumb without a separate toolbar row.
            Section {
                Button {
                    showAddExercise = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add Exercise")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .foregroundColor(.accentBlue)

                Button {
                    workoutVM.adaptTargetIndex = nil
                    onAdapt()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("AI Suggest Changes")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .foregroundColor(.accentBlue)

                Button(role: .destructive) {
                    onFinish()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Finish Workout")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .sheet(isPresented: $showAddExercise) {
            // Reuse the same library picker Today uses, scoped to the
            // session's muscle focus. Selection → WatchExerciseInfo →
            // `addExercise` which mode-branches correctly (mutates locally
            // in standalone, forwards command in watch-mirrored).
            AddExerciseToPlanSheet(focus: workoutVM.muscleGroups) { exercise in
                let info = WatchExerciseInfo(
                    name: exercise.name,
                    sets: 3,
                    targetReps: "8-12",
                    suggestedWeight: exercise.defaultWeight ?? 0,
                    warmupSets: nil,
                    notes: nil,
                    intent: "isolation",
                    lastWeight: nil,
                    lastReps: nil,
                    equipment: exercise.equipment
                )
                workoutVM.addExercise(info)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func exerciseRow(state: PhoneWorkoutViewModel.ExerciseState, index: Int) -> some View {
        let row = rowContent(state: state, index: index)

        if state.effectivelySkipped {
            // Skipped: single-action restore swipe.
            row.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    workoutVM.unskipExercise(at: index)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            }
        } else if state.isComplete {
            // Completed: no swipes. Tap still opens detail for review/undo.
            row
        } else {
            // Active: leading = swap (AI pick), trailing = skip.
            row
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        onSwap(index)
                    } label: {
                        Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .tint(.accentBlue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        workoutVM.skipExercise(at: index)
                    } label: {
                        Label("Skip", systemImage: "forward.end.fill")
                    }
                }
        }
    }

    private func rowContent(state: PhoneWorkoutViewModel.ExerciseState, index: Int) -> some View {
        Button {
            guard !state.effectivelySkipped else { return }
            onSelectExercise(index)
        } label: {
            HStack(spacing: 12) {
                statusIndicator(state: state)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.info.name)
                        .font(.subheadline.bold())
                        .foregroundColor(titleColor(for: state))
                        .strikethrough(state.effectivelySkipped, color: .secondaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(state.targetSets)×\(state.info.targetReps)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondaryText)

                        if state.info.suggestedWeight > 0 {
                            Text("@ \(Int(state.info.suggestedWeight)) lbs")
                                .font(.caption)
                                .foregroundColor(state.effectivelySkipped ? .secondaryText : .accentBlue)
                        }
                    }

                    if state.totalVolume > 0 {
                        Text("\(Int(state.totalVolume)) lbs volume")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }

                Spacer()

                Circle()
                    .fill(intentColor(state.info.intent))
                    .frame(width: 8, height: 8)
                    .opacity(state.effectivelySkipped ? 0.3 : 1)

                if !state.effectivelySkipped && !state.isComplete {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            .opacity(state.effectivelySkipped ? 0.45 : 1)
        }
        .buttonStyle(.plain)
    }

    private func titleColor(for state: PhoneWorkoutViewModel.ExerciseState) -> Color {
        if state.effectivelySkipped { return .secondaryText }
        if state.isComplete { return .secondaryText }
        return .primary
    }

    private func statusIndicator(state: PhoneWorkoutViewModel.ExerciseState) -> some View {
        Group {
            if state.effectivelySkipped {
                Image(systemName: "forward.end.fill")
                    .foregroundColor(.secondaryText)
                    .font(.body)
                    .frame(width: 28, height: 28)
            } else if state.isComplete {
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
