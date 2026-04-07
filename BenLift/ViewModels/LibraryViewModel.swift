import SwiftUI
import SwiftData

@Observable
class LibraryViewModel {
    var searchText: String = ""
    var selectedEquipmentFilter: Equipment?

    @MainActor
    func fetchExercises(from context: ModelContext) -> [Exercise] {
        let descriptor = FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    func fetchTemplates(from context: ModelContext) -> [WorkoutTemplate] {
        let descriptor = FetchDescriptor<WorkoutTemplate>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    func exercises(for category: WorkoutCategory, from context: ModelContext) -> [Exercise] {
        let groups = category.muscleGroups
        return fetchExercises(from: context).filter { groups.contains($0.muscleGroup) }
    }

    @MainActor
    func exercisesGroupedByMuscle(from context: ModelContext) -> [(MuscleGroup, [Exercise])] {
        let all = fetchExercises(from: context)
        let filtered = all.filter { exercise in
            let matchesSearch = searchText.isEmpty || exercise.name.localizedCaseInsensitiveContains(searchText)
            let matchesEquipment = selectedEquipmentFilter == nil || exercise.equipment == selectedEquipmentFilter
            return matchesSearch && matchesEquipment
        }

        let grouped = Dictionary(grouping: filtered) { $0.muscleGroup }
        return MuscleGroup.allCases.compactMap { group in
            guard let exercises = grouped[group], !exercises.isEmpty else { return nil }
            return (group, exercises)
        }
    }

    @MainActor
    func addExercise(
        name: String,
        muscleGroup: MuscleGroup,
        equipment: Equipment,
        defaultWeight: Double?,
        context: ModelContext
    ) {
        let exercise = Exercise(
            name: name,
            muscleGroup: muscleGroup,
            equipment: equipment,
            defaultWeight: defaultWeight,
            isCustom: true
        )
        context.insert(exercise)
        try? context.save()
    }

    @MainActor
    func deleteExercise(_ exercise: Exercise, context: ModelContext) {
        guard exercise.isCustom else { return }
        context.delete(exercise)
        try? context.save()
    }

    @MainActor
    func addTemplate(
        name: String,
        category: WorkoutCategory,
        context: ModelContext
    ) -> WorkoutTemplate {
        let template = WorkoutTemplate(name: name, category: category)
        context.insert(template)
        try? context.save()
        return template
    }

    @MainActor
    func deleteTemplate(_ template: WorkoutTemplate, context: ModelContext) {
        context.delete(template)
        try? context.save()
    }
}
