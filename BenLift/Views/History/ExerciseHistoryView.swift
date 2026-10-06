import SwiftUI
import SwiftData
import Charts

// MARK: - Model

/// What happened to a lift's working weight relative to the time before.
/// The resolver's progression decision, read back out of history.
enum LiftChange: Equatable {
    case first
    case bumped(Double)
    case held
    case dropped(Double)

    var label: String {
        switch self {
        case .first: return "FIRST"
        case .bumped(let d): return "+\(formatLbs(d))"
        case .held: return "HOLD"
        case .dropped(let d): return "−\(formatLbs(d))"
        }
    }

    var symbol: String? {
        switch self {
        case .bumped: return "arrow.up"
        case .dropped: return "arrow.down"
        case .first, .held: return nil
        }
    }

    var color: Color {
        switch self {
        case .bumped: return .prGreen
        case .dropped: return .failedRed
        case .first, .held: return .tertiaryText
        }
    }
}

/// One session's performance of one lift.
struct LiftPerformance: Identifiable {
    let id: UUID
    let date: Date
    /// The resolver's working-weight statistic — the load most of the real
    /// sets were at, not the single heaviest touch.
    let weight: Double
    let sets: [SetLog]
    let targetReps: String?
    let change: LiftChange
    /// What they wrote about it that day, if anything.
    let note: String?

    var repsDetail: String {
        sets.map(\.reps.formattedReps).joined(separator: ", ")
    }
}

enum LiftHistory {
    /// Every session a lift was actually performed in, oldest first, each
    /// tagged with how its weight moved from the one before.
    static func performances(for name: String, in sessions: [WorkoutSession]) -> [LiftPerformance] {
        let ordered = sessions.sorted { $0.date < $1.date }
        var result: [LiftPerformance] = []
        var previous: Double?

        for session in ordered {
            guard let entry = session.entries.first(where: {
                $0.exerciseName == name && !$0.isSkipped
            }) else { continue }
            let working = entry.workingSets
            guard !working.isEmpty else { continue }
            // Bodyweight lifts have no load to track; they still count as a
            // performance at 0 so the session shows up.
            let weight = PlanResolver.workingWeight(of: working) ?? 0

            let change: LiftChange
            if let previous {
                if weight > previous + 0.01 { change = .bumped(weight - previous) }
                else if weight < previous - 0.01 { change = .dropped(previous - weight) }
                else { change = .held }
            } else {
                change = .first
            }
            previous = weight

            result.append(LiftPerformance(
                id: session.id,
                date: session.date,
                weight: weight,
                sets: working,
                targetReps: entry.targetReps,
                change: change,
                note: entry.note
            ))
        }
        return result
    }

    /// One row per lift, most recently performed first.
    static func summaries(in sessions: [WorkoutSession]) -> [LiftSummary] {
        var names: [String] = []
        var seen = Set<String>()
        for session in sessions.sorted(by: { $0.date > $1.date }) {
            for entry in session.sortedEntries where !entry.isSkipped && !entry.workingSets.isEmpty {
                if seen.insert(entry.exerciseName).inserted { names.append(entry.exerciseName) }
            }
        }
        return names.compactMap { name in
            let perfs = performances(for: name, in: sessions)
            guard let latest = perfs.last else { return nil }
            let bumps = perfs.filter { if case .bumped = $0.change { return true } else { return false } }.count
            return LiftSummary(
                name: name,
                latestWeight: latest.weight,
                latestDate: latest.date,
                sessionCount: perfs.count,
                bumpCount: bumps,
                latestChange: latest.change
            )
        }
    }
}

struct LiftSummary: Identifiable {
    var id: String { name }
    let name: String
    let latestWeight: Double
    let latestDate: Date
    let sessionCount: Int
    let bumpCount: Int
    let latestChange: LiftChange
}

func formatLbs(_ weight: Double) -> String {
    weight.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(weight))
        : String(format: "%.1f", weight)
}

func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

// MARK: - All lifts

/// History organised by lift rather than by day. Each row is a lift with its
/// current working weight; tapping opens the full timeline.
struct ExerciseHistoryView: View {
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var searchText = ""

