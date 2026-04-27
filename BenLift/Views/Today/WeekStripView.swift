import SwiftUI
import SwiftData

// MARK: - Day model
//
// View-layer representation of one cell in the strip. Built by
// `PatternEngine.computeWeek(...)` from raw SwiftData (sessions + pins +
// seed patterns). The view itself never decides what a cell shows — that
// logic lives in the engine, where it's testable and stays consistent
// with the planner's `targetMuscleForToday(...)` decision.

enum DaySource: String {
    /// Logged session — read from history.
    case completed
    /// Today's plan, already committed.
    case today
    /// User explicitly chose this muscle group for a future day.
    case pinned
    /// AI's pattern-based guess; can be overridden by tapping the cell.
    case predicted
    /// No prediction available (sparse history). Renders as a "?" placeholder.
    case unknown
}

struct DayIntent: Identifiable, Equatable {
    /// Stable across recomputes — derived from the cell's calendar date so
    /// `selectedDayID`-based sheet routing doesn't break when @Query
    /// invalidates and `days` rebuilds. Using `UUID()` here was a bug:
    /// every rebuild minted new IDs, so the tap → sheet flow lost its
    /// reference within a single render cycle.
    var id: TimeInterval { date.timeIntervalSince1970 }
    var date: Date
    var muscle: MuscleGroup?
    var label: String?       // freeform fallback ("rest", "travel")
    var source: DaySource
    /// Optional context note ("dumbbells only", "shoulders sore") that rides
    /// into the planner prompt for that day. Surfaced via the pin sheet.
    var note: String?
}

// MARK: - Strip View

/// Horizontal scroll of day cells: past 3 days + today + next 3 days. Past +
/// today (when logged) are read-only; today (when not logged) and future
/// cells open a sheet to pin a muscle / add a freeform note. ~100pt tall —
/// sits above the check-in card on Today.
///
/// Data flow: SwiftData @Query for sessions / pins / seed patterns →
/// `PatternEngine.computeWeek(...)` → `[DayIntent]`. The engine is the
/// single source of truth — the view never derives cell state itself.
struct WeekStripView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    @Query private var pins: [MuscleGroupPin]
    @Query private var seedPatterns: [SeedPattern]
    @Query private var exercises: [Exercise]

    @State private var selectedDayID: DayIntent.ID?
    /// HealthKit cross-training (climbing, running, etc.) for the past 21
    /// days. Refreshed on appear — used to color past empty days as the
    /// activity that actually happened, not "Rest."
    @State private var activities: [PatternEngine.ActivityRecord] = []

    private let cellWidth: CGFloat = 78
    private let cellHeight: CGFloat = 100
    private let cellSpacing: CGFloat = 10

    /// Exercise → primary muscle group map. The pattern engine uses this to
    /// derive each session's primary muscle from actual entries (not the
    /// non-deterministic `muscleGroups[]` ordering).
    private var exerciseMuscleLookup: [String: MuscleGroup] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.name, $0.muscleGroup) })
    }

    private var days: [DayIntent] {
        PatternEngine.computeWeek(
            sessions: sessions,
            pins: pins,
            seedPatterns: seedPatterns,
            activities: activities,
            exerciseMuscleLookup: exerciseMuscleLookup
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cellSpacing) {
                    ForEach(days) { day in
                        DayCellView(day: day, width: cellWidth, height: cellHeight)
                            .id(day.id)
                            .onTapGesture {
                                guard day.source != .completed else { return }
                                Haptics.selection()
                                selectedDayID = day.id
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear {
                // Anchor "today" centered on first appear so users see context
                // both directions instead of starting at the leading edge.
                if let todayID = days.first(where: { $0.source == .today })?.id {
                    proxy.scrollTo(todayID, anchor: .center)
                }
            }
            .task {
                // Pull HealthKit cross-training so past days that were
                // climbing / running / etc. don't render as "Rest". Failures
                // (no auth, no data) are silent — the strip degrades to
                // session-only rendering, which is the prior behavior.
                activities = await HealthKitService.shared.fetchRecentActivities(days: PatternEngine.lookbackDays)
            }
        }
        .frame(height: cellHeight + 16)
        .sheet(item: bindingForSelectedDay()) { day in
            PinDaySheet(day: day) { updated in
                applyPinEdit(updated)
                selectedDayID = nil
            } onCancel: {
                selectedDayID = nil
            }
            .presentationDetents([.height(360), .medium])
            .presentationDragIndicator(.visible)
        }
    }

    /// Sheet binding helper — converts the optional ID into an optional
    /// DayIntent so `.sheet(item:)` can drive presentation directly.
    private func bindingForSelectedDay() -> Binding<DayIntent?> {
        Binding(
            get: {
                guard let id = selectedDayID else { return nil }
                return days.first(where: { $0.id == id })
            },
            set: { newValue in
                if newValue == nil { selectedDayID = nil }
            }
        )
    }

    // MARK: - Persistence

    /// Apply a pin-sheet result by upserting (or deleting) the matching
    /// `MuscleGroupPin` row. The strip re-renders automatically via @Query.
    ///
    /// "Clear pin" is signalled by the sheet flipping `source` back to
    /// `.predicted` — that's our cue to delete the row entirely so the
    /// pattern engine takes over again.
    private func applyPinEdit(_ updated: DayIntent) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: updated.date)
        let existing = pins.first { cal.isDate($0.date, inSameDayAs: day) }

        if updated.source == .predicted {
            // User cleared the pin.
            if let row = existing { modelContext.delete(row) }
            try? modelContext.save()
            return
        }

        // User pinned. Upsert.
        if let row = existing {
            row.muscleGroup = updated.muscle
            row.label = updated.label
            row.note = updated.note
        } else {
            let row = MuscleGroupPin(
                date: day,
                muscleGroup: updated.muscle,
                label: updated.label,
                note: updated.note
            )
            modelContext.insert(row)
        }
        try? modelContext.save()
    }
}

