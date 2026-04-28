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
    /// All muscles this day represents. A "push" day = [chest, shoulders,
    /// triceps]. The cell renders the first as the headline muscle plus a
    /// "+N" badge when there are more — full list visible in the pin sheet.
    var muscles: [MuscleGroup]
    var label: String?       // freeform fallback ("rest", "travel")
    var source: DaySource
    /// Optional context note ("dumbbells only", "shoulders sore") that rides
    /// into the planner prompt for that day. Surfaced via the pin sheet.
    var note: String?

    /// First muscle (headline) — most cell rendering still wants a single
    /// muscle for the big text. nil when the day has no muscles (rest).
    var muscle: MuscleGroup? { muscles.first }

    /// Convenience for callers that produce a single-muscle DayIntent
    /// (the engine path before / on cold-start).
    init(date: Date, muscle: MuscleGroup?, label: String?, source: DaySource, note: String? = nil) {
        self.date = date
        self.muscles = muscle.map { [$0] } ?? []
        self.label = label
        self.source = source
        self.note = note
    }

    /// Multi-muscle init for pin/seed paths that carry a real list.
    init(date: Date, muscles: [MuscleGroup], label: String?, source: DaySource, note: String? = nil) {
        self.date = date
        self.muscles = muscles
        self.label = label
        self.source = source
        self.note = note
    }
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

    /// Today's muscle picked by the LLM (CoachViewModel.targetMuscleGroups
    /// .first). When non-nil and there's no pin or logged session for today,
    /// this overrides the pattern engine's prediction for the today cell.
    /// The strip stays a deterministic data view; the AI's signal flows in
    /// from the parent so the engine doesn't need to know about CoachVM.
    let aiTargetMuscleForToday: MuscleGroup?

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
            exerciseMuscleLookup: exerciseMuscleLookup,
            aiTargetMuscle: aiTargetMuscleForToday
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

        // User pinned. Upsert the full muscle list.
        if let row = existing {
            row.muscleGroups = updated.muscles
            row.label = updated.label
            row.note = updated.note
        } else {
            let row = MuscleGroupPin(
                date: day,
                muscleGroups: updated.muscles,
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
        // Recognize common multi-muscle patterns and label them ("Push" /
        // "Pull" / "Legs") instead of "Chest +2" — more readable at the
        // cell's compact size.
        if let preset = matchedPresetName(for: day.muscles) { return preset }
        guard let m = day.muscle else { return "—" }
        if day.muscles.count <= 1 { return m.displayName }
        return "\(m.displayName) +\(day.muscles.count - 1)"
    }

    /// Match the day's muscle set against canonical presets so the cell
    /// shows "Push" instead of a comma list. Order-insensitive.
    private func matchedPresetName(for muscles: [MuscleGroup]) -> String? {
        let s = Set(muscles)
        if s == Set([.chest, .shoulders, .triceps]) { return "Push" }
        if s == Set([.back, .biceps]) { return "Pull" }
        if s == Set([.quads, .hamstrings, .glutes, .calves]) { return "Legs" }
        if s == Set([.chest, .back, .shoulders, .biceps, .triceps]) { return "Upper" }
        return nil
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

    @State private var draftMuscles: Set<MuscleGroup>
    @State private var draftLabel: String?
    @State private var draftNote: String

    /// Curated quick-presets that map common training days to their muscle
    /// stacks. One tap fills the multi-select, user can refine. "Rest" is
    /// mutually exclusive with any muscles.
    private let presets: [Preset] = [
        .init(name: "Push",  muscles: [.chest, .shoulders, .triceps]),
        .init(name: "Pull",  muscles: [.back, .biceps]),
        .init(name: "Legs",  muscles: [.quads, .hamstrings, .glutes, .calves]),
        .init(name: "Upper", muscles: [.chest, .back, .shoulders, .biceps, .triceps]),
        .init(name: "Lower", muscles: [.quads, .hamstrings, .glutes, .calves]),
    ]

    /// Individual muscle chips for users who want to compose their own
    /// set rather than pick a preset.
    private let muscleChips: [MuscleGroup] = [
        .chest, .back, .shoulders, .biceps, .triceps,
        .quads, .hamstrings, .glutes, .calves, .core
    ]

    init(day: DayIntent, onSave: @escaping (DayIntent) -> Void, onCancel: @escaping () -> Void) {
        self.day = day
        self.onSave = onSave
        self.onCancel = onCancel
        _draftMuscles = State(initialValue: Set(day.muscles))
        _draftLabel  = State(initialValue: day.label)
        _draftNote   = State(initialValue: day.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick presets")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                presetRow

                Text("What are you training?")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                muscleChipGrid

                restButton
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
                    // Stable order: follow the chip-grid order so the
                    // headline muscle in the strip cell is deterministic
                    // across edits.
                    updated.muscles = muscleChips.filter { draftMuscles.contains($0) }
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
                .disabled(draftMuscles.isEmpty && draftLabel == nil)
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
            return "Tap chips to plan this day"
        case .pinned:    return "Pinned — change or clear below"
        case .unknown:   return "No prediction yet"
        default:         return ""
        }
    }

    /// Quick-preset row — horizontal scroll of "Push" / "Pull" / "Legs" /
    /// "Upper" / "Lower". One tap replaces the muscle selection with the
    /// preset's full set. Clears the rest-day label too.
    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    private func presetChip(_ preset: Preset) -> some View {
        // Preset is "selected" when its muscle set exactly matches the
        // current draft (so the user sees which preset they're on).
        let isSelected = draftMuscles == Set(preset.muscles) && draftLabel == nil
        return Button {
            Haptics.selection()
            draftMuscles = Set(preset.muscles)
            draftLabel = nil
        } label: {
            Text(preset.name)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentBlue : Color.gray.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }

    /// Adaptive grid of muscle chips. Tapping toggles in/out of the
    /// `draftMuscles` set — true multi-select.
    private var muscleChipGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(muscleChips, id: \.self) { muscle in
                muscleChipButton(muscle)
            }
        }
    }

    private func muscleChipButton(_ muscle: MuscleGroup) -> some View {
        let isSelected = draftMuscles.contains(muscle) && draftLabel == nil
        return Button {
            Haptics.selection()
            draftLabel = nil
            if isSelected {
                draftMuscles.remove(muscle)
            } else {
                draftMuscles.insert(muscle)
            }
        } label: {
            Text(muscle.displayName)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentBlue : Color.gray.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    /// Standalone Rest button — mutually exclusive with any muscle
    /// selection. Tapping clears muscles and sets label="Rest".
    private var restButton: some View {
        let isSelected = draftLabel == "Rest"
        return Button {
            Haptics.selection()
            if isSelected {
                draftLabel = nil
            } else {
                draftLabel = "Rest"
                draftMuscles = []
            }
        } label: {
            HStack {
                Image(systemName: "moon.zzz.fill").font(.caption)
                Text("Rest day")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentBlue : Color.gray.opacity(0.12))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    /// Curated quick-presets — common training day shapes.
    private struct Preset: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let muscles: [MuscleGroup]
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
        WeekStripView(aiTargetMuscleForToday: nil)
        Spacer()
    }
    .background(Color.appBackground)
}
