import SwiftUI
import SwiftData
import Charts

struct ProgramOverview: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
    var intelligenceVM: IntelligenceViewModel
    @Query(sort: \WorkoutSession.date, order: .reverse) private var allSessions: [WorkoutSession]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Status: muscle map + compact "this week" stats in the
                    // header. One card instead of two.
                    muscleStatusSection

                    // Weekly volume — trimmed to only muscle groups with
                    // actual volume (previously showed all 11 with zeros).
                    weeklyVolumeSection

                    // Insights: patterns + trends + intelligence combined.
                    // Each sub-section hides itself when it has nothing to
                    // show, so the card quietly shrinks until the user
                    // has real signal to surface.
                    insightsSection

                    // Recent activities (climbing, cardio) — already gated
                    // on `recentTimeline.isEmpty`, stays as its own card.
                    recentActivitiesSection
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Training")
            .onAppear {
                programVM.loadCurrentProgram(modelContext: modelContext)
                loadActivities()
            }
        }
    }

    // MARK: - Exercise count

    @Query private var exercises: [Exercise]
    private var exerciseCount: Int { exercises.count }

    // MARK: - Muscle Status (tappable overrides)

    /// Currently-presented override sheet. Non-nil = picker visible for
    /// that muscle group. Using an item-driven sheet (rather than a bool
    /// + a separate state) avoids the "open for the wrong muscle" race
    /// when the user taps rapidly across rows.
    @State private var overrideTarget: MuscleGroup?

    private var muscleStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MUSCLE STATUS")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                Spacer()
                Text("Tap to override")
                    .font(.system(size: 9))
                    .foregroundColor(.secondaryText)
            }

            // Compact "this week" line — replaces the separate This Week
            // card. Reads sessions / volume / activities at a glance before
            // the muscle detail.
            weekStatsLine

            if coachVM.isLoadingRecommendation {
                ForEach(MuscleGroup.allCases) { mg in
                    shimmerRow(name: mg.rawValue)
                }
            } else if let rec = coachVM.recommendation {
                ForEach(rec.muscleGroupStatus) { mg in
                    tappableRow(
                        muscle: MuscleGroup(rawValue: mg.muscleGroup),
                        defaultName: mg.muscleGroup,
                        baselineStatus: mg.status
                    )
                }
            } else {
                ForEach(computedMuscleStatus(), id: \.name) { mg in
                    tappableRow(
                        muscle: MuscleGroup(rawValue: mg.name),
                        defaultName: mg.name,
                        baselineStatus: mg.status
                    )
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
        .sheet(item: $overrideTarget) { muscle in
            muscleOverrideSheet(for: muscle)
        }
    }

    /// Render one muscle-status row. If the user has set an override for
    /// this muscle, that wins over the AI/computed baseline and we show
    /// a subtle badge indicating it was user-set.
    @ViewBuilder
    private func tappableRow(muscle: MuscleGroup?, defaultName: String, baselineStatus: String) -> some View {
        let override = muscle.flatMap { coachVM.muscleOverrides[$0] }
        let shownStatus = override ?? baselineStatus
        Button {
            if let muscle {
                overrideTarget = muscle
            }
        } label: {
            statusRow(
                name: defaultName,
                status: shownStatus,
                level: statusLevel(shownStatus),
                userSet: override != nil
            )
        }
        .buttonStyle(.plain)
        .disabled(muscle == nil)
    }

    /// Sheet with the four status choices + a Clear action that drops
    /// the override and lets the AI/computed status take over again.
    private func muscleOverrideSheet(for muscle: MuscleGroup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(muscle.displayName)
                    .font(.title3.bold())
                Spacer()
                Button("Cancel") { overrideTarget = nil }
                    .font(.subheadline)
            }
            Text("How does it feel right now? The AI will honor this on the next plan refresh.")
                .font(.caption)
                .foregroundColor(.secondaryText)
            VStack(spacing: 8) {
                ForEach(["fresh", "ready", "recovering", "sore"], id: \.self) { status in
                    Button {
                        coachVM.setMuscleOverride(muscle, status: status)
                        overrideTarget = nil
                    } label: {
                        HStack {
                            Circle()
                                .fill(statusColor(status))
                                .frame(width: 12, height: 12)
                            Text(status.capitalized)
                                .font(.body)
                            Spacer()
                            if coachVM.muscleOverrides[muscle] == status {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentBlue)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.cardSurface)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            if coachVM.muscleOverrides[muscle] != nil {
                Button(role: .destructive) {
                    coachVM.setMuscleOverride(muscle, status: nil)
                    overrideTarget = nil
                } label: {
                    Text("Clear override (use AI read)")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.failedRed.opacity(0.12))
                        .foregroundColor(.failedRed)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func shimmerRow(name: String) -> some View {
        HStack(spacing: 8) {
            Text(name.capitalized)
                .font(.caption)
                .foregroundColor(.secondaryText.opacity(0.4))
                .frame(width: 75, alignment: .trailing)

            ShimmerBar()
                .frame(height: 10)

            Text("...")
                .font(.caption2)
                .foregroundColor(.secondaryText.opacity(0.3))
                .frame(width: 60, alignment: .leading)
        }
    }

    private func statusRow(name: String, status: String, level: Double, userSet: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name.capitalized)
                .font(.caption)
                .foregroundColor(.secondaryText)
                .frame(width: 75, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(statusColor(status))
                        .frame(width: geo.size.width * level)
                }
            }
            .frame(height: 10)

            HStack(spacing: 3) {
                if userSet {
                    // Small dot badge so the user can tell at a glance
                    // which rows they've overridden vs. the AI's read.
                    Image(systemName: "person.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.accentBlue)
                }
                Text(status)
                    .font(.caption2)
                    .foregroundColor(statusColor(status))
            }
            .frame(width: 60, alignment: .leading)
        }
    }

    private func statusLevel(_ status: String) -> Double {
        switch status {
        case "fresh": return 1.0
        case "ready": return 0.75
        case "recovering": return 0.4
        case "sore": return 0.15
        default: return 0.5
        }
    }

    // MARK: - This Week (compact line in the Status card)

    /// One-line summary of this week: sessions • volume • activities.
    /// Previously its own card; now nested into the Status header so the
    /// numbers ride above the muscle map instead of forcing a separate
    /// scroll.
    private var weekStatsLine: some View {
        let weekSessions = sessionsThisWeek
        let liftingSessions = weekSessions.count
        let totalVolume = weekSessions.reduce(0.0) { $0 + $1.totalVolume }

        var parts: [String] = []
        parts.append("\(liftingSessions) session\(liftingSessions == 1 ? "" : "s")")
        if totalVolume > 0 {
            parts.append("\(Int(totalVolume)) lbs")
        }
        if !recentActivityData.isEmpty {
            parts.append("\(recentActivityData.count) activit\(recentActivityData.count == 1 ? "y" : "ies")")
        }

        return HStack {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption.monospacedDigit())
                .foregroundColor(.primary)
            Spacer()
        }
    }

    // MARK: - Weekly Volume

    @ViewBuilder
    private var weeklyVolumeSection: some View {
        let volumeByGroup = computeWeeklyVolume()
        // Filter to groups with actual work this week, ranked desc, cap
        // at 5. Showing 11 rows of mostly-zeros was visual noise — the
        // groups that matter are the ones you've been hitting.
        let topGroups = MuscleGroup.allCases
            .map { ($0.rawValue, volumeByGroup[$0.rawValue] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(5)

        if !topGroups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("WEEKLY VOLUME")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)

                ForEach(Array(topGroups), id: \.0) { group, sets in
                    HStack {
                        Text(group.capitalized)
                            .font(.caption)
                            .frame(width: 70, alignment: .trailing)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentBlue)
                                    .frame(width: geo.size.width * min(Double(sets) / 20.0, 1.0))
                            }
                        }
                        .frame(height: 10)

                        Text("\(sets)")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 30, alignment: .leading)
                    }
                }
            }
            .padding()
            .background(Color.cardSurface)
            .cornerRadius(12)
        }
    }

    // MARK: - Patterns (SessionEvent log + UserObservation)

    @Query(sort: \SessionEvent.timestamp, order: .reverse) private var allEvents: [SessionEvent]

    /// Active AI-learned patterns — sorted by reinforcement recency so
    /// the freshest ones land at the top of the Patterns card.
    @Query(
        filter: #Predicate<UserObservation> { $0.isActive == true },
        sort: \UserObservation.lastReinforcedAt,
        order: .reverse
    ) private var activeObservations: [UserObservation]

    /// Events from the last 30 days — small pool in practice, so we
    /// filter in memory instead of fighting SwiftData #Predicate's Date
    /// arithmetic.
    private var recentEvents: [SessionEvent] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return allEvents.filter { $0.timestamp >= cutoff }
    }

    /// Bullets for the Patterns card. Two sources:
    /// 1. Active `UserObservation` rows — the AI's learned patterns, top
    ///    3 by reinforcement recency. These lead because they're the
    ///    highest-signal "here's what I've noticed about you" insights.
    /// 2. SessionEvent aggregates over the last 30 days — what the user
    ///    actually does (swap / skip / add patterns). Ground truth
    ///    behavior below the AI insights.
    ///
    /// Each bullet gets a kind-appropriate icon. No AI call at render
    /// time; this is local aggregation + durable AI outputs.
    private var derivedPatterns: [(icon: String, text: String)] {
        var bullets: [(icon: String, text: String)] = []

        // AI-learned observations first — top 3 by recency.
        for obs in activeObservations.prefix(3) {
            let icon: String
            switch obs.kind {
            case .correlation: icon = "link"
            case .pattern:     icon = "chart.line.uptrend.xyaxis"
            case .programming: icon = "dumbbell"
            case .recovery:    icon = "bed.double"
            case .note:        icon = "lightbulb"
            case .unknown:     icon = "sparkles"
            }
            bullets.append((icon: icon, text: obs.text))
        }

        // Mid-workout behavior aggregates.
        let events = recentEvents
        guard !events.isEmpty else { return bullets }

        var swapsByName: [String: Int] = [:]
        var skipsByName: [String: Int] = [:]
        var addsByName: [String: Int] = [:]

        for event in events {
            guard let name = event.exerciseName else { continue }
            switch event.kind {
            case .swap:     swapsByName[name, default: 0] += 1
            case .skip:     skipsByName[name, default: 0] += 1
            case .addExercise: addsByName[name, default: 0] += 1
            default: break
            }
        }

        // Most-swapped is the juiciest signal: "you keep replacing X"
        if let top = swapsByName.max(by: { $0.value < $1.value }), top.value >= 2 {
            bullets.append((
                icon: "arrow.triangle.2.circlepath",
                text: "You've swapped \(top.key) \(top.value) times in the last 30 days."
            ))
        }

        // Most-skipped
        if let top = skipsByName.max(by: { $0.value < $1.value }), top.value >= 2 {
            bullets.append((
                icon: "forward.end",
                text: "\(top.key) skipped \(top.value) times — consider dropping it."
            ))
        }

        // Most-added mid-workout
        if let top = addsByName.max(by: { $0.value < $1.value }), top.value >= 2 {
            bullets.append((
                icon: "plus.circle",
                text: "You keep adding \(top.key) mid-workout (\(top.value)×). Worth in the plan?"
            ))
        }

        // Totals summary — lives at the bottom so the specific bullets
        // land first.
        let swapCount = swapsByName.values.reduce(0, +)
        let skipCount = skipsByName.values.reduce(0, +)
        let addCount = addsByName.values.reduce(0, +)
        let total = swapCount + skipCount + addCount
        if total > 0 {
            var parts: [String] = []
            if swapCount > 0 { parts.append("\(swapCount) swap\(swapCount == 1 ? "" : "s")") }
            if skipCount > 0 { parts.append("\(skipCount) skip\(skipCount == 1 ? "" : "s")") }
            if addCount > 0 { parts.append("\(addCount) add\(addCount == 1 ? "" : "s")") }
            bullets.append((
                icon: "chart.bar",
                text: "30-day activity: " + parts.joined(separator: ", ") + "."
            ))
        }

        return bullets
    }

    /// Patterns as a content block (no outer card) — rendered as a
    /// subsection inside `insightsSection`. Empty returns nil so the
    /// caller can skip the subsection + its divider entirely.
    @ViewBuilder
    private var patternsContent: some View {
        let patterns = derivedPatterns
        if !patterns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PATTERNS")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                ForEach(Array(patterns.enumerated()), id: \.offset) { _, pattern in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: pattern.icon)
                            .font(.caption)
                            .foregroundColor(.accentBlue)
                            .frame(width: 16)
                        Text(pattern.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Trends (e1RM sparklines)

    private struct TrendSeries: Identifiable {
        let id: String  // exerciseName
        let exerciseName: String
        let points: [TrendPoint]

        struct TrendPoint: Identifiable {
            let id = UUID()
            let date: Date
            let e1rm: Double
        }

        var latest: Double { points.last?.e1rm ?? 0 }
        var earliest: Double { points.first?.e1rm ?? 0 }
        var delta: Double { latest - earliest }
    }

    /// Top 5 exercises by session count over the last 8 weeks, each with
    /// an e1RM-over-time series. Exercises with fewer than 2 sessions
    /// don't form a meaningful trend — filtered out.
    private var trendSeriesList: [TrendSeries] {
        let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -8, to: Date()) ?? Date()
        let recentSessions = allSessions.filter { $0.date >= cutoff }

        // Aggregate: exerciseName → [(date, e1rm)]
        var byExercise: [String: [(Date, Double)]] = [:]
        for session in recentSessions {
            for entry in session.sortedEntries {
                guard let top = StatsEngine.topSet(sets: entry.sets) else { continue }
                let e1rm = StatsEngine.estimatedOneRepMax(weight: top.weight, reps: top.reps)
                guard e1rm > 0 else { continue }
                byExercise[entry.exerciseName, default: []].append((session.date, e1rm))
            }
        }

        // Rank by session count descending, take top 5 with ≥2 points.
        return byExercise
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(5)
            .map { exerciseName, raw in
                let sortedPoints = raw
                    .sorted { $0.0 < $1.0 }
                    .map { TrendSeries.TrendPoint(date: $0.0, e1rm: $0.1) }
                return TrendSeries(id: exerciseName, exerciseName: exerciseName, points: sortedPoints)
            }
    }

    /// Trends as a content block (no outer card) — rendered inside
    /// `insightsSection`. Skipped entirely when there are no multi-point
    /// series to plot.
    @ViewBuilder
    private var trendsContent: some View {
        let series = trendSeriesList
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("TRENDS · 8 WEEKS")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                ForEach(series) { s in
                    trendRow(s)
                }
            }
        }
    }

    private func trendRow(_ series: TrendSeries) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(series.exerciseName)
                    .font(.caption.bold())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("e1RM \(Int(series.latest))")
                        .font(.caption2.monospacedDigit())
                    deltaBadge(series.delta)
                }
            }
            .frame(width: 120, alignment: .leading)

            // Sparkline — Swift Charts auto-scales, so even small deltas
            // read visibly. No axes / labels, just the line.
            Chart(series.points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("e1RM", point.e1rm)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(series.delta >= 0 ? Color.prGreen : Color.legsOrange)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 28)
        }
    }

    private func deltaBadge(_ delta: Double) -> some View {
        let rounded = Int(delta.rounded())
        let sign = rounded > 0 ? "+" : ""
        let color: Color = rounded == 0 ? .secondaryText : (rounded > 0 ? .prGreen : .legsOrange)
        return Text("\(sign)\(rounded)")
            .font(.caption2.bold().monospacedDigit())
            .foregroundColor(color)
    }

    // MARK: - Recent Activities (unified timeline)

    @State private var recentActivityData: [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)] = []

    private enum TimelineItem: Identifiable {
        case workout(WorkoutSession)
        case activity(index: Int, type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)

        var id: String {
            switch self {
            case .workout(let s): return "w-\(s.id.uuidString)"
            case .activity(let i, _, let d, _, _, _): return "a-\(i)-\(d.timeIntervalSince1970)"
            }
        }

        var date: Date {
            switch self {
            case .workout(let s): return s.date
            case .activity(_, _, let d, _, _, _): return d
            }
        }
    }

    private var recentTimeline: [TimelineItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var items: [TimelineItem] = allSessions
            .filter { $0.date >= cutoff }
            .map { .workout($0) }
        for (i, act) in recentActivityData.enumerated() {
            items.append(.activity(index: i, type: act.type, date: act.date, duration: act.duration, calories: act.calories, source: act.source))
        }
        return items.sorted { $0.date > $1.date }
    }

    private var recentActivitiesSection: some View {
        Group {
            if !recentTimeline.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT ACTIVITY")
                        .font(.caption.bold())
                        .foregroundColor(.secondaryText)

                    ForEach(Array(recentTimeline.prefix(8))) { item in
                        switch item {
                        case .workout(let session):
                            HStack {
                                Image(systemName: "figure.strengthtraining.traditional")
                                    .foregroundColor(.accentBlue)
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(session.displayName)
                                        .font(.subheadline)
                                    HStack(spacing: 4) {
                                        Text(session.date.shortFormatted)
                                        if let dur = session.duration {
                                            Text("•")
                                            Text(TimeInterval(dur).formattedDuration)
                                        }
                                        Text("•")
                                        Text("\(session.entries.count) exercises")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondaryText)
                                }
                                Spacer()
                                Text("Lifting")
                                    .font(.caption2)
                                    .foregroundColor(.accentBlue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentBlue.opacity(0.1))
                                    .cornerRadius(4)
                            }

                        case .activity(_, let type, let date, let duration, _, let source):
                            HStack {
                                Image(systemName: activityIcon(type))
                                    .foregroundColor(.legsOrange)
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(type.capitalized)
                                        .font(.subheadline)
                                    Text("\(date.shortFormatted) • \(TimeInterval(duration).formattedDuration) • \(source)")
                                        .font(.caption2)
                                        .foregroundColor(.secondaryText)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
                .background(Color.cardSurface)
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Intelligence

    /// Intelligence content block. Always shown inside `insightsSection`
    /// since it's where the user manages Refresh / Reset / user input.
    /// The bottom-row profile summary (Goal/Experience/Days) is dropped
    /// here — it's better-suited to Settings or the full IntelligenceView.
    @ViewBuilder
    private var intelligenceContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INTELLIGENCE")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                Spacer()
                NavigationLink {
                    IntelligenceView(
                        intelligenceVM: intelligenceVM,
                        program: programVM.currentProgram
                    )
                } label: {
                    Text("Manage")
                        .font(.caption)
                        .foregroundColor(.accentBlue)
                }
            }

            if let intel = intelligenceVM.intelligence, intel.hasBeenRefreshed {
                if !intel.trainingPatterns.isEmpty && intel.trainingPatterns != "Insufficient data" {
                    Text(intel.trainingPatterns)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                if !intel.strengthProfile.isEmpty && intel.strengthProfile != "Insufficient data" {
                    Text(intel.strengthProfile)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("Refreshed \(intel.lastRefreshed.shortFormatted)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondaryText)
                    if intel.isStale {
                        Text("· Stale")
                            .font(.system(size: 9).bold())
                            .foregroundColor(.orange)
                    }
                    if intel.workoutsSinceRefresh > 0 {
                        Text("· \(intel.workoutsSinceRefresh) new")
                            .font(.system(size: 9))
                            .foregroundColor(.secondaryText)
                    }
                    Spacer()
                }
            } else {
                Text("Tap Manage to analyze your training data.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
    }

    // MARK: - Insights (patterns + trends + intelligence in one card)

    /// Combined Insights card — Patterns + Trends + Intelligence. Each
    /// subsection hides itself when it has no data, so the card quietly
    /// shrinks until the user has real signal. Dividers between rendered
    /// subsections for visual separation.
    @ViewBuilder
    private var insightsSection: some View {
        // Even when all data-derived subsections are empty, we keep the
        // card visible so the user always has a path to Intelligence's
        // Manage link (and the Reset action lives on that full page).
        VStack(alignment: .leading, spacing: 12) {
            let hasPatterns = !derivedPatterns.isEmpty
            let hasTrends = !trendSeriesList.isEmpty

            if hasPatterns {
                patternsContent
            }
            if hasTrends {
                if hasPatterns { Divider() }
                trendsContent
            }
            // Intelligence always renders — it's the entry point to the
            // full manage page and user-provided injuries live there.
            if hasPatterns || hasTrends { Divider() }
            intelligenceContent
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private var sessionsThisWeek: [WorkoutSession] {
        let startOfWeek = Date().startOfWeek
        return allSessions.filter { $0.date >= startOfWeek }
    }

    private func computeWeeklyVolume() -> [String: Int] {
        let lookup = DefaultExercises.buildMuscleGroupLookup(from: modelContext)
        var result: [String: Int] = [:]

        for session in sessionsThisWeek {
            for entry in session.entries {
                let group = lookup[entry.exerciseName]?.rawValue ?? "other"
                let workingSets = entry.sets.filter { !$0.isWarmup }.count
                result[group, default: 0] += workingSets
            }
        }
        return result
    }

    private struct ComputedStatus: Identifiable {
        var id: String { name }
        let name: String
        let status: String
        let level: Double
    }

    private func computedMuscleStatus() -> [ComputedStatus] {
        let lookup = DefaultExercises.buildMuscleGroupLookup(from: modelContext)
        var lastTrained: [String: Date] = [:]

        for session in allSessions.prefix(20) {
            for entry in session.entries {
                let group = lookup[entry.exerciseName]?.rawValue ?? "other"
                if lastTrained[group] == nil {
                    lastTrained[group] = session.date
                }
            }
        }

        return MuscleGroup.allCases.map { mg in
            let name = mg.rawValue
            let daysSince = lastTrained[name].map { Date().daysSince($0) } ?? 99

            let status: String
            let level: Double
            if daysSince >= 4 {
                status = "fresh"; level = 1.0
            } else if daysSince >= 3 {
                status = "ready"; level = 0.75
            } else if daysSince >= 2 {
                status = "recovering"; level = 0.4
            } else {
                status = "sore"; level = 0.15
            }

            return ComputedStatus(name: name, status: status, level: level)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "fresh": return .prGreen
        case "ready": return .pushBlue
        case "recovering": return .legsOrange
        case "sore": return .failedRed
        default: return .secondaryText
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
        default: return "figure.mixed.cardio"
        }
    }

    private func loadActivities() {
        Task {
            recentActivityData = await HealthKitService.shared.fetchRecentActivities(days: 7)
        }
    }
}

// MARK: - Shimmer Bar

struct ShimmerBar: View {
    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.08))
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: geo.size.width * offset)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                offset = 1.4
            }
        }
    }
}