// MARK: - Day Cell

private struct DayCellView: View {
    let day: DayIntent
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            // Top row — "TODAY" pill on the current day, otherwise weekday
            // letters. Today gets the explicit label so it can't be missed
            // even if the strip is scrolled off-center.
            Text(topLabel)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.5)
                .foregroundColor(weekdayColor)

            // Muscle text — middle, the headline. Slightly larger now that
            // the cell has more breathing room.
            Text(muscleText)
                .font(.subheadline.bold())
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)

            // Date number — quiet bottom row
            Text(dayNumber)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(textColor.opacity(0.65))
        }
        .padding(.vertical, 10)
        .frame(width: width, height: height)
        .background(background)
        .overlay(borderOverlay)
        .overlay(alignment: .topTrailing) { sourceBadge }
        .cornerRadius(12)
        .scaleEffect(day.source == .today ? 1.05 : 1.0)
        .opacity(opacity)
    }

    // MARK: Layout pieces

    private var weekdayLetter: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: day.date).uppercased()
    }

    /// "TODAY" replaces the weekday letters on the current day so the cell
    /// is unambiguous even when the strip is scrolled off its anchor.
    private var topLabel: String {
        day.source == .today ? "TODAY" : weekdayLetter
    }

    private var dayNumber: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: day.date)
    }

    private var muscleText: String {
        if let label = day.label, !label.isEmpty { return label }
        if let m = day.muscle { return m.displayName }
        return "—"
    }

    @ViewBuilder
    private var background: some View {
        switch day.source {
        case .today:
            Color.accentBlue
        case .completed:
            Color.cardSurface
        case .pinned:
            Color.cardSurface
        case .predicted, .unknown:
            Color.clear
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch day.source {
        case .predicted:
            // Dashed border = "AI guess, tap to confirm"
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color.secondaryText.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        case .unknown:
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondaryText.opacity(0.25), lineWidth: 1)
        case .today:
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentBlue, lineWidth: 2)
        default:
            EmptyView()
        }
    }

    /// Tiny corner glyph that distinguishes pinned (user) from predicted (AI)
    /// from completed (history). The cells already differ in fill/border;
    /// the glyph just makes the source unambiguous at a glance.
    @ViewBuilder
    private var sourceBadge: some View {
        switch day.source {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.prGreen)
                .padding(4)
        case .pinned:
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundColor(.accentBlue)
                .padding(4)
        default:
            EmptyView()
        }
    }

    private var textColor: Color {
        switch day.source {
        case .today: return .white
        case .unknown: return .secondaryText
        case .predicted: return .secondaryText
        default: return .primary
        }
    }

    private var weekdayColor: Color {
        day.source == .today ? .white.opacity(0.85) : .secondaryText
    }

    private var opacity: Double {
        switch day.source {
        case .predicted: return 0.85
        case .unknown:   return 0.6
        default:         return 1.0
        }
    }
}

