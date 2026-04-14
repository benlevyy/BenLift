import Foundation
import SwiftData

struct ContextBuilder {

    // MARK: - Daily Plan Context

    @MainActor
    static func buildDailyPlanContext(
        category: WorkoutCategory? = nil,
        targetMuscleGroups: [MuscleGroup] = [],
        sessionName: String? = nil,
        feeling: Int,
        availableTime: Int?,
        concerns: String?,
        modelContext: ModelContext,
        program: TrainingProgram?,
        healthContext: HealthContext? = nil
    ) -> (system: String, user: String) {
        // Today's focus muscle groups — used as GUIDANCE, not as a filter.
        // The AI sees the full library and picks the most efficient session for the focus.
        let focusMuscleGroups: [MuscleGroup]
        if !targetMuscleGroups.isEmpty {
            focusMuscleGroups = targetMuscleGroups
        } else if let cat = category {
            focusMuscleGroups = cat.muscleGroups
        } else {
            focusMuscleGroups = []  // No focus → AI picks freely from full library + weekly volume
        }

        // Full exercise library, grouped by primary muscle for token-efficient formatting.
        // The AI may select ANY exercise — many compounds efficiently cover multiple muscles
        // (bench → chest+triceps+front delts; weighted dips → chest+triceps; pull-ups → back+biceps).
        let allExercises = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        let library = exerciseLibraryGrouped(allExercises)

        // Summarize recent sessions
        let recentSummary: String
        if let cat = category {
            recentSummary = summarizeRecentSessions(category: cat, limit: 3, modelContext: modelContext)
        } else {
            recentSummary = summarizeAllRecentSessions(limit: 5, modelContext: modelContext)
        }

        // Weekly volume progress
        let volumeProgress = weeklyVolumeProgress(modelContext: modelContext, exerciseLookup: DefaultExercises.buildMuscleGroupLookup(from: modelContext))

        // Load intelligence for prompt context
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        let intelligence = try? modelContext.fetch(intelDescriptor).first

        var system = PromptBuilder.sharedSystemPrefix(program: program, healthContext: healthContext, intelligence: intelligence)
        system += """

        EXERCISE SELECTION PRINCIPLES:
        - You have access to the full exercise library — do NOT limit yourself to exercises tagged with the focus muscle groups. The "primary muscle" tag is a single-label simplification.
        - Most compounds efficiently train multiple muscles. Bench press hits chest + triceps + front delts; weighted dips hit chest + triceps; pull-ups hit back + biceps; RDLs hit hamstrings + glutes + lower back; OHP hits shoulders + triceps. Use these to cover under-trained muscles incidentally.
        - Prioritize stimulus-to-fatigue ratio: prefer one heavy compound that covers two muscle groups over two isolation exercises. Add isolation only when a muscle needs targeted volume that compounds don't provide (e.g., biceps after a pressing focus, rear delts after vertical pulls).
        - Cross-reference today's focus against weekly volume progress. If a non-focus muscle is severely under-volume for the week, weave in an exercise that hits it as a secondary mover.
        - Avoid redundancy: don't program two exercises that hit the exact same primary mover with the same equipment unless one is heavy/low-rep and the other is light/high-rep.

        Respond with this JSON schema:
        {"exercises":[{"name":"string","sets":int,"targetReps":"string","suggestedWeight":double_or_null,"repScheme":"string?","warmupSets":[{"weight":double_or_null,"reps":int}]?,"notes":"string?","intent":"primary compound|secondary compound|isolation|finisher"}],"sessionStrategy":"string","estimatedDuration":int,"deloadNote":"string?"}

        IMPORTANT: For bodyweight exercises, set suggestedWeight to null or 0. Exercise name MUST exactly match a name from the library below.
        """

        let focusDesc: String
        if let sessionName, !sessionName.isEmpty {
            focusDesc = sessionName
        } else if !focusMuscleGroups.isEmpty {
            focusDesc = focusMuscleGroups.map(\.displayName).joined(separator: " + ")
        } else {
            focusDesc = "AI's choice (no fixed focus — optimize for weekly volume gaps and recovery)"
        }

        var user = """
        Generate today's workout plan.
        Recommended focus (guidance, not a hard filter): \(focusDesc)

        Pre-workout check-in:
        - Feeling: \(feeling)/5
        """
        if let time = availableTime {
            user += "\n- Available time: \(time) minutes"
        }
        if let concerns = concerns, !concerns.isEmpty {
            user += "\n- Concerns: \(concerns)"
        }

        user += "\n\nFull exercise library (grouped by primary muscle — pick from any group):\n\(library)"
        user += "\n\nRecent sessions:\n\(recentSummary)"
        user += "\n\nWeekly volume progress (use this to decide which non-focus muscles need incidental work):\n\(volumeProgress)"

        return (system, user)
    }

