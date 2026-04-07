import Foundation

struct StatsEngine {

    // MARK: - Estimated 1RM (Epley Formula)

    /// Epley formula: weight × (1 + reps / 30)
    /// For failed reps (e.g., 4.5), use the raw value — it's useful signal.
    static func estimatedOneRepMax(weight: Double, reps: Double) -> Double {
        guard weight > 0 && reps > 0 else { return 0 }
        if reps <= 1 { return weight }
        return weight * (1.0 + reps / 30.0)
    }

    // MARK: - Volume Calculations

    /// Total volume across all entries in a session (working sets only).
    static func totalVolume(entries: [ExerciseEntry]) -> Double {
        entries.reduce(0) { $0 + exerciseVolume(sets: $1.sets.filter { !$0.isWarmup }) }
    }

    /// Volume for a single exercise's sets.
    static func exerciseVolume(sets: [SetLog]) -> Double {
        sets.reduce(0) { $0 + $1.weight * floor($1.reps) }
    }

    /// Effective volume — weights sets by rep range relevance to goal.
    /// Hypertrophy: 6-15 reps = 1.0x, 1-5 reps = 0.7x, 16+ reps = 0.5x
    /// Strength: 1-5 reps = 1.0x, 6-10 reps = 0.7x, 11+ reps = 0.4x
    static func effectiveSetCount(sets: [SetLog], goal: TrainingGoal) -> Double {
        sets.filter { !$0.isWarmup }.reduce(0.0) { total, set in
            let reps = Int(floor(set.reps))
            let multiplier: Double
            switch goal {
            case .hypertrophy, .recomposition, .generalFitness:
                if reps >= 6 && reps <= 15 { multiplier = 1.0 }
                else if reps >= 1 && reps <= 5 { multiplier = 0.7 }
                else { multiplier = 0.5 }
            case .strength:
                if reps >= 1 && reps <= 5 { multiplier = 1.0 }
                else if reps >= 6 && reps <= 10 { multiplier = 0.7 }
                else { multiplier = 0.4 }
            }
            return total + multiplier
        }
    }

    // MARK: - Top Set

    /// Returns the heaviest working set (by weight, then reps as tiebreaker).
    static func topSet(sets: [SetLog]) -> SetLog? {
        sets.filter { !$0.isWarmup }
            .max { a, b in
                if a.weight != b.weight { return a.weight < b.weight }
                return a.reps < b.reps
            }
    }

    // MARK: - Weekly Set Count per Muscle Group

    /// Counts working sets for a given muscle group across sessions in a time window.
    static func weeklySetCount(
        sessions: [WorkoutSession],
        muscleGroup: MuscleGroup,
        exerciseLookup: [String: MuscleGroup]
    ) -> Int {
        var count = 0
        for session in sessions {
            for entry in session.entries {
                if exerciseLookup[entry.exerciseName] == muscleGroup {
                    count += entry.sets.filter { !$0.isWarmup }.count
                }
            }
        }
        return count
    }

    // MARK: - e1RM Trend

    /// Returns best e1RM per session for a given exercise, sorted by date.
    static func e1RMTrend(
        sessions: [WorkoutSession],
        exerciseName: String
    ) -> [(date: Date, e1RM: Double)] {
        sessions.compactMap { session in
            guard let entry = session.entries.first(where: { $0.exerciseName == exerciseName }) else {
                return nil
            }
            guard let top = topSet(sets: entry.sets) else { return nil }
            let e1rm = estimatedOneRepMax(weight: top.weight, reps: top.reps)
            return (date: session.date, e1RM: e1rm)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - PR Detection

    /// Checks if the given set is a PR compared to historical data.
    static func isPR(
        exerciseName: String,
        weight: Double,
        reps: Double,
        historicalSessions: [WorkoutSession]
    ) -> Bool {
        let currentE1RM = estimatedOneRepMax(weight: weight, reps: reps)

        for session in historicalSessions {
            for entry in session.entries where entry.exerciseName == exerciseName {
                for set in entry.sets where !set.isWarmup {
                    let historicalE1RM = estimatedOneRepMax(weight: set.weight, reps: set.reps)
                    if historicalE1RM >= currentE1RM {
                        return false
                    }
                }
            }
        }
        return !historicalSessions.isEmpty
    }

    // MARK: - Relative Intensity

    /// Compares set weight to estimated 1RM to infer intensity (proxy for RPE).
    /// Returns a value from 0 to 1 where 1.0 = at or above e1RM.
    static func relativeIntensity(weight: Double, estimatedMax: Double) -> Double {
        guard estimatedMax > 0 else { return 0 }
        return min(weight / estimatedMax, 1.0)
    }

    // MARK: - Weight Formatting

    static func formatWeight(_ weight: Double, unit: WeightUnit) -> String {
        weight.formattedWeight(unit: unit)
    }
}