// MARK: - Pin Day Sheet

/// Tap a future cell to open this. Top: muscle chip grid (one tap = pin).
/// Bottom: optional freeform note that rides into that day's planner prompt.
/// Save commits both; "Clear pin" reverts to AI prediction.
private struct PinDaySheet: View {
    let day: DayIntent
    let onSave: (DayIntent) -> Void
    let onCancel: () -> Void

    @State private var draftMuscle: MuscleGroup?
    @State private var draftLabel: String?
    @State private var draftNote: String

    /// Curated list — most users pick from this set 95% of the time. We
    /// surface major lifts up top and a "Rest" escape hatch. The full
    /// MuscleGroup enum is available via the "More" disclosure if needed.
    private let primaryChips: [ChipOption] = [
        .muscle(.chest), .muscle(.back), .muscle(.shoulders),
        .muscle(.quads), .muscle(.hamstrings), .muscle(.biceps),
        .muscle(.triceps), .label("Rest")
    ]

    init(day: DayIntent, onSave: @escaping (DayIntent) -> Void, onCancel: @escaping () -> Void) {
        self.day = day
        self.onSave = onSave
        self.onCancel = onCancel
        _draftMuscle = State(initialValue: day.muscle)
        _draftLabel  = State(initialValue: day.label)
        _draftNote   = State(initialValue: day.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("What are you training?")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                chipGrid
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Anything else?")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                TextField("e.g. dumbbells only, going heavy",
                          text: $draftNote, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if day.source == .pinned {
                    Button("Clear pin") {
                        Haptics.selection()
                        var cleared = day
                        cleared.source = .predicted
                        cleared.note = nil
                        onSave(cleared)
                    }
                    .font(.subheadline)
                    .foregroundColor(.failedRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.failedRed.opacity(0.08))
                    .cornerRadius(10)
                }

                Button {
                    Haptics.impact(.medium)
                    var updated = day
                    updated.muscle = draftMuscle
                    updated.label = draftLabel
                    updated.note = draftNote.isEmpty ? nil : draftNote
                    updated.source = .pinned
                    onSave(updated)
                } label: {
                    Text("Pin")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftMuscle == nil && draftLabel == nil)
            }
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.title3.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
    }

    private var subtitle: String {
        switch day.source {
        case .predicted:
            if let m = day.muscle { return "AI guess: \(m.displayName) — pin to lock it in" }
            return "Tap a chip to plan this day"
        case .pinned:    return "Pinned — change or clear below"
        case .unknown:   return "No prediction yet"
        default:         return ""
        }
    }

    /// Adaptive grid keeps chips reflowing cleanly across phone widths
    /// without manually breaking into rows.
    private var chipGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(primaryChips, id: \.self) { chip in
                chipButton(chip)
            }
        }
    }

    private func chipButton(_ chip: ChipOption) -> some View {
        let isSelected: Bool = {
            switch chip {
            case .muscle(let m): return draftMuscle == m && draftLabel == nil
            case .label(let s):  return draftLabel == s
            }
        }()
        return Button {
            Haptics.selection()
            switch chip {
            case .muscle(let m):
                draftMuscle = m
                draftLabel = nil
            case .label(let s):
                draftLabel = s
                draftMuscle = nil
            }
        } label: {
            Text(chip.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentBlue : Color.gray.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private enum ChipOption: Hashable {
        case muscle(MuscleGroup)
        case label(String)
        var title: String {
            switch self {
            case .muscle(let m): return m.displayName
            case .label(let s):  return s
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        WeekStripView()
        Spacer()
    }
    .background(Color.appBackground)
}