    /// Format the full exercise library grouped by primary muscle. Far fewer tokens
    /// than tagging each exercise individually, and gives the AI a clear mental map.
    private static func exerciseLibraryGrouped(_ exercises: [Exercise]) -> String {
        let byGroup = Dictionary(grouping: exercises, by: \.muscleGroup)
        return MuscleGroup.allCases.compactMap { group -> String? in
            guard let items = byGroup[group], !items.isEmpty else { return nil }
            let names = items.map { ex -> String in
                ex.equipment == .bodyweight ? "\(ex.name) (BW)" : ex.name
            }.joined(separator: ", ")
            return "\(group.displayName): \(names)"
        }.joined(separator: "\n")
    }

    // MARK: - Summarize All Recent Sessions (for recommendation)

    @MainActor
    static func summarizeAllRecentSessions(limit: Int, modelContext: ModelContext) -> String {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let sessions = try? modelContext.fetch(descriptor), !sessions.isEmpty else {
            return "No recent sessions."
        }

        return sessions.map { session in
            let muscleList = session.muscleGroups.isEmpty
                ? (session.category?.displayName ?? "Unknown")
                : session.muscleGroups.map(\.displayName).joined(separator: ", ")
            let setCount = session.entries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
            return "\(session.date.shortFormatted): \(session.displayName) (\(muscleList)) — \(setCount) working sets, \(Int(session.totalVolume)) lbs"
        }.joined(separator: "\n")
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
        let recentSummary: String
        if let cat = session.category {
            recentSummary = summarizeRecentSessions(category: cat, limit: 5, modelContext: modelContext)
        } else {
            recentSummary = "No category-specific history (dynamic session)"
        }

        // Load pending observations from intelligence
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        let pendingObservations = (try? modelContext.fetch(intelDescriptor).first)?.pendingObservations

        return PromptBuilder.postWorkoutAnalysisPrompt(
            planSummary: planSummary,
            actualWorkout: actualWorkout,
            recentSessionsSummary: recentSummary,
            program: program,
            healthContext: healthContext,
            pendingObservations: pendingObservations
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
            predicate: #Predicate<WorkoutSession> { session in session.category == category },
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
                let topWeightStr = top.weight == 0 ? "BW" : "\(Int(top.weight)) lbs"
                summary += "  \(entry.exerciseName): top set \(topWeightStr) x \(top.reps.formattedReps), e1RM: \(Int(e1rm))\n"
            }
            summary += "  Total volume: \(Int(session.totalVolume)) lbs"
            return summary
        }.joined(separator: "\n")
    }

    @MainActor
    static func weeklyVolumeProgress(modelContext: ModelContext, exerciseLookup: [String: MuscleGroup]) -> String {
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
        var result = "\(session.displayName) - \(session.date.shortFormatted)"
        if let feeling = session.feeling { result += " (feeling: \(feeling)/5)" }
        result += "\n"
        for entry in session.sortedEntries {
            result += "  \(entry.exerciseName):\n"
            for set in entry.sortedSets {
                let warmup = set.isWarmup ? " (warmup)" : ""
                let weightStr = set.weight == 0 ? "BW" : "\(Int(set.weight)) lbs"
                result += "    Set \(set.setNumber): \(weightStr) x \(set.reps.formattedReps)\(warmup)\n"
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
