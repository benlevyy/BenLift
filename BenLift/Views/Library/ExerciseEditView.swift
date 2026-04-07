import SwiftUI
import SwiftData

struct ExerciseEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let exercise: Exercise?

    @State private var name: String = ""
    @State private var muscleGroup: MuscleGroup = .chest
    @State private var equipment: Equipment = .barbell
    @State private var defaultWeight: String = ""

    var isEditing: Bool { exercise != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise Details") {
                    TextField("Name", text: $name)

                    Picker("Muscle Group", selection: $muscleGroup) {
                        ForEach(MuscleGroup.allCases) { group in
                            Text(group.displayName).tag(group)
                        }
                    }

                    Picker("Equipment", selection: $equipment) {
                        ForEach(Equipment.allCases) { eq in
                            Text(eq.displayName).tag(eq)
                        }
                    }

                    TextField("Default Weight (lbs)", text: $defaultWeight)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(isEditing ? "Edit Exercise" : "Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let exercise {
                    name = exercise.name
                    muscleGroup = exercise.muscleGroup
                    equipment = exercise.equipment
                    defaultWeight = exercise.defaultWeight.map { String($0) } ?? ""
                }
            }
        }
    }

    private func save() {
        let weight = Double(defaultWeight)

        if let exercise {
            exercise.name = name
            exercise.muscleGroup = muscleGroup
            exercise.equipment = equipment
            exercise.defaultWeight = weight
        } else {
            let newExercise = Exercise(
                name: name,
                muscleGroup: muscleGroup,
                equipment: equipment,
                defaultWeight: weight,
                isCustom: true
            )
            modelContext.insert(newExercise)
        }
        try? modelContext.save()
    }
}
