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

    /// Clears pending observations on every UserIntelligence record in the
    /// context (handles the case where multiple records exist from prior
    /// testing) and refreshes the VM's reference so @Observable fires.
    @MainActor
    func clearPendingObservations(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<UserIntelligence>()
        guard let all = try? modelContext.fetch(descriptor), !all.isEmpty else { return }
        for intel in all {
            intel.pendingObservations = ""
        }
        try? modelContext.save()
        // Reassign so SwiftUI views bound to `intelligence` on the VM re-read.
        intelligence = all.first
        print("[BenLift/Intel] Cleared pending observations on \(all.count) record(s)")
    }

    /// Wipe the AI-generated sections on every UserIntelligence record
    /// AND archive every active UserObservation row. Preserves
    /// user-provided fields (`injuries` / `userNotes`) and UserRules —
    /// those are durable decisions, not AI output. Use this to recover
    /// from test workouts that polluted the profile; the next refresh
    /// rebuilds observations from whatever sessions remain in SwiftData.
    @MainActor
    func resetIntelligence(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<UserIntelligence>()
        guard let all = try? modelContext.fetch(descriptor), !all.isEmpty else { return }
        for intel in all {
            intel.activityPatterns = ""
            intel.trainingPatterns = ""
            intel.strengthProfile = ""
            intel.recoveryProfile = ""
            intel.exercisePreferences = ""
            intel.notableObservations = ""
            intel.pendingObservations = ""
            intel.workoutsSinceRefresh = 0
            intel.lastRefreshed = .distantPast
        }

        // Archive all active observations so the UI (and the prompt
        // payload) actually reflects the reset. Soft-archive keeps
        // history debuggable.
        let obsDescriptor = FetchDescriptor<UserObservation>(
            predicate: #Predicate { $0.isActive == true }
        )
        let archivedCount = (try? modelContext.fetch(obsDescriptor).reduce(into: 0) { count, obs in
            obs.isActive = false
            count += 1
        }) ?? 0

        try? modelContext.save()
        intelligence = all.first
        print("[BenLift/Intel] Reset intelligence on \(all.count) record(s), archived \(archivedCount) observation(s) — user input + rules preserved")
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

        let sessionsSummary = formatSessionsForIntelligence(limit: nil, modelContext: modelContext)
        let activitiesText = formatActivities(activities)
        let healthText = formatHealthAverages(healthAverages, current: healthContext)
        let behaviorText = formatBehaviorPatterns(modelContext: modelContext)

        // UserState snapshot — same compressed view every other prompt
        // gets. Refresh also consumes the raw `sessionsSummary` below as
        // its discovery supplement (Sonnet finds patterns aggregates
        // miss). checkIn has defaults because refresh isn't tied to a
        // specific user check-in.
        let userState = UserState.current(
            modelContext: modelContext,
            program: program,
            intelligence: intel,
            checkIn: UserState.CheckInInput(feeling: 3, availableTime: nil, concerns: ""),
            healthContext: healthContext,
            healthAverages: healthAverages,
            recentActivities: activities
        )

        // Pending observations are synthesized AI notes from prior plan
        // iterations — intentionally dropped from the refresh prompt so
        // the profile is rebuilt from source-of-truth data (sessions +
        // HK + SessionEvent behavior log), not the AI's own echoes.
        let (system, user) = PromptBuilder.refreshIntelligencePrompt(
            userState: userState,
            program: program,
            activitiesText: activitiesText,
            healthAverages: healthText,
            sessionsSummary: sessionsSummary,
            pendingObservations: "",
            injuries: intel.injuries,
            userNotes: intel.userNotes,
            behaviorPatterns: behaviorText
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

            // Mirror each structured field into a UserObservation row so
            // UserState.observations picks them up. Subject tags the
            // section so upsert dedupes correctly across refreshes
            // (e.g. "training" section always updates in-place).
            ObservationStore.archiveStale(modelContext: modelContext)
            let sections: [(ObservationKind, String, String)] = [
                (.pattern,     "activity",    response.activityPatterns),
                (.pattern,     "training",    response.trainingPatterns),
                (.programming, "strength",    response.strengthProfile),
                (.recovery,    "recovery",    response.recoveryProfile),
                (.programming, "preferences", response.exercisePreferences),
                (.correlation, "notable",     response.notableObservations),
            ]
            for (kind, subject, text) in sections {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.lowercased() != "insufficient data" else { continue }
                ObservationStore.upsert(
                    kind: kind,
                    subject: subject,
                    text: trimmed,
                    confidence: .high,
                    modelContext: modelContext
                )
            }

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
    private func formatSessionsForIntelligence(limit: Int?, modelContext: ModelContext) -> String {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }

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

            // Top sets per exercise — plus an explicit "SKIPPED" line for
            // bailed entries. Without this, skipped entries dropped
            // silently from the refresh summary (topSet returns nil on an
            // empty sets array) so the AI couldn't see bail patterns.
            for entry in session.sortedEntries {
                if entry.isSkipped {
                    line += "\n  \(entry.exerciseName): SKIPPED"
                } else if let top = StatsEngine.topSet(sets: entry.sets) {
                    let e1rm = StatsEngine.estimatedOneRepMax(weight: top.weight, reps: top.reps)
                    line += "\n  \(entry.exerciseName): \(Int(top.weight))x\(top.reps.formattedReps) (e1RM ~\(Int(e1rm)))"
                }
            }

            let setCount = session.entries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
            line += "\n  \(setCount) working sets, \(Int(session.totalVolume)) lbs total"

            return line
        }.joined(separator: "\n\n")
    }

    /// Summarize the last 30 days of SessionEvent activity into top
    /// swap/skip/add exercises with counts. Fed into the refresh prompt so
    /// the AI sees mid-workout behavior, not just logged sets.
    ///
    /// Format: "Swapped: Bench Press 4×, DB Incline 2×. Skipped: Split
    /// Squat 3×. Added mid-workout: Pallof Press 2×." Empty string when
    /// the user hasn't done anything adapty — caller skips the block.
    @MainActor
    private func formatBehaviorPatterns(modelContext: ModelContext) -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<SessionEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let events = try? modelContext.fetch(descriptor), !events.isEmpty else {
            return ""
        }

        var swaps: [String: Int] = [:]
        var skips: [String: Int] = [:]
        var adds: [String: Int] = [:]
        for event in events {
            guard let name = event.exerciseName else { continue }
            switch event.kind {
            case .swap: swaps[name, default: 0] += 1
            case .skip: skips[name, default: 0] += 1
            case .addExercise: adds[name, default: 0] += 1
            default: break
            }
        }

        // Top 5 per category — keep the prompt scannable.
        func topN(_ dict: [String: Int], limit: Int = 5) -> String {
            dict
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit)
                .map { "\($0.key) \($0.value)×" }
                .joined(separator: ", ")
        }

        var parts: [String] = []
        if !swaps.isEmpty { parts.append("Swapped out: \(topN(swaps)).") }
        if !skips.isEmpty { parts.append("Skipped: \(topN(skips)).") }
        if !adds.isEmpty { parts.append("Added mid-workout: \(topN(adds)).") }
        return parts.joined(separator: " ")
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
