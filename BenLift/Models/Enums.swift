import SwiftUI

// MARK: - Muscle Groups

enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest, shoulders, triceps
    case back, biceps, forearms
    case quads, hamstrings, glutes, calves
    case core

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .shoulders: return "Shoulders"
        case .triceps: return "Triceps"
        case .back: return "Back"
        case .biceps: return "Biceps"
        case .forearms: return "Forearms"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .glutes: return "Glutes"
        case .calves: return "Calves"
        case .core: return "Core"
        }
    }
}

// MARK: - Equipment

enum Equipment: String, Codable, CaseIterable, Identifiable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Workout Category (Push/Pull/Legs)

enum WorkoutCategory: String, Codable, CaseIterable, Identifiable {
    case push, pull, legs

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .push: return Color(hex: "4A90D9")
        case .pull: return Color(hex: "4CAF50")
        case .legs: return Color(hex: "FF9800")
        }
    }

    var muscleGroups: [MuscleGroup] {
        switch self {
        case .push: return [.chest, .shoulders, .triceps]
        case .pull: return [.back, .biceps, .forearms]
        case .legs: return [.quads, .hamstrings, .glutes, .calves]
        }
    }
}

// MARK: - Experience Level

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case beginner, intermediate, advanced

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Overall Rating (Post-Workout)

enum OverallRating: String, Codable {
    case prDay = "pr_day"
    case good
    case average
    case recovery

    var displayName: String {
        switch self {
        case .prDay: return "PR Day"
        case .good: return "Good"
        case .average: return "Average"
        case .recovery: return "Recovery"
        }
    }

    var color: Color {
        switch self {
        case .prDay: return Color(hex: "34C759")
        case .good: return Color(hex: "4A90D9")
        case .average: return Color(hex: "8E8E93")
        case .recovery: return Color(hex: "FF9800")
        }
    }
}

// MARK: - Exercise Intent (AI-assigned)

enum ExerciseIntent: String, Codable, CaseIterable {
    case primaryCompound = "primary compound"
    case secondaryCompound = "secondary compound"
    case isolation
    case finisher

    var displayName: String {
        switch self {
        case .primaryCompound: return "Primary"
        case .secondaryCompound: return "Secondary"
        case .isolation: return "Isolation"
        case .finisher: return "Finisher"
        }
    }
}

// MARK: - Training Goal

enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case strength, hypertrophy, recomposition, generalFitness

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strength: return "Strength"
        case .hypertrophy: return "Hypertrophy"
        case .recomposition: return "Recomposition"
        case .generalFitness: return "General Fitness"
        }
    }
}

// MARK: - Weight Unit

enum WeightUnit: String, Codable, CaseIterable {
    case lbs, kg

    var conversionFactor: Double {
        switch self {
        case .lbs: return 1.0
        case .kg: return 0.453592
        }
    }

    var displaySuffix: String {
        rawValue
    }
}

// MARK: - Equipment Access

enum EquipmentAccess: String, Codable, CaseIterable, Identifiable {
    case fullGym = "full_gym"
    case homeGym = "home_gym"
    case limited

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullGym: return "Full Gym"
        case .homeGym: return "Home Gym"
        case .limited: return "Limited"
        }
    }
}
