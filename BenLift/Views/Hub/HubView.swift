import SwiftUI
import SwiftData
import UIKit

/// Everything he actually does, in one place — and one picture of it.
///
/// The hero is the training portrait: a drawing built from every logged
/// exercise and every HealthKit workout, no decoration. Three rules, and
/// they fit on one line under the canvas: outward is time, angle is muscle,
/// bold is progress. Below it, the week's numbers, which lifts are moving
/// and which are stuck, recovery, and the non-lifting sessions.
///
/// Lifting comes from SwiftData; everything else is read from HealthKit,
/// because those sessions are already tracked by the apps that recorded
/// them and re-entering them here would be busywork.
///
/// Read-only by design. Nothing here feeds the plan resolver — it's context
/// for him, and for chat when he asks.
struct HubView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    /// A year of cross-training, fetched once. The portrait wants all of it;
    /// the week strip and the list below filter it down.
    @State private var activities: [CrossTrainingActivity] = []
    @State private var healthContext: HealthContext?
    @State private var vo2Max: Double?

    // Derived in `rebuild()`, not in `body` — the portrait walks every set
    // ever logged, and the labels toggle should not pay for that.
    @State private var strokes: [PortraitStroke] = []
    @State private var showsLabels = false
    @State private var shareImage: UIImage?
    @State private var movingUp: [LiftSummary] = []
    @State private var stuck: [LiftSummary] = []
    @State private var liftsMovedUp = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    portraitCard
                    thisWeekCard
                    if !movingUp.isEmpty || !stuck.isEmpty { whatMovedCard }
                    recoveryCard
                    if !recentActivities.isEmpty { crossTrainingCard }
                }
                .padding(16)
            }
            .background(Color.appBackground)
            .navigationTitle("Hub")
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: sessions.count) { rebuild() }
        }
    }

    // MARK: Loading

    private func load() async {
        // Lifting is local, so draw it before HealthKit answers rather than
        // showing an empty ring while the query runs.
        rebuild()

        async let raw = HealthKitService.shared.fetchRecentActivities(days: 365)
        async let context = HealthKitService.shared.fetchHealthContext()
        async let vo2 = HealthKitService.shared.fetchVO2Max()

        // Parenthesised: `await raw.map { }` would try to call map on the
        // unresolved async-let binding rather than on its result.
        activities = (await raw).map {
            CrossTrainingActivity(
                type: $0.type,
                date: $0.date,
                duration: $0.duration,
                distanceMiles: $0.distanceMiles
            )
        }
        healthContext = await context
        vo2Max = await vo2

        rebuild()
    }

    /// Recomputes everything derived from sessions and activities.
    private func rebuild() {
        strokes = TrainingPortrait.strokes(
            sessions: sessions,
            activities: activities,
            exerciseGroups: muscleGroupLookup()
        )

        let summaries = LiftHistory.summaries(in: sessions)
        let recent = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        movingUp = Array(summaries.filter { summary in
            if case .bumped = summary.latestChange { return summary.latestDate >= recent }
            return false
        }.prefix(5))
        stuck = Array(summaries.filter { isStuck($0) }.prefix(5))
        liftsMovedUp = liftsMovedUpCount()

        renderShareImage()
    }

    /// Shipped defaults first, then the library — a lift the user has refiled
    /// wins over the shipped list. Keys lowercased, so "bench press" from a
    /// plan and "Bench Press" from the library are the same lift.
    private func muscleGroupLookup() -> [String: MuscleGroup] {
        var lookup: [String: MuscleGroup] = [:]
        for def in DefaultExercises.all {
            lookup[def.name.lowercased()] = def.muscleGroup
        }
        let stored = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        for exercise in stored {
            lookup[exercise.name.lowercased()] = exercise.muscleGroup
        }
        return lookup
    }

    /// Three sessions in a row at the same load, the latest within a month.
    /// Bodyweight lifts hold at 0 forever and are not stuck, just unloaded.
    private func isStuck(_ summary: LiftSummary) -> Bool {
        let month = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        guard summary.latestWeight > 0, summary.latestDate >= month else { return false }
        let perfs = LiftHistory.performances(for: summary.name, in: sessions)
        guard perfs.count >= 3 else { return false }
        return perfs.suffix(2).allSatisfy { $0.change == .held }
    }

    /// Lifts whose current working weight is above the first one ever logged.
    /// One pass, oldest to newest — the same baseline the portrait uses.
    private func liftsMovedUpCount() -> Int {
        var first: [String: Double] = [:]
        var latest: [String: Double] = [:]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for entry in session.entries where !entry.isSkipped {
                let working = entry.workingSets
                guard !working.isEmpty,
                      let weight = PlanResolver.workingWeight(of: working) else { continue }
                let key = entry.exerciseName.lowercased()
                if first[key] == nil { first[key] = weight }
                latest[key] = weight
            }
        }
        return first.filter { key, start in (latest[key] ?? start) > start + 0.01 }.count
    }

    private func renderShareImage() {
        shareImage = strokes.isEmpty
            ? nil
            : portraitImage(strokes: strokes, showsLabels: showsLabels)
    }

    // MARK: Portrait

    private var portraitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PORTRAIT")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                    .kerning(0.7)
                Spacer()
                if let shareImage {
                    let image = Image(uiImage: shareImage)
                    ShareLink(item: image, preview: SharePreview("My training", image: image)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share portrait")
                }
            }
            .frame(height: 44)

            TrainingPortraitView(strokes: strokes, showsLabels: showsLabels)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.selection()
                    showsLabels.toggle()
                    renderShareImage()
                }
                .accessibilityElement()
                .accessibilityLabel("Training portrait")
                .accessibilityValue(portraitSentence)
                .accessibilityHint(showsLabels ? "Hides muscle labels" : "Shows muscle labels")
                .accessibilityAddTraits(.isButton)

            VStack(alignment: .leading, spacing: 4) {
                Text(portraitSentence)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Outward is time · angle is muscle · bold is progress")
                    .font(.caption)
                    .foregroundStyle(Color.tertiaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// "Since 3 Jun: 48 sessions, 14 lifts moved up, 6 climbs." Built from
    /// the same data as the drawing; a clause that would read zero is left out.
    private var portraitSentence: String {
        guard let since = firstEventDate else {
            return "Your first session draws the first stroke."
        }

        var clauses: [String] = []
        if !sessions.isEmpty { clauses.append(counted(sessions.count, "session")) }
        if liftsMovedUp > 0 { clauses.append("\(counted(liftsMovedUp, "lift")) moved up") }
        clauses += activityClauses
        guard !clauses.isEmpty else { return "Your first session draws the first stroke." }

        let sameYear = Calendar.current.isDate(since, equalTo: Date(), toGranularity: .year)
        let start = sameYear
            ? since.formatted(.dateTime.day().month(.abbreviated))
            : since.formatted(.dateTime.day().month(.abbreviated).year())
        return "Since \(start): \(clauses.joined(separator: ", "))."
    }

    private var firstEventDate: Date? {
        // Sessions are sorted newest first, so the oldest is last.
        let dates = [sessions.last?.date, activities.map(\.date).min()].compactMap { $0 }
        return dates.min()
    }

    private var activityClauses: [String] {
        var counts: [String: Int] = [:]
        for activity in activities { counts[activity.type, default: 0] += 1 }

        var clauses: [String] = []
        var named = 0
        for (type, noun) in [("climbing", "climb"), ("running", "run"), ("cycling", "ride")] {
            guard let n = counts[type] else { continue }
            clauses.append(counted(n, noun))
            named += n
        }
        let other = activities.count - named
        if other > 0 { clauses.append("\(other) other") }
        return clauses
    }

    private func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
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
            }
        }
    }

    private var hoursLabel: String {
        let lifting = sessionsThisWeek.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let cross = activitiesThisWeek.reduce(0.0) { $0 + $1.duration }
        return String(format: "%.1f", (lifting + cross) / 3600)
    }

    // MARK: What moved

    private var whatMovedCard: some View {
        card("WHAT MOVED") {
            VStack(alignment: .leading, spacing: 14) {
                if !movingUp.isEmpty { liftList("Moving up", movingUp) }
                if !stuck.isEmpty { liftList("Stuck", stuck) }
            }
        }
    }

    private func liftList(_ title: String, _ lifts: [LiftSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tertiaryText)
                .padding(.bottom, 4)

            ForEach(lifts) { summary in
                NavigationLink {
                    ExerciseProgressView(exerciseName: summary.name)
                } label: {
                    HStack(spacing: 8) {
                        Text(summary.name)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Color.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        LiftChangeBadge(change: summary.latestChange)
                        Text(formatLbs(summary.latestWeight))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.tertiaryText)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Cross-training

    /// The last two weeks, for the list. The portrait has the whole year.
    private var recentActivities: [CrossTrainingActivity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        return activities.filter { $0.date >= cutoff }
    }

    private var crossTrainingCard: some View {
        card("EVERYTHING ELSE") {
            VStack(spacing: 8) {
                ForEach(Array(recentActivities.prefix(8).enumerated()), id: \.offset) { _, activity in
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
