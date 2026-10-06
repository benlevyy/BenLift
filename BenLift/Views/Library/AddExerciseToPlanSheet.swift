import SwiftUI
import SwiftData

// MARK: - Add Exercise to Plan Sheet

struct AddExerciseToPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Muscle groups to prioritize in the list. Empty = show every muscle
    /// group (no narrowing). Pass the plan's muscle groups to align with
    /// what the session is actually training.
    let focus: [MuscleGroup]
    let onSelect: (Exercise) -> Void

    @Query private var allExercises: [Exercise]
    @State private var searchText = ""
    @State private var showAll = false

    private var filteredExercises: [Exercise] {
        let scoped: [Exercise]
        if focus.isEmpty || showAll {
            scoped = allExercises
        } else {
            scoped = allExercises.filter { focus.contains($0.muscleGroup) }
        }
        if searchText.isEmpty { return scoped }
        return scoped.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var groupedExercises: [(MuscleGroup, [Exercise])] {
        let grouped = Dictionary(grouping: filteredExercises) { $0.muscleGroup }
        return MuscleGroup.allCases.compactMap { group in
            guard let exercises = grouped[group], !exercises.isEmpty else { return nil }
            return (group, exercises)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedExercises, id: \.0) { group, exercises in
                    Section(group.displayName) {
                        ForEach(exercises) { exercise in
                            Button {
                                onSelect(exercise)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(exercise.name)
                                    Spacer()
                                    if let w = exercise.defaultWeight {
                                        Text("\(w.formattedLoad) lbs")
                                            .font(.caption)
                                            .foregroundColor(.secondaryText)
                                    }
                                    Text(exercise.equipment.displayName)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.cardSurface)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Focus toggle — only shown when there's actually a focus to
                // widen out of; without it the button would do nothing.
                if !focus.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(showAll ? "Focus" : "All") {
                            showAll.toggle()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}
