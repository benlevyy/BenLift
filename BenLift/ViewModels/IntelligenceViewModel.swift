import SwiftUI
import SwiftData

@Observable
class IntelligenceViewModel {
    var intelligence: UserIntelligence?
    var isRefreshing = false
    var refreshError: String?

    private let coachService: CoachServiceProtocol

    init(coachService: CoachServiceProtocol? = nil) {
        self.coachService = coachService ?? ClaudeCoachService()
    }

    @MainActor
    func loadIntelligence(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<UserIntelligence>()
        intelligence = try? modelContext.fetch(descriptor).first
    }

    @MainActor
    func ensureIntelligenceExists(modelContext: ModelContext) -> UserIntelligence {
        if let existing = intelligence { return existing }
        let descriptor = FetchDescriptor<UserIntelligence>()
        if let existing = try? modelContext.fetch(descriptor).first {
            intelligence = existing
            return existing
        }
        let new = UserIntelligence()
        modelContext.insert(new)
        try? modelContext.save()
        intelligence = new
        return new
    }

    @MainActor
    func refreshIntelligence(
        modelContext: ModelContext,
        program: TrainingProgram?
    ) async {
        isRefreshing = true
        refreshError = nil

        let intel = ensureIntelligenceExists(modelContext: modelContext)

        // Gather data
        let activities = await HealthKitService.shared.fetchRecentActivities(days: 30)
        let healthAverages = await HealthKitService.shared.fetchHealthAverages(days: 30)
        let healthContext = await HealthKitService.shared.fetchHealthContext()

        let sessionsSummary = formatSessionsForIntelligence(limit: 20, modelContext: modelContext)
        let activitiesText = formatActivities(activities)
        let healthText = formatHealthAverages(healthAverages, current: healthContext)

        let (system, user) = PromptBuilder.refreshIntelligencePrompt(
            program: program,
            activitiesText: activitiesText,
            healthAverages: healthText,
            sessionsSummary: sessionsSummary,
            pendingObservations: intel.pendingObservations
        )

        let model = "claude-sonnet-4-5"
        print("[BenLift/Intel] Refreshing intelligence with model=\(model)")

        do {
            let response = try await coachService.refreshIntelligence(
                systemPrompt: system, userPrompt: user, model: model
            )

            intel.activityPatterns = response.activityPatterns
            intel.trainingPatterns = response.trainingPatterns
            intel.strengthProfile = response.strengthProfile
            intel.recoveryProfile = response.recoveryProfile
            intel.exercisePreferences = response.exercisePreferences
            intel.notableObservations = response.notableObservations
            intel.pendingObservations = ""
            intel.workoutsSinceRefresh = 0
            intel.lastRefreshed = Date()

            try? modelContext.save()
            intelligence = intel
            print("[BenLift/Intel] ✅ Intelligence refreshed successfully")
        } catch {
            refreshError = error.localizedDescription
            print("[BenLift/Intel] ❌ Refresh failed: \(error)")
        }

        isRefreshing = false
    }

    // MARK: - Data Formatting

    @MainActor
    private func formatSessionsForIntelligence(limit: Int, modelContext: ModelContext) -> String {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let sessions = try? modelContext.fetch(descriptor), !sessions.isEmpty else {
            return "No training sessions recorded."
        }

        return sessions.map { session in
            let muscleList = session.muscleGroups.isEmpty
                ? (session.category?.displayName ?? "Unknown")
                : session.muscleGroups.map(\.displayName).joined(separator: ", ")

            var line = "\(session.date.shortFormatted) (\(session.date.weekdayName)): \(session.displayName) (\(muscleList))"
            if let feeling = session.feeling { line += " — feeling \(feeling)/5" }
            if let duration = session.duration, duration > 0 { line += ", \(Int(duration))min" }

            // Top sets per exercise
            for entry in session.sortedEntries {
                if let top = StatsEngine.topSet(sets: entry.sets) {
                    let e1rm = StatsEngine.estimatedOneRepMax(weight: top.weight, reps: top.reps)
                    line += "\n  \(entry.exerciseName): \(Int(top.weight))x\(top.reps.formattedReps) (e1RM ~\(Int(e1rm)))"
                }
            }

            let setCount = session.entries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
            line += "\n  \(setCount) working sets, \(Int(session.totalVolume)) lbs total"

            return line
        }.joined(separator: "\n\n")
    }

    private func formatActivities(_ activities: [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)]) -> String {
        guard !activities.isEmpty else { return "" }
        return activities.map { act in
            let dur = TimeInterval(act.duration).formattedDuration
            let cal = act.calories.map { ", \(Int($0)) cal" } ?? ""
            return "\(act.date.shortFormatted) (\(act.date.weekdayName)): \(act.type), \(dur)\(cal) (\(act.source))"
        }.joined(separator: "\n")
    }

    private func formatHealthAverages(_ averages: HealthKitService.HealthAverages, current: HealthContext) -> String {
        var lines: [String] = []

        if let sleep = averages.avgSleep {
            lines.append("Avg sleep: \(String(format: "%.1f", sleep.average))h (trend: \(sleep.trend))")
        }
        if let rhr = averages.avgRHR {
            lines.append("Avg RHR: \(Int(rhr.average)) bpm (trend: \(rhr.trend))")
        }
        if let hrv = averages.avgHRV {
            lines.append("Avg HRV: \(Int(hrv.average)) ms (trend: \(hrv.trend))")
        }
        if let weight = current.bodyWeight {
            lines.append("Current weight: \(Int(weight)) lbs")
        }
        if let vo2 = current.vo2Max {
            lines.append("VO2max: \(String(format: "%.1f", vo2)) mL/min/kg")
        }

        return lines.joined(separator: "\n")
    }
}
