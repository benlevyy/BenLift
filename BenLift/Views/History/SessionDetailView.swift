import SwiftUI
import SwiftData
import Charts

struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let session: WorkoutSession
    @State private var analysis: PostWorkoutAnalysis?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Coach note
                if let analysis {
                    coachSection(analysis)
                }

                // PR badges
                if let analysis, !analysis.progressionEvents.isEmpty {
                    prSection(analysis.progressionEvents)
                }

                // Exercises
                exercisesSection

                // Pre-workout notes
                if session.feeling != nil || session.concerns != nil {
                    preWorkoutSection
                }
            }
            .padding()
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadAnalysis() }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.shortFormatted)
                    .font(.headline)
                HStack(spacing: 12) {
                    if let duration = session.duration {
                        Label(TimeInterval(duration).formattedDuration, systemImage: "clock")
                    }
                    Label("\(Int(session.totalVolume)) lbs", systemImage: "scalemass")
                }
                .font(.subheadline)
                .foregroundColor(.secondaryText)
            }

            Spacer()

            if let analysis {
                Text(analysis.overallRating.displayName)
                    .font(.headline)
                    .foregroundColor(analysis.overallRating.color)
            }
        }
    }

    private func coachSection(_ analysis: PostWorkoutAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coach Notes")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            Text(analysis.coachNote)
                .font(.body)

            if let recovery = analysis.recoveryNotes {
                Text(recovery)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .italic()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func prSection(_ events: [ProgressionEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(events) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.type.contains("pr") ? "star.fill" : "arrow.right")
                        .foregroundColor(event.type.contains("pr") ? .prGreen : .secondaryText)
                    VStack(alignment: .leading) {
                        Text("\(event.exercise) — \(event.type.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(.subheadline.bold())
                        Text(event.detail)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }
            }
        }
        .padding()
        .background(Color.prGreen.opacity(0.1))
        .cornerRadius(12)
    }

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exercises")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            ForEach(session.sortedEntries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.exerciseName)
                        .font(.body.bold())

                    ForEach(entry.sortedSets) { set in
                        HStack {
                            Text("Set \(set.setNumber)")
                                .font(.caption)
                                .foregroundColor(.secondaryText)
                                .frame(width: 50, alignment: .leading)

                            Text("\(Int(set.weight)) x \(set.reps.formattedReps)")
                                .font(.body.monospacedDigit())
                                .foregroundColor(set.isFailed ? .failedRed : .primary)

                            if set.isWarmup {
                                Text("warm-up")
                                    .font(.caption2)
                                    .foregroundColor(.secondaryText)
                            }

                            Spacer()
                        }
                    }

                    Text("Volume: \(Int(entry.totalVolume)) lbs")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
                .padding()
                .background(Color.cardSurface)
                .cornerRadius(8)
            }
        }
    }

    private var preWorkoutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pre-Workout")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if let feeling = session.feeling {
                Text("Feeling: \(feeling)/5")
                    .font(.caption)
            }
            if let concerns = session.concerns, !concerns.isEmpty {
                Text("Concerns: \(concerns)")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(8)
    }

    private func loadAnalysis() {
        let sessionId = session.id
        let descriptor = FetchDescriptor<PostWorkoutAnalysis>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        analysis = try? modelContext.fetch(descriptor).first
    }
}
