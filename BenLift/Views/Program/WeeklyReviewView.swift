import SwiftUI
import SwiftData
import Charts

struct WeeklyReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WeeklyReview.weekStartDate, order: .reverse) private var reviews: [WeeklyReview]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let latest = reviews.first {
                    weekSummaryCard(latest)
                    coachNoteCard(latest)
                    volumeComplianceSection(latest)
                    strengthTrendsSection(latest)
                    adjustmentsSection(latest)
                }

                if reviews.isEmpty {
                    ContentUnavailableView(
                        "No Reviews Yet",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Weekly reviews are generated automatically after your training week.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Weekly Review")
    }

    private func weekSummaryCard(_ review: WeeklyReview) -> some View {
        HStack(spacing: 20) {
            statBadge(value: "\(review.sessionsCompleted)/\(review.sessionsPlanned)", label: "Sessions")
            statBadge(value: "\(Int(review.totalVolume))", label: "Volume (lbs)")
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func coachNoteCard(_ review: WeeklyReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coach Notes")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)
            Text(review.coachNote)
                .font(.body)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func volumeComplianceSection(_ review: WeeklyReview) -> some View {
        let compliance = review.volumeCompliance

        return VStack(alignment: .leading, spacing: 8) {
            Text("Volume Compliance")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if compliance.isEmpty {
                Text("No data")
                    .foregroundColor(.secondaryText)
            } else {
                Chart(compliance.sorted(by: { $0.key < $1.key }), id: \.key) { group, entry in
                    BarMark(
                        x: .value("Group", group.capitalized),
                        y: .value("Target", entry.target)
                    )
                    .foregroundStyle(Color.secondaryText.opacity(0.3))

                    BarMark(
                        x: .value("Group", group.capitalized),
                        y: .value("Actual", entry.actual)
                    )
                    .foregroundStyle(entry.actual >= entry.target ? Color.prGreen : Color.failedRed)
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func strengthTrendsSection(_ review: WeeklyReview) -> some View {
        let trends = review.strengthTrends

        return VStack(alignment: .leading, spacing: 8) {
            Text("Strength Trends")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            ForEach(trends) { trend in
                HStack {
                    Text(trend.exercise)
                        .font(.subheadline)
                    Spacer()
                    if let now = trend.e1rmNow {
                        Text("\(Int(now)) e1RM")
                            .font(.subheadline.monospacedDigit())
                    }
                    Image(systemName: trend.trend.contains("up") ? "arrow.up.right" : trend.trend.contains("down") ? "arrow.down.right" : "arrow.right")
                        .foregroundColor(trend.trend.contains("up") ? .prGreen : trend.trend.contains("down") ? .failedRed : .secondaryText)
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func adjustmentsSection(_ review: WeeklyReview) -> some View {
        let adjustments = review.programAdjustments

        return Group {
            if !adjustments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested Adjustments")
                        .font(.caption.bold())
                        .foregroundColor(.secondaryText)
                        .textCase(.uppercase)

                    ForEach(adjustments) { adjustment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(adjustment.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption.bold())
                                Spacer()
                                Text(adjustment.priority.uppercased())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(adjustment.priority == "high" ? Color.failedRed.opacity(0.2) : Color.secondaryText.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            Text(adjustment.detail)
                                .font(.subheadline)
                        }
                        .padding()
                        .background(Color.appBackground)
                        .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.cardSurface)
                .cornerRadius(12)
            }
        }
    }
}
