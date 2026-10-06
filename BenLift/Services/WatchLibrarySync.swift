import Foundation
import SwiftData

/// Keeps the watch's add-exercise picker aware of exercises the user made
/// on the phone. Called after every library edit and once per launch; the
/// sync layer drops the send when nothing changed.
@MainActor
enum WatchLibrarySync {
    static func pushCustomExercises(from context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.isCustom == true }
        )
        let customs = (try? context.fetch(descriptor)) ?? []
        WatchSyncService.shared.sendCustomExercises(customs.map {
            WatchCustomExercise(
                name: $0.name,
                muscleGroup: $0.muscleGroup,
                equipment: $0.equipment,
                defaultWeight: $0.defaultWeight
            )
        })
    }
}
