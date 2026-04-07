import Foundation
import SwiftData

struct ContextBuilder {

    // MARK: - Daily Plan Context

    @MainActor
    static func buildDailyPlanContext(
        category: WorkoutCategory,
        feeling: Int,
        availableTime: Int,
        concerns: String?,
        modelContext: ModelContext,
        program: TrainingProgram?,
        healthContext: HealthContext? = nil
    ) -> (system: String, user: String) {
        // Fetch available exercises for this category
        let allExercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let categoryExercises = allExercises.filter { category.muscleGroups.contains($0.muscleGroup) }
        let exerciseNames = categoryExercises.map(\.name)

        // Fetch last 3 sessions for this category
        let recentSummary = summarizeRecentSessions(category: category, limit: 3, modelContext: modelContext)

        // Weekly volume progress
        let volumeProgress = weeklyVolumeProgress(modelContext: modelContext, exerciseLookup: DefaultExercises.buildMuscleGroupLookup(from: modelContext))

        // Build system prompt with health context included
        var system = PromptBuilder.sharedSystemPrefix(program: program, healthContext: healthContext)
        system += """

        Respond with this JSON schema:
        {"exercises":[{"name":"string","sets":int,"targetReps":"string","suggestedWeight":double,"repScheme":"string?","warmupSets":[{"weight":double,"reps":int}]?,"notes":"string?","intent":"primary compound|secondary compound|isolation|finisher"}],"sessionStrategy":"string","estimatedDuration":int,"deloadNote":"string?"}
        """

        var user = """
        Generate today's \(category.displayName) workout plan.

        Pre-workout check-in:
        - Feeling: \(feeling)/5
        - Available time: \(availableTime) minutes
        """
        if let concerns = concerns, !concerns.isEmpty {
            user += "\n- Concerns: \(concerns)"
        }

        user += "\n\nAvailable exercises: \(exerciseNames.joined(separator: ", "))"
        user += "\n\nRecent sessions:\n\(recentSummary)"
        user += "\n\nWeekly volume progress:\n\(volumeProgress)"

        return (system, user)
    }

    // MARK: - Post-Workout Context

    @MainActor
    static func buildPostWorkoutContext(
        session: WorkoutSession,
        planSummary: String?,
        modelContext: ModelContext,
        program: TrainingProgram?,
        healthContext: HealthContext?
    ) -> (system: String, user: String) {
        let actualWorkout = formatSession(session)
        let recentSummary = summarizeRecentSessions(category: session.category, limit: 5, modelContext: modelContext)

        return PromptBuilder.postWorkoutAnalysisPrompt(
            planSummary: planSummary,
            actualWorkout: actualWorkout,
            recentSessionsSummary: recentSummary,
            program: program,
            healthContext: healthContext
        )
    }

    // MARK: - Weekly Review Context

    @MainActor
    static func buildWeeklyReviewContext(
        modelContext: ModelContext,
        program: TrainingProgram?,
        healthContext: HealthContext?
    ) -> (system: String, user: String) {
        let thisWeekSessions = fetchThisWeekSessions(modelContext: modelContext)
        let sessionsSummary = thisWeekSessions.map { formatSession($0) }.joined(separator: "\n---\n")
        let previousSummary = summarizePreviousWeeks(weeks: 4, modelContext: modelContext)

        return PromptBuilder.weeklyReviewPrompt(
            sessionsSummary: sessionsSummary,
            program: program,
            previousWeeksSummary: previousSummary,
            healthContext: healthContext
        )
    }

    // MARK: - Helpers

    @MainActor
    private static func summarizeRecentSessions(category: WorkoutCategory, limit: Int, modelContext: ModelContext) -> String {
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.category == category },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let sessions = try? modelContext.fetch(descriptor), !sessions.isEmpty else {
            return "No recent sessions for this category."
        }

        return sessions.enumerated().map { index, session in
            let daysAgo = Date().daysSince(session.date)
            var summary = "Session \(index + 1) (\(daysAgo) days ago):\n"
            for entry in session.sortedEntries {
                guard let top = StatsEngine.topSet(sets: entry.sets) else { continue }
                let e1rm = StatsEngine.estimatedOneRepMax(weight: top.weight, reps: top.reps)
                summary += "  \(entry.exerciseName): top set \(Int(top.weight))x\(top.reps.formattedReps), e1RM: \(Int(e1rm))\n"
            }
            summary += "  Total volume: \(Int(session.totalVolume)) lbs"
            return summary
        }.joined(separator: "\n")
    }

    @MainActor
    private static func weeklyVolumeProgress(modelContext: ModelContext, exerciseLookup: [String: MuscleGroup]) -> String {
        let weekStart = Date().startOfWeek
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= weekStart }
        )
        guard let sessions = try? modelContext.fetch(descriptor) else { return "No sessions this week." }

        var setsByGroup: [MuscleGroup: Int] = [:]
        for session in sessions {
            for entry in session.entries {
                if let group = exerciseLookup[entry.exerciseName] {
                    setsByGroup[group, default: 0] += entry.workingSets.count
                }
            }
        }

        if setsByGroup.isEmpty { return "No sessions this week yet." }

        return setsByGroup.map { "\($0.key.displayName): \($0.value) sets" }.joined(separator: ", ")
    }

    @MainActor
    private static func formatSession(_ session: WorkoutSession) -> String {
        var result = "\(session.category.displayName) - \(session.date.shortFormatted)"
        if let feeling = session.feeling { result += " (feeling: \(feeling)/5)" }
        result += "\n"
        for entry in session.sortedEntries {
            result += "  \(entry.exerciseName):\n"
            for set in entry.sortedSets {
                let warmup = set.isWarmup ? " (warmup)" : ""
                result += "    Set \(set.setNumber): \(Int(set.weight)) x \(set.reps.formattedReps)\(warmup)\n"
            }
        }
        return result
    }

    @MainActor
    private static func fetchThisWeekSessions(modelContext: ModelContext) -> [WorkoutSession] {
        let weekStart = Date().startOfWeek
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.date >= weekStart },
            sortBy: [SortDescriptor(\.date)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @MainActor
    private static func summarizePreviousWeeks(weeks: Int, modelContext: ModelContext) -> String {
        let calendar = Calendar.current
        var summaries: [String] = []

        for weekOffset in 1...weeks {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: Date().startOfWeek),
                  let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { continue }

            let descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.date >= weekStart && $0.date < weekEnd }
            )
            let sessions = (try? modelContext.fetch(descriptor)) ?? []
            if sessions.isEmpty { continue }

            let totalVolume = sessions.reduce(0.0) { $0 + $1.totalVolume }
            let avgFeeling = sessions.compactMap(\.feeling).isEmpty ? nil :
                Double(sessions.compactMap(\.feeling).reduce(0, +)) / Double(sessions.compactMap(\.feeling).count)

            var summary = "Week \(weekOffset) ago: \(sessions.count) sessions, \(Int(totalVolume)) lbs total"
            if let avg = avgFeeling { summary += ", avg feeling \(String(format: "%.1f", avg))" }
            summaries.append(summary)
        }

        return summaries.isEmpty ? "No previous data." : summaries.joined(separator: "\n")
    }
}
