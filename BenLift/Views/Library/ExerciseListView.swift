import SwiftUI
import SwiftData

struct ExerciseListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = LibraryViewModel()
    @State private var showAddExercise = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.exercisesGroupedByMuscle(from: modelContext), id: \.0) { group, exercises in
                    Section(group.displayName) {
                        ForEach(exercises) { exercise in
                            NavigationLink {
                                ExerciseEditView(exercise: exercise)
                            } label: {
                                exerciseRow(exercise)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                viewModel.deleteExercise(exercises[offset], context: modelContext)
                            }
                        }
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search exercises")
            .navigationTitle("Exercise Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddExercise = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddExercise) {
                ExerciseEditView(exercise: nil)
            }
        }
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exercise.name)
                .font(.body)

            HStack(spacing: 8) {
                Text(exercise.equipment.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cardSurface)
                    .cornerRadius(4)

                if let weight = exercise.defaultWeight {
                    Text(weight.formattedWeight())
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }

                if exercise.isCustom {
                    Text("Custom")
                        .font(.caption2)
                        .foregroundColor(.accentBlue)
                }
            }
        }
    }
}
