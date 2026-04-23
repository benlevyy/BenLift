import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showClearConfirm = false
    @State private var showManualEntry = false
    @State private var activities: [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)] = []
    /// Search query — filters the timeline to sessions containing any
    /// exercise whose name matches (case-insensitive contains). Empty
    /// string = show everything, including HealthKit activities.
    @State private var searchText: String = ""

    // Unified timeline item
    private enum TimelineItem: Identifiable {
        case workout(WorkoutSession)
        case activity(index: Int, type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)

        var id: String {
            switch self {
            case .workout(let s): return s.id.uuidString
            case .activity(let i, _, let d, _, _, _): return "act-\(i)-\(d.timeIntervalSince1970)"
            }
        }

        var date: Date {
            switch self {
            case .workout(let s): return s.date
            case .activity(_, _, let d, _, _, _): return d
            }
        }
    }

    private var timeline: [TimelineItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filterActive = !query.isEmpty

        // Sessions: when searching, only include ones with a matching
        // exercise entry. Case-insensitive `contains` so "bench" hits
        // "Bench Press" and "Close Grip Bench."
        let filteredSessions: [WorkoutSession] = filterActive
            ? sessions.filter { session in
                session.entries.contains {
                    $0.exerciseName.localizedCaseInsensitiveContains(query)
                }
            }
            : sessions

        var items: [TimelineItem] = filteredSessions.map { .workout($0) }

        // HealthKit activities — no exercise names to match against, so
        // they drop out entirely when a query is active. Keeps the
        // search-result list focused on lifts.
        if !filterActive {
            for (i, act) in activities.enumerated() {
                items.append(.activity(index: i, type: act.type, date: act.date, duration: act.duration, calories: act.calories, source: act.source))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty && activities.isEmpty {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Start your first session from the Today tab.")
                    )
                } else if timeline.isEmpty {
                    // Non-empty history overall but the current search
                    // returned no sessions. Distinct from "no history yet"
                    // so the user knows the issue is the query, not an
                    // empty log.
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(timeline) { item in
                            switch item {
                            case .workout(let session):
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    sessionRow(session)
                                }
                            case .activity(_, let type, let date, let duration, let calories, let source):
                                activityRow(type: type, date: date, duration: duration, calories: calories, source: source)
                            }
                        }
                        .onDelete { offsets in
                            // Only delete workout sessions, not HealthKit activities
                            let items = timeline
                            for offset in offsets {
                                if case .workout(let session) = items[offset] {
                                    deleteSession(session)
                                }
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("History")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search exercises (e.g. bench)"
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            showManualEntry = true
                        } label: {
                            Image(systemName: "plus")
                        }

                        if !sessions.isEmpty {
                            Menu {
                                Button(role: .destructive) {
                                    showClearConfirm = true
                                } label: {
                                    Label("Clear All History", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualWorkoutEntryView()
            }
            .alert("Clear All History?", isPresented: $showClearConfirm) {
                Button("Delete All", role: .destructive) {
                    clearAllHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all \(sessions.count) workout sessions and their AI analyses. HealthKit activities will remain.")
            }
            .onAppear { loadActivities() }
        }
    }

    // MARK: - Activity Row

    private func activityRow(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: activityIcon(type))
                .font(.body)
                .foregroundColor(.accentBlue)
                .frame(width: 32, height: 32)
                .background(Color.accentBlue.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(type.capitalized)
                    .font(.body.bold())
                Text(date.shortFormatted)
                    .font(.caption)
                    .foregroundColor(.secondaryText)

                HStack(spacing: 8) {
                    Text(duration.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                    if let cal = calories {
                        Text("\(Int(cal)) cal")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    Text(source)
                        .font(.caption2)
                        .foregroundColor(.secondaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cardSurface)
                        .cornerRadius(3)
                }
            }

            Spacer()

            // Label to distinguish from workouts
            Text("Activity")
                .font(.caption2)
                .foregroundColor(.accentBlue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentBlue.opacity(0.1))
                .cornerRadius(4)
        }
    }

    // MARK: - Workout Row

    private func sessionRow(_ session: WorkoutSession) -> some View {
        // Precompute counts used in the meta row — skipped entries get a
        // separate visible pill so "3 exercises" isn't secretly "2 done,
        // 1 bailed." Logged = has sets; skipped = explicit skip.
        let loggedCount = session.entries.filter { !$0.sets.isEmpty }.count
        let skippedCount = session.entries.filter { $0.isSkipped }.count

        return HStack(spacing: 12) {
            Text(String(session.displayName.prefix(1)))
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(session.category?.color ?? .accentBlue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.body.bold())
                    // AI-planned badge — subtle sparkle next to the title
                    // so a glance tells you whether the AI built it or
                    // it was a manual session.
                    if session.aiPlanUsed {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundColor(.accentBlue)
                    }
                }
                Text(session.date.shortFormatted)
                    .font(.caption)
                    .foregroundColor(.secondaryText)

                HStack(spacing: 8) {
                    if let duration = session.duration {
                        Text(TimeInterval(duration).formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }

                    Text("\(Int(session.totalVolume)) lbs")
                        .font(.caption)
                        .foregroundColor(.secondaryText)

                    // Exercise counts: "3 logged" solo, or "3 logged · 1
                    // skipped" when the user bailed on something. Dropping
                    // the old generic "N exercises" — it hid the skips.
                    if skippedCount > 0 {
                        Text("\(loggedCount) logged · \(skippedCount) skipped")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    } else {
                        Text("\(loggedCount) exercise\(loggedCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }
            }

            Spacer()

            ratingBadge(for: session)
        }
    }

    private func ratingBadge(for session: WorkoutSession) -> some View {
        let sessionId = session.id
        let descriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let analysis = try? modelContext.fetch(descriptor).first

        return Group {
            if let analysis {
                Text(analysis.overallRating.displayName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(analysis.overallRating.color.opacity(0.2))
                    .foregroundColor(analysis.overallRating.color)
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Delete

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            deleteSession(sessions[index])
        }
        try? modelContext.save()
    }

    private func deleteSession(_ session: WorkoutSession) {
        let sessionId = session.id
        let analysisDescriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let analyses = try? modelContext.fetch(analysisDescriptor) {
            for analysis in analyses { modelContext.delete(analysis) }
        }
        for entry in session.entries {
            for set in entry.sets { modelContext.delete(set) }
            modelContext.delete(entry)
        }
        modelContext.delete(session)
    }

    private func clearAllHistory() {
        for session in sessions {
            deleteSession(session)
        }
        try? modelContext.save()
        print("[BenLift] Cleared all workout history")
    }

    // MARK: - Activities

    private func loadActivities() {
        Task {
            activities = await HealthKitService.shared.fetchRecentActivities(days: 30)
        }
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "climbing": return "figure.climbing"
        case "running": return "figure.run"
        case "cycling": return "figure.outdoor.cycle"
        case "swimming": return "figure.pool.swim"
        case "yoga": return "figure.yoga"
        case "hiking": return "figure.hiking"
        case "hiit": return "figure.highintensity.intervaltraining"
        default: return "figure.mixed.cardio"
        }
    }
}
