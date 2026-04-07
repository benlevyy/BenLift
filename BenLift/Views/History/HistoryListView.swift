import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Workouts Yet",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Start your first session from the Today tab.")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                sessionRow(session)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !sessions.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
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
            .alert("Clear All History?", isPresented: $showClearConfirm) {
                Button("Delete All", role: .destructive) {
                    clearAllHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all \(sessions.count) workout sessions and their AI analyses.")
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
        // Delete associated analysis
        let sessionId = session.id
        let analysisDescriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let analyses = try? modelContext.fetch(analysisDescriptor) {
            for analysis in analyses { modelContext.delete(analysis) }
        }
        // Delete child objects explicitly in case cascade doesn't fire
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

    // MARK: - Row

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack(spacing: 12) {
            Text(String(session.category.displayName.prefix(1)))
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(session.category.color)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.shortFormatted)
                    .font(.body)

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
}
