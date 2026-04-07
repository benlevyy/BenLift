import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

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
                    List(sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            sessionRow(session)
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack(spacing: 12) {
            // Category badge
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

            // Rating badge (from analysis if available)
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
