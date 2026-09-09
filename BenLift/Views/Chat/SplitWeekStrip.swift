import SwiftUI
import SwiftData

/// The week at a glance, expanded from the header title.
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

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(pastDays, id: \.label) { day in
                    cell(weekday: day.label, name: day.name, style: .past)
                }
                cell(weekday: "Today", name: plan?.displayName ?? "—", style: .today)
            }

            if !upcoming.isEmpty {
                HStack(spacing: 5) {
                    Text("Up next")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.tertiaryText)
                    Text(upcoming.joined(separator: " → "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
            return PastDay(label: formatter.string(from: date), name: name)
        }
    }

    private var exerciseLookup: [String: Exercise] {
        // Small table (~120 rows); fetched once per strip render, and the
        // strip only exists while expanded.
        let all = (try? modelContext.fetch(FetchDescriptor<Exercise>())) ?? []
        return Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Future — what the rotation will produce

    /// The next entries in the cycle, in order. Deliberately not pinned to
    /// calendar days: the rotation advances when you train, not when the
    /// earth turns, so "Pull → Legs → Push" is the truth and "Thursday:
    /// Legs" would be a guess.
    private var upcoming: [String] {
        let days = TrainingSplit.current.days
        guard days.count > 1 else { return [] }
        guard let todayName = plan?.dayName,
              let index = days.firstIndex(where: { $0.name == todayName }) else { return [] }
        return (1...min(3, days.count)).map { days[(index + $0) % days.count].name }
    }

    // MARK: Cell

    private enum CellStyle { case past, today }

    private func cell(weekday: String, name: String?, style: CellStyle) -> some View {
        VStack(spacing: 3) {
            Text(weekday)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style == .today ? Color.accent : Color.tertiaryText)
            Text(name ?? "·")
                .font(.system(size: 12, weight: style == .today ? .semibold : .regular))
                .foregroundStyle(name == nil ? Color.tertiaryText
                                 : style == .today ? Color.primaryText : Color.bodyText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(style == .today ? Color.accent.opacity(0.10) : Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