    private var summaries: [LiftSummary] {
        let all = LiftHistory.summaries(in: sessions)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if summaries.isEmpty && searchText.isEmpty {
                ContentUnavailableView(
                    "No Lifts Yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Working sets you log will show up here, one row per lift.")
                )
            } else if summaries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(summaries) { summary in
                    NavigationLink {
                        ExerciseProgressView(exerciseName: summary.name)
                    } label: {
                        row(summary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Lifts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search lifts")
    }

    private func row(_ summary: LiftSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s") · \(summary.bumpCount) bump\(summary.bumpCount == 1 ? "" : "s") · last \(shortDate(summary.latestDate))")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            LiftChangeBadge(change: summary.latestChange)
            Text(formatLbs(summary.latestWeight))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundColor(.primaryText)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - One lift

/// A lift's working weight across every session it appeared in: when it was
/// bumped, when it held, when it was backed off. The "weights bumped" pattern
/// the plan card hints at with its badges, laid out end to end.
struct ExerciseProgressView: View {
    let exerciseName: String
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @State private var selectedDate: Date?

    private var performances: [LiftPerformance] {
        LiftHistory.performances(for: exerciseName, in: sessions)
    }

    var body: some View {
        let perfs = performances

        ScrollView {
            if perfs.isEmpty {
                ContentUnavailableView(
                    "Nothing Logged",
                    systemImage: "chart.xyaxis.line",
                    description: Text("No working sets of \(exerciseName) yet.")
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    summary(perfs)
                    if perfs.count >= 2 {
                        chart(perfs)
                    }
                    timeline(perfs)
                }
                .padding(16)
            }
        }
        .background(Color.appBackground)
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Summary

    private func summary(_ perfs: [LiftPerformance]) -> some View {
        let latest = perfs[perfs.count - 1]
        let first = perfs[0]
        let lastBumpIndex = perfs.lastIndex { if case .bumped = $0.change { return true } else { return false } }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatLbs(latest.weight))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primaryText)
                Text("lb")
                    .font(.headline)
                    .foregroundColor(.secondaryText)
                Spacer()
                LiftChangeBadge(change: latest.change)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let index = lastBumpIndex {
                    let ago = perfs.count - 1 - index
                    let when = ago == 0 ? "last session" : "\(ago) session\(ago == 1 ? "" : "s") ago"
                    if case .bumped(let d) = perfs[index].change {
                        Text("Last bumped +\(formatLbs(d)) on \(shortDate(perfs[index].date)) · \(when)")
                    }
                } else if perfs.count > 1 {
                    Text("Never bumped — held at \(formatLbs(latest.weight)) since \(shortDate(first.date))")
                } else {
                    Text("First time logged \(shortDate(first.date))")
                }

                if perfs.count > 1 {
                    let delta = latest.weight - first.weight
                    let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "")
                    Text("\(sign)\(formatLbs(abs(delta))) lb over \(perfs.count) sessions since \(shortDate(first.date))")
                }
            }
            .font(.caption)
            .foregroundColor(.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Chart

    private func chart(_ perfs: [LiftPerformance]) -> some View {
        let weights = perfs.map(\.weight)
        let low = weights.min() ?? 0
        let high = weights.max() ?? 0
        let pad = max(5, (high - low) * 0.25)
        let domain = max(0, low - pad)...(high + pad)
        let latest = perfs[perfs.count - 1]
        let selected = selectedDate.flatMap { nearest(to: $0, in: perfs) }

        return VStack(alignment: .leading, spacing: 10) {
            Text("WORKING WEIGHT")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .kerning(0.7)

            Chart {
                ForEach(perfs) { perf in
                    LineMark(
                        x: .value("Date", perf.date),
                        y: .value("Weight", perf.weight)
                    )
                    .foregroundStyle(Color.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Date", perf.date),
                        y: .value("Weight", perf.weight)
                    )
                    .foregroundStyle(pointColor(perf.change))
                    .symbolSize(perf.id == selected?.id ? 110 : 64)
                }

                // Direct label on the latest point only — the headline
                // number, not a number on every point.
                if selected == nil {
                    PointMark(
                        x: .value("Date", latest.date),
                        y: .value("Weight", latest.weight)
                    )
                    .opacity(0)
                    .annotation(position: .top, spacing: 6) {
                        Text(formatLbs(latest.weight))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.primaryText)
                    }
                }

                if let selected {
                    RuleMark(x: .value("Selected", selected.date))
                        .foregroundStyle(Color.secondaryText.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortDate(selected.date))
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondaryText)
                                HStack(spacing: 4) {
                                    Text("\(formatLbs(selected.weight)) lb")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Color.primaryText)
                                    Text(selected.change.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(selected.change.color)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.appBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.controlFill, lineWidth: 1)
                            )
                        }
                }
            }
            .chartYScale(domain: domain)
            .chartXSelection(value: $selectedDate)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.controlFill)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.controlFill)
                    AxisValueLabel()
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .frame(height: 190)

            HStack(spacing: 14) {
                legendDot(.prGreen, "bumped")
                legendDot(.tertiaryText, "held")
                legendDot(.failedRed, "backed off")
            }
            .font(.caption2)
            .foregroundColor(.secondaryText)
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func pointColor(_ change: LiftChange) -> Color {
        switch change {
        case .bumped: return .prGreen
        case .dropped: return .failedRed
        case .held: return .tertiaryText
        case .first: return .accent
        }
    }

    private func nearest(to date: Date, in perfs: [LiftPerformance]) -> LiftPerformance? {
        perfs.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: Timeline

    private func timeline(_ perfs: [LiftPerformance]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EVERY SESSION")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .kerning(0.7)
                .padding(.leading, 2)

            VStack(spacing: 2) {
                ForEach(perfs.reversed()) { perf in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortDate(perf.date))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primaryText)
                            HStack(spacing: 4) {
                                Text("\(perf.sets.count) × \(perf.repsDetail)")
                                    .font(.caption.monospacedDigit())
                                if let target = perf.targetReps {
                                    Text("· target \(target)")
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.secondaryText)
                            .lineLimit(1)
                            if let note = perf.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .italic()
                                    .foregroundColor(.secondaryText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 6)
                        LiftChangeBadge(change: perf.change)
                        Text(formatLbs(perf.weight))
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundColor(.primaryText)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Shared badge

/// Arrow plus number, never colour alone — same visual language as the
/// progression badge on the plan card. Used here and on the workout
/// runner's history strip.
struct LiftChangeBadge: View {
    let change: LiftChange

    var body: some View {
        switch change {
        case .bumped, .dropped:
            HStack(spacing: 1) {
                if let symbol = change.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .heavy))
                }
                Text(change.label)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(change.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(change.color.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .held, .first:
            Text(change.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tertiaryText)
        }
    }
}
