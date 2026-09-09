import SwiftUI
import SwiftData

/// The week at a glance, expanded from the header title.
///
/// Shows everything trained, not just what was lifted. Most weeks here have
/// more climbing and riding in them than barbell work, and a strip that only
/// counted app-logged sessions rendered those days blank — which read as rest
/// days that weren't.
///
/// Replaces the old pattern-engine strip, which predicted future days from
/// three-week modal patterns — a system the resolver stopped consulting when
/// rotation took over, so the strip could confidently show a Thursday the
/// resolver would never produce. This one derives everything from the same
/// two sources the resolver uses: logged sessions behind you, the split's
/// cycle ahead of you. It cannot disagree with the plan because it has no
/// opinion of its own.
struct SplitWeekStrip: View {
    let plan: DailyPlan?
    /// Non-lifting sessions from HealthKit, already loaded by the view model.
    let activities: [CrossTrainingActivity]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(pastDays, id: \.label) { day in
                    cell(
                        weekday: day.label,
                        name: day.name,
                        activityTypes: day.activityTypes,
                        style: .past
                    )
                }
                cell(
                    weekday: "Today",
                    name: plan?.displayName ?? "—",
                    activityTypes: todayActivityTypes,
                    style: .today
                )
            }

            if !plannedAhead.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plannedAhead) { plan in
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: plan.activityType))
                                .font(.system(size: 10))
                                .foregroundStyle(Color.flagAmber)
                                .frame(width: 14)
                            Text(whenLabel(for: plan.date))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.secondaryText)
                            Text(plan.note ?? plan.displayName)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Past — what actually happened

    private struct PastDay {
        let label: String
        let name: String?
        let activityTypes: [String]
    }

    private var pastDays: [PastDay] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        let split = TrainingSplit.current
        let lookup = exerciseLookup

        return (1...3).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            let session = sessions.first { calendar.isDate($0.date, inSameDayAs: date) }
            let name = session.flatMap {
                PlanResolver.splitDay(of: $0, in: split, lookup: lookup)?.name ?? $0.displayName
            }
            // Deduped and capped: two climbs in a day is still one icon, and
            // three icons is all a cell this narrow can carry.
            var seen: [String] = []
            for activity in activities where calendar.isDate(activity.date, inSameDayAs: date) {
                if !seen.contains(activity.type) { seen.append(activity.type) }
            }
            return PastDay(
                label: formatter.string(from: date),
                name: name,
                activityTypes: Array(seen.prefix(3))
            )
        }
    }

    private var todayActivityTypes: [String] {
        let calendar = Calendar.current
        var seen: [String] = []
        for activity in activities where calendar.isDate(activity.date, inSameDayAs: Date()) {
            if !seen.contains(activity.type) { seen.append(activity.type) }
        }
        return Array(seen.prefix(3))
    }

    /// Matches the Hub's iconography so the same activity reads the same way
    /// in both places.
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
        case "strength_training", "functional_training": return "dumbbell"
        default: return "figure.mixed.cardio"
        }
    }

    private var exerciseLookup: [String: Exercise] {
        // Small table (~120 rows); fetched once per strip render, and the
        // strip only exists while expanded.
        let all = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        return Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Future — what the rotation will produce

    /// What the user has told the coach they're doing on days to come.
    ///
    /// This replaced a preview of the rotation's next few day types, which
    /// was answering a question nobody asks — the cycle is three names long
    /// and never surprises anyone. What isn't knowable from the app alone is
    /// tomorrow's climb, so that's what the space shows.
    private var plannedAhead: [PlannedActivity] {
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        return PlannedActivity.upcoming(in: modelContext)
            .filter { $0.date >= tomorrow }
            .prefix(3)
            .map { $0 }
    }

    private func whenLabel(for date: Date) -> String {
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    // MARK: Cell

    private enum CellStyle { case past, today }

    private func cell(
        weekday: String,
        name: String?,
        activityTypes: [String],
        style: CellStyle
    ) -> some View {
        // A day with a climb but no lift isn't empty — it says "climbing"
        // rather than the dot that used to imply a rest day.
        let hasLift = name != nil
        let label = name ?? (activityTypes.isEmpty ? "·" : activityTypes[0].replacingOccurrences(of: "_", with: " ").capitalized)

        return VStack(spacing: 3) {
            Text(weekday)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style == .today ? Color.accent : Color.tertiaryText)
            Text(label)
                .font(.system(size: 12, weight: style == .today ? .semibold : .regular))
                .foregroundStyle(!hasLift && activityTypes.isEmpty ? Color.tertiaryText
                                 : style == .today ? Color.primaryText
                                 : hasLift ? Color.bodyText : Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // Icons only where they add something the label doesn't already
            // say — no dumbbell beside "Pull", no climbing icon beside
            // "Climbing".
            if !activityTypes.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(activityTypes.dropFirst(hasLift ? 0 : 1).enumerated()), id: \.offset) { _, type in
                        Image(systemName: icon(for: type))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.flagAmber)
                    }
                }
                .frame(height: 10)
            } else {
                Color.clear.frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(style == .today ? Color.accent.opacity(0.10) : Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
