import SwiftUI
import SwiftData

/// Everything he actually does, in one place.
///
/// Replaces the old Training tab, which was muscle-status grids and volume
/// charts about lifting alone — a narrow view of someone who also climbs,
/// runs and bikes. Lifting comes from SwiftData; everything else is read
/// from HealthKit, because those sessions are already tracked by the apps
/// that recorded them and re-entering them here would be busywork.
///
/// Read-only by design. Nothing here feeds the plan resolver — it's context
/// for him, and for chat when he asks.
struct HubView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var programVM: ProgramViewModel

    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    @State private var activities: [CrossTrainingActivity] = []
    @State private var healthContext: HealthContext?
    @State private var vo2Max: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    thisWeekCard
                    if !activities.isEmpty { crossTrainingCard }
                    recoveryCard
                    if !recentLifts.isEmpty { liftingCard }
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("Hub")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        async let raw = HealthKitService.shared.fetchRecentActivities(days: 14)
        async let context = HealthKitService.shared.fetchHealthContext()
        async let vo2 = HealthKitService.shared.fetchVO2Max()

        // Parenthesised: `await raw.map { }` would try to call map on the
        // unresolved async-let binding rather than on its result.
        activities = (await raw).map {
            CrossTrainingActivity(type: $0.type, date: $0.date, duration: $0.duration, distanceMiles: nil)
        }
        healthContext = await context
        vo2Max = await vo2
    }

    // MARK: This week

    private var weekStart: Date { Date().startOfWeek }

    private var sessionsThisWeek: [WorkoutSession] {
        sessions.filter { $0.date >= weekStart }
    }

    private var activitiesThisWeek: [CrossTrainingActivity] {
        activities.filter { $0.date >= weekStart }
    }

    private var thisWeekCard: some View {
        card("THIS WEEK") {
            HStack(spacing: 0) {
                stat("\(sessionsThisWeek.count)", "lifts")
                divider
                stat("\(activitiesThisWeek.count)", "other")
                divider
                stat(hoursLabel, "hours")
                divider
                stat(volumeLabel, "lbs moved")
            }
        }
    }

    private var hoursLabel: String {
        let lifting = sessionsThisWeek.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let cross = activitiesThisWeek.reduce(0.0) { $0 + $1.duration }
        return String(format: "%.1f", (lifting + cross) / 3600)
    }

    private var volumeLabel: String {
        let total = sessionsThisWeek.reduce(0.0) { $0 + $1.totalVolume }
        return total >= 1000 ? String(format: "%.0fk", total / 1000) : "\(Int(total))"
    }

    // MARK: Cross-training

    private var crossTrainingCard: some View {
        card("EVERYTHING ELSE") {
            VStack(spacing: 8) {
                ForEach(Array(activities.prefix(8).enumerated()), id: \.offset) { _, activity in
                    HStack(spacing: 11) {
                        Image(systemName: icon(for: activity.type))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accent)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(activity.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Color.primaryText)
                            Text(activity.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.tertiaryText)
                        }

                        Spacer()

                        Text(activity.duration.formattedDurationShort)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.secondaryText)
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "climbing": return "figure.climbing"
        case "running": return "figure.run"
        case "cycling": return "figure.outdoor.cycle"
        case "swimming": return "figure.pool.swim"
        case "hiking": return "figure.hiking"
        case "rowing": return "figure.rower"
        case "yoga": return "figure.yoga"
        case "hiit": return "figure.highintensity.intervaltraining"
        default: return "figure.mixed.cardio"
        }
    }

    // MARK: Recovery

    private var recoveryCard: some View {
        card("RECOVERY") {
            HStack(spacing: 0) {
                metric(healthContext?.sleepHours.map { String(format: "%.1f", $0) }, "h sleep")
                divider
                metric(healthContext?.restingHR.map { "\(Int($0))" }, "resting HR")
                divider
                metric(healthContext?.hrv.map { "\(Int($0))" }, "HRV ms")
                divider
                metric(vo2Max.map { String(format: "%.0f", $0) }, "VO₂ max")
            }
        }
    }

    // MARK: Lifting

    private var recentLifts: [(name: String, weight: Double, date: Date)] {
        var seen = Set<String>()
        var result: [(String, Double, Date)] = []
        for session in sessions.prefix(20) {
            for entry in session.sortedEntries where !entry.isSkipped {
                guard !seen.contains(entry.exerciseName),
                      let top = entry.workingSets.map(\.weight).max(), top > 0 else { continue }
                seen.insert(entry.exerciseName)
                result.append((entry.exerciseName, top, session.date))
            }
            if result.count >= 8 { break }
        }
        return result.map { (name: $0.0, weight: $0.1, date: $0.2) }
    }

    private var liftingCard: some View {
        card("CURRENT LOADS") {
            VStack(spacing: 8) {
                ForEach(Array(recentLifts.enumerated()), id: \.offset) { _, lift in
                    HStack {
                        Text(lift.name)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Color.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(lift.date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.tertiaryText)
                        Text("\(Int(lift.weight))")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .kerning(0.7)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    /// Shows an em dash rather than a zero when HealthKit has nothing — a
    /// missing reading and a reading of zero are different facts.
    private func metric(_ value: String?, _ label: String) -> some View {
        stat(value ?? "—", label)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondaryText.opacity(0.15))
            .frame(width: 1, height: 28)
    }
}
