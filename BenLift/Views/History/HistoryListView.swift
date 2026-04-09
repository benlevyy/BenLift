import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showClearConfirm = false
    @State private var showManualEntry = false
    @State private var activities: [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)] = []

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
        var items: [TimelineItem] = sessions.map { .workout($0) }
        for (i, act) in activities.enumerated() {
            items.append(.activity(index: i, type: act.type, date: act.date, duration: act.duration, calories: act.calories, source: act.source))
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
        HStack(spacing: 12) {
            Text(String(session.displayName.prefix(1)))
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(session.category?.color ?? .accentBlue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.body.bold())
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

                    Text("\(session.entries.count) exercises")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
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
