import SwiftUI
import SwiftData

struct TemplateEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var template: WorkoutTemplate
    @State private var showExercisePicker = false

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $template.name)

                Picker("Category", selection: $template.category) {
                    ForEach(WorkoutCategory.allCases) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
            }

            Section("Exercises") {
                ForEach(template.exercises.sorted { $0.order < $1.order }) { templateExercise in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(templateExercise.exerciseName)
                            .font(.body)
                        HStack {
                            Text("\(templateExercise.targetSets) sets x \(templateExercise.targetReps) reps")
                                .font(.caption)
                                .foregroundColor(.secondaryText)
                        }
                    }
                }
                .onMove { from, to in
                    moveExercises(from: from, to: to)
                }
                .onDelete { offsets in
                    deleteExercises(at: offsets)
                }

                Button {
                    showExercisePicker = true
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Edit Template")
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerView(category: template.category) { exercise in
                addExercise(exercise)
            }
        }
    }

    private func addExercise(_ exercise: Exercise) {
        let nextOrder = (template.exercises.map(\.order).max() ?? -1) + 1
        let templateExercise = TemplateExercise(
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            order: nextOrder
        )
        template.exercises.append(templateExercise)
        try? modelContext.save()
    }

    private func moveExercises(from source: IndexSet, to destination: Int) {
        var sorted = template.exercises.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, exercise) in sorted.enumerated() {
            exercise.order = index
        }
        try? modelContext.save()
    }

    private func deleteExercises(at offsets: IndexSet) {
        let sorted = template.exercises.sorted { $0.order < $1.order }
        for offset in offsets {
            let exercise = sorted[offset]
            modelContext.delete(exercise)
        }
        try? modelContext.save()
    }
}

// MARK: - Exercise Picker

struct ExercisePickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let category: WorkoutCategory
    let onSelect: (Exercise) -> Void

    @Query private var allExercises: [Exercise]

    var filteredExercises: [Exercise] {
        let groups = category.muscleGroups
        return allExercises.filter { groups.contains($0.muscleGroup) }
    }

    var body: some View {
        NavigationStack {
            List(filteredExercises) { exercise in
                Button {
                    onSelect(exercise)
                    dismiss()
                } label: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                        Text(exercise.muscleGroup.displayName)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }
            }
            .navigationTitle("Add Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
