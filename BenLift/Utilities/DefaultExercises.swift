import Foundation
import SwiftData

struct DefaultExercises {

    struct ExerciseDef {
        let name: String
        let muscleGroup: MuscleGroup
        let equipment: Equipment
        let defaultWeight: Double?
    }

    // MARK: - Push Exercises

    static let push: [ExerciseDef] = [
        // Chest — Compounds
        ExerciseDef(name: "Bench Press", muscleGroup: .chest, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "DB Incline Press", muscleGroup: .chest, equipment: .dumbbell, defaultWeight: 55),
        ExerciseDef(name: "DB Flat Press", muscleGroup: .chest, equipment: .dumbbell, defaultWeight: 55),
        ExerciseDef(name: "Machine Press", muscleGroup: .chest, equipment: .machine, defaultWeight: 45),
        ExerciseDef(name: "Incline Barbell Press", muscleGroup: .chest, equipment: .barbell, defaultWeight: 115),
        ExerciseDef(name: "Close Grip Bench", muscleGroup: .triceps, equipment: .barbell, defaultWeight: 115),
        ExerciseDef(name: "Landmine Press", muscleGroup: .chest, equipment: .barbell, defaultWeight: 45),
        ExerciseDef(name: "Single Arm DB Floor Press", muscleGroup: .chest, equipment: .dumbbell, defaultWeight: 40),
        ExerciseDef(name: "Machine Incline Press", muscleGroup: .chest, equipment: .machine, defaultWeight: 90),
        ExerciseDef(name: "Svend Press", muscleGroup: .chest, equipment: .dumbbell, defaultWeight: 10),
        // Chest — Isolation
        ExerciseDef(name: "Cable Flys", muscleGroup: .chest, equipment: .cable, defaultWeight: 17.5),
        ExerciseDef(name: "Cable Fly (3 Height)", muscleGroup: .chest, equipment: .cable, defaultWeight: 12.5),
        ExerciseDef(name: "Pec Deck", muscleGroup: .chest, equipment: .machine, defaultWeight: 100),
        // Shoulders
        ExerciseDef(name: "DB Shoulder Press", muscleGroup: .shoulders, equipment: .dumbbell, defaultWeight: 45),
        ExerciseDef(name: "Overhead Press", muscleGroup: .shoulders, equipment: .barbell, defaultWeight: 85),
        ExerciseDef(name: "Machine Shoulder Press", muscleGroup: .shoulders, equipment: .machine, defaultWeight: 45),
        ExerciseDef(name: "Lateral Raises", muscleGroup: .shoulders, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Cable Lateral Raise", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 10),
        ExerciseDef(name: "Rear Delt Fly", muscleGroup: .shoulders, equipment: .dumbbell, defaultWeight: 15),
        ExerciseDef(name: "Cable Y-Raise", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 7.5),
        ExerciseDef(name: "Lu Raises", muscleGroup: .shoulders, equipment: .dumbbell, defaultWeight: 10),
        ExerciseDef(name: "Cable Front Raise", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 15),
        ExerciseDef(name: "Plate Bus Driver", muscleGroup: .shoulders, equipment: .dumbbell, defaultWeight: 10),
        ExerciseDef(name: "Banded Shoulder Dislocate", muscleGroup: .shoulders, equipment: .bodyweight, defaultWeight: nil),
        // Triceps
        ExerciseDef(name: "Skull Crushers", muscleGroup: .triceps, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Tricep Pushdown", muscleGroup: .triceps, equipment: .cable, defaultWeight: 57.5),
        ExerciseDef(name: "Tricep Overhead Extension", muscleGroup: .triceps, equipment: .cable, defaultWeight: 47.5),
        ExerciseDef(name: "Dips", muscleGroup: .triceps, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Tricep Kickback", muscleGroup: .triceps, equipment: .dumbbell, defaultWeight: 15),
        ExerciseDef(name: "JM Press", muscleGroup: .triceps, equipment: .barbell, defaultWeight: 75),
        ExerciseDef(name: "Cable Tricep Kickback", muscleGroup: .triceps, equipment: .cable, defaultWeight: 12.5),
        ExerciseDef(name: "Diamond Push-ups", muscleGroup: .triceps, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Single Arm Tricep Pushdown", muscleGroup: .triceps, equipment: .cable, defaultWeight: 20),
        ExerciseDef(name: "French Press", muscleGroup: .triceps, equipment: .dumbbell, defaultWeight: 25),
        ExerciseDef(name: "Bench Dips", muscleGroup: .triceps, equipment: .bodyweight, defaultWeight: nil),
    ]

    // MARK: - Pull Exercises

    static let pull: [ExerciseDef] = [
        // Back — Vertical
        ExerciseDef(name: "Pull-ups", muscleGroup: .back, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Chin-ups", muscleGroup: .back, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Lat Pulldown", muscleGroup: .back, equipment: .machine, defaultWeight: 145),
        ExerciseDef(name: "One Arm Lat Pulldown", muscleGroup: .back, equipment: .cable, defaultWeight: 57.5),
        ExerciseDef(name: "Straight Arm Pulldown", muscleGroup: .back, equipment: .cable, defaultWeight: 30),
        ExerciseDef(name: "Neutral Grip Lat Pulldown", muscleGroup: .back, equipment: .machine, defaultWeight: 130),
        // Back — Horizontal
        ExerciseDef(name: "Seated Row", muscleGroup: .back, equipment: .cable, defaultWeight: 145),
        ExerciseDef(name: "Chest Supported Row", muscleGroup: .back, equipment: .dumbbell, defaultWeight: 55),
        ExerciseDef(name: "Barbell Row", muscleGroup: .back, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "DB Row", muscleGroup: .back, equipment: .dumbbell, defaultWeight: 50),
        ExerciseDef(name: "T-Bar Row", muscleGroup: .back, equipment: .barbell, defaultWeight: 90),
        ExerciseDef(name: "Meadows Row", muscleGroup: .back, equipment: .barbell, defaultWeight: 45),
        ExerciseDef(name: "Pendlay Row", muscleGroup: .back, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "Seal Row", muscleGroup: .back, equipment: .dumbbell, defaultWeight: 40),
        ExerciseDef(name: "Machine Row", muscleGroup: .back, equipment: .machine, defaultWeight: 115),
        ExerciseDef(name: "Inverted Row", muscleGroup: .back, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Single Arm Cable Row", muscleGroup: .back, equipment: .cable, defaultWeight: 50),
        ExerciseDef(name: "Rack Pull", muscleGroup: .back, equipment: .barbell, defaultWeight: 225),
        ExerciseDef(name: "Kayak Row", muscleGroup: .back, equipment: .cable, defaultWeight: 40),
        // Upper Back / Posture
        ExerciseDef(name: "Prone Y-T-W Raises", muscleGroup: .back, equipment: .dumbbell, defaultWeight: 5),
        ExerciseDef(name: "Band Pull-Apart", muscleGroup: .back, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Kelso Shrug", muscleGroup: .back, equipment: .dumbbell, defaultWeight: 30),
        ExerciseDef(name: "Snatch Grip Barbell Shrug", muscleGroup: .back, equipment: .barbell, defaultWeight: 135),
        // Rear Delts / Prehab
        ExerciseDef(name: "Face Pulls", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 50),
        ExerciseDef(name: "Reverse Pec Deck", muscleGroup: .shoulders, equipment: .machine, defaultWeight: 70),
        ExerciseDef(name: "Face Pull w/ External Rotation", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 30),
        ExerciseDef(name: "Cable External Rotation", muscleGroup: .shoulders, equipment: .cable, defaultWeight: 10),
        // Biceps
        ExerciseDef(name: "Barbell Curl", muscleGroup: .biceps, equipment: .barbell, defaultWeight: 30),
        ExerciseDef(name: "Hammer Curl", muscleGroup: .biceps, equipment: .dumbbell, defaultWeight: 25),
        ExerciseDef(name: "Incline Hammer Curl", muscleGroup: .biceps, equipment: .dumbbell, defaultWeight: 25),
        ExerciseDef(name: "Preacher Curl", muscleGroup: .biceps, equipment: .machine, defaultWeight: 12.5),
        ExerciseDef(name: "Incline Curl", muscleGroup: .biceps, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Cable Curl", muscleGroup: .biceps, equipment: .cable, defaultWeight: 30),
        ExerciseDef(name: "Spider Curl", muscleGroup: .biceps, equipment: .dumbbell, defaultWeight: 15),
        ExerciseDef(name: "EZ Bar Curl", muscleGroup: .biceps, equipment: .barbell, defaultWeight: 45),
        ExerciseDef(name: "Concentration Curl", muscleGroup: .biceps, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Bayesian Curl", muscleGroup: .biceps, equipment: .cable, defaultWeight: 20),
        // Forearms
        ExerciseDef(name: "Wrist Curl", muscleGroup: .forearms, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Reverse Curl", muscleGroup: .forearms, equipment: .barbell, defaultWeight: 40),
    ]

    // MARK: - Legs Exercises

    static let legs: [ExerciseDef] = [
        // Quads — Compounds
        ExerciseDef(name: "Squat", muscleGroup: .quads, equipment: .barbell, defaultWeight: 185),
        ExerciseDef(name: "Front Squat", muscleGroup: .quads, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "Hack Squat", muscleGroup: .quads, equipment: .machine, defaultWeight: 45),
        ExerciseDef(name: "Leg Press", muscleGroup: .quads, equipment: .machine, defaultWeight: 270),
        ExerciseDef(name: "Goblet Squat", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 45),
        ExerciseDef(name: "Pendulum Squat", muscleGroup: .quads, equipment: .machine, defaultWeight: 90),
        ExerciseDef(name: "Belt Squat", muscleGroup: .quads, equipment: .machine, defaultWeight: 135),
        // Quads — Unilateral
        ExerciseDef(name: "Split Squat", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 25),
        ExerciseDef(name: "Bulgarian Split Squat", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 20),
        ExerciseDef(name: "Step Ups", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 10),
        ExerciseDef(name: "Walking Lunges", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 25),
        ExerciseDef(name: "Reverse Lunge", muscleGroup: .quads, equipment: .dumbbell, defaultWeight: 25),
        // Quads — Isolation
        ExerciseDef(name: "Leg Extension", muscleGroup: .quads, equipment: .machine, defaultWeight: 180),
        ExerciseDef(name: "Sissy Squat", muscleGroup: .quads, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "KB Goblet Squat Hold", muscleGroup: .quads, equipment: .kettlebell, defaultWeight: 25),
        // Hamstrings
        ExerciseDef(name: "Romanian Deadlift", muscleGroup: .hamstrings, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "Deadlift", muscleGroup: .hamstrings, equipment: .barbell, defaultWeight: 225),
        ExerciseDef(name: "DB Romanian Deadlift", muscleGroup: .hamstrings, equipment: .dumbbell, defaultWeight: 50),
        ExerciseDef(name: "Hamstring Curl", muscleGroup: .hamstrings, equipment: .machine, defaultWeight: 100),
        ExerciseDef(name: "Nordic Curl", muscleGroup: .hamstrings, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Good Morning", muscleGroup: .hamstrings, equipment: .barbell, defaultWeight: 95),
        ExerciseDef(name: "Single Leg RDL", muscleGroup: .hamstrings, equipment: .dumbbell, defaultWeight: 30),
        ExerciseDef(name: "Glute Ham Raise", muscleGroup: .hamstrings, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Jefferson Curl", muscleGroup: .hamstrings, equipment: .dumbbell, defaultWeight: 15),
        // Glutes
        ExerciseDef(name: "Hip Thrust", muscleGroup: .glutes, equipment: .barbell, defaultWeight: 135),
        ExerciseDef(name: "Cable Pull Through", muscleGroup: .glutes, equipment: .cable, defaultWeight: 40),
        ExerciseDef(name: "Kettlebell Swing", muscleGroup: .glutes, equipment: .kettlebell, defaultWeight: 35),
        ExerciseDef(name: "Reverse Hyperextension", muscleGroup: .glutes, equipment: .machine, defaultWeight: 90),
        ExerciseDef(name: "Cable Kickback", muscleGroup: .glutes, equipment: .cable, defaultWeight: 25),
        ExerciseDef(name: "Hip 90/90 Stretch", muscleGroup: .glutes, equipment: .bodyweight, defaultWeight: nil),
        // Calves
        ExerciseDef(name: "Calf Raises", muscleGroup: .calves, equipment: .machine, defaultWeight: 150),
        ExerciseDef(name: "Seated Calf Raise", muscleGroup: .calves, equipment: .machine, defaultWeight: 90),
        ExerciseDef(name: "Single Leg Calf Raise", muscleGroup: .calves, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Donkey Calf Raise", muscleGroup: .calves, equipment: .machine, defaultWeight: 135),
    ]

    // MARK: - Core Exercises (available on any day)

    static let core: [ExerciseDef] = [
        ExerciseDef(name: "Pallof Press", muscleGroup: .core, equipment: .cable, defaultWeight: 25),
        ExerciseDef(name: "Ab Wheel Rollout", muscleGroup: .core, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Dead Bug", muscleGroup: .core, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Copenhagen Plank", muscleGroup: .core, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Hanging Leg Raise", muscleGroup: .core, equipment: .bodyweight, defaultWeight: nil),
        ExerciseDef(name: "Farmer's Carry", muscleGroup: .core, equipment: .dumbbell, defaultWeight: 70),
        ExerciseDef(name: "Suitcase Carry", muscleGroup: .core, equipment: .dumbbell, defaultWeight: 50),
        ExerciseDef(name: "Cable Woodchop", muscleGroup: .core, equipment: .cable, defaultWeight: 30),
    ]

    static let all: [ExerciseDef] = push + pull + legs + core

    // MARK: - Exercise -> Category mapping

    static func category(for exerciseName: String) -> WorkoutCategory? {
        if push.contains(where: { $0.name == exerciseName }) { return .push }
        if pull.contains(where: { $0.name == exerciseName }) { return .pull }
        if legs.contains(where: { $0.name == exerciseName }) { return .legs }
        return nil // core exercises are available on any day
    }

    static func exercises(for category: WorkoutCategory) -> [ExerciseDef] {
        switch category {
        case .push: return push
        case .pull: return pull
        case .legs: return legs
        }
    }

    // MARK: - Seeding

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { !$0.isCustom }
        )
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0

        guard existingCount == 0 else {
            print("[BenLift] Exercise library already seeded (\(existingCount) exercises)")
            return
        }

        for def in all {
            let exercise = Exercise(
                name: def.name,
                muscleGroup: def.muscleGroup,
                equipment: def.equipment,
                defaultWeight: def.defaultWeight,
                isCustom: false
            )
            context.insert(exercise)
        }

        try? context.save()
        print("[BenLift] Seeded \(all.count) default exercises")
    }

    @MainActor
    static func reseed(in context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>(
            predicate: #Predicate { !$0.isCustom }
        )
        if let existing = try? context.fetch(descriptor) {
            for exercise in existing {
                context.delete(exercise)
            }
        }
        try? context.save()

        for def in all {
            let exercise = Exercise(
                name: def.name,
                muscleGroup: def.muscleGroup,
                equipment: def.equipment,
                defaultWeight: def.defaultWeight,
                isCustom: false
            )
            context.insert(exercise)
        }
        try? context.save()
        print("[BenLift] Reseeded \(all.count) default exercises")
    }

    @MainActor
    static func buildMuscleGroupLookup(from context: ModelContext) -> [String: MuscleGroup] {
        let descriptor = FetchDescriptor<Exercise>()
        guard let exercises = try? context.fetch(descriptor) else { return [:] }
        var lookup: [String: MuscleGroup] = [:]
        for exercise in exercises {
            lookup[exercise.name] = exercise.muscleGroup
        }
        return lookup
    }
}
