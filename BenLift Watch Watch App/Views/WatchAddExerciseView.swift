import SwiftUI

struct WatchAddExerciseView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @Environment(\.dismiss) private var dismiss
    /// Set to true when the user taps the toolbar toggle to broaden the list
    /// past today's focus (e.g. they want to add core work on a push day).
    @State private var showAll: Bool = false
    /// Drives the native watchOS search field — dictation / scribble pop
    /// automatically when the field gets focus. Filters across Recent +
    /// all muscle-group sections.
    @State private var searchText: String = ""

    var body: some View {
        List {
            if !recentSection.isEmpty {
                Section("Recent") {
                    ForEach(recentSection, id: \.name) { exercise in
                        exerciseRow(exercise)
                    }
                }
            }

            // Muscle-group sections, each alphabetized so the user can
            // predict where a given exercise lives instead of scrolling
            // an arbitrarily-ordered pool.
            ForEach(groupedSections, id: \.0) { group, items in
                Section(group.displayName) {
                    ForEach(items, id: \.name) { exercise in
                        exerciseRow(exercise)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle(showAll ? "All" : "Add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasFocus {
                ToolbarItem(placement: .primaryAction) {
                    Button(showAll ? "Focus" : "All") {
                        showAll.toggle()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Row

    private func exerciseRow(_ exercise: WatchExerciseInfo) -> some View {
        Button {
            workoutVM.addExercise(exercise)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    if exercise.suggestedWeight > 0 {
                        Text("\(exercise.suggestedWeight.formattedLoad) lbs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundColor(.blue)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sectioning

    /// Exercises available to add — excluding anything already in the plan,
    /// scoped to the session's muscle focus when one exists (unless the user
    /// flipped the Focus/All toggle or the plan is an empty manual session).
    private var availableExercises: [WatchExerciseInfo] {
        let alreadyInPlan = Set(workoutVM.exerciseStates.map(\.id))
        let focus: [MuscleGroup] = {
            guard !showAll,
                  let raw = workoutVM.currentPlan?.muscleGroups,
                  !raw.isEmpty else { return [] }
            return raw.compactMap { MuscleGroup(rawValue: $0) }
        }()
        let pool = Self.exercisePool(
            for: focus,
            knownWeights: workoutVM.currentPlan?.recentWeights ?? [:]
        ).filter { !alreadyInPlan.contains($0.name) }
        guard !searchText.isEmpty else { return pool }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The "Recent" section reorders the top ~N picks from history onto a
    /// dedicated first section. Preserves the ranking order from the plan
    /// and excludes anything that's already on today's plan or filtered out
    /// by search/focus (so it stays in sync with the main sections).
    private var recentSection: [WatchExerciseInfo] {
        guard let recent = workoutVM.currentPlan?.recentExercises, !recent.isEmpty else {
            return []
        }
        let available = availableExercises
        let byName: [String: WatchExerciseInfo] = Dictionary(
            uniqueKeysWithValues: available.map { ($0.name, $0) }
        )
        return recent.compactMap { byName[$0] }
    }

    /// Main muscle-group sections. Each group contains its own available
    /// exercises sorted alphabetically. Items surfaced in Recent are
    /// deliberately NOT filtered out here — familiar exercises should stay
    /// discoverable in their expected home.
    private var groupedSections: [(MuscleGroup, [WatchExerciseInfo])] {
        let available = availableExercises
        // Build a name→muscle-group lookup from the static library so we
        // can bucket the runtime `WatchExerciseInfo` entries (which don't
        // carry their own muscle-group tag) into sections.
        let groupByName: [String: MuscleGroup] = Dictionary(
            uniqueKeysWithValues: Self.library.map { ($0.name, $0.muscleGroup) }
        )
        let grouped = Dictionary(grouping: available) { info in
            groupByName[info.name] ?? .core
        }
        return MuscleGroup.allCases.compactMap { group in
            guard let items = grouped[group], !items.isEmpty else { return nil }
            return (group, items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    /// True when the plan has an AI muscle-group focus; drives whether we
    /// offer the Focus/All toggle. Without a focus, the toggle is meaningless.
    private var hasFocus: Bool {
        guard let raw = workoutVM.currentPlan?.muscleGroups else { return false }
        return !raw.isEmpty
    }

    // MARK: - Static library

    /// Filter the shared library by muscle-group focus; empty focus returns
    /// the full catalog (manual/empty workout case). Callers still dedupe
    /// against exercises already in the active plan.
    /// - Parameter knownWeights: last working weight per exercise, sent down
    ///   with the plan. The `library` weights below are textbook numbers — a
    ///   bench is 135 whoever you are — so they're a last resort, used only
    ///   for a movement with no history. Without this, adding an exercise
    ///   mid-workout suggested a weight unrelated to what the user lifts,
    ///   which is most of what "the weights feel random" means on the watch.
    static func exercisePool(
        for focus: [MuscleGroup],
        knownWeights: [String: Double] = [:]
    ) -> [WatchExerciseInfo] {
        let scoped = focus.isEmpty ? library : library.filter { focus.contains($0.muscleGroup) }
        return scoped.map { item in
            WatchExerciseInfo(
                name: item.name,
                sets: 3,
                targetReps: "8-12",
                suggestedWeight: knownWeights[item.name.lowercased()] ?? item.weight,
                warmupSets: nil,
                notes: nil,
                intent: "isolation",
                lastWeight: nil,
                lastReps: nil,
                equipment: item.equipment
            )
        }
    }

    /// Flat library — each entry carries the primary muscle group it trains
    /// plus the equipment (which drives the weight increment on the watch).
    ///
    /// GENERATED from the phone's `DefaultExercises` — same names, groups,
    /// equipment and textbook weights, so a lift added on the phone is
    /// findable on the wrist and lands in the same muscle-group bucket. It
    /// was hand-maintained before and had drifted: ~45 lifts missing and two
    /// filed under a different group than the phone used. If you add to
    /// `DefaultExercises`, mirror it here (or re-run the generator).
    static let library: [LibraryItem] = [
        // Chest
        .init("Bench Press", 135, .barbell, .chest),
        .init("DB Incline Press", 55, .dumbbell, .chest),
        .init("DB Flat Press", 55, .dumbbell, .chest),
        .init("Machine Press", 45, .machine, .chest),
        .init("Incline Barbell Press", 115, .barbell, .chest),
        .init("Landmine Press", 45, .barbell, .chest),
        .init("Single Arm DB Floor Press", 40, .dumbbell, .chest),
        .init("Machine Incline Press", 90, .machine, .chest),
        .init("Svend Press", 10, .dumbbell, .chest),
        .init("Cable Flys", 17.5, .cable, .chest),
        .init("Cable Fly (3 Height)", 12.5, .cable, .chest),
        .init("Pec Deck", 100, .machine, .chest),

        // Shoulders
        .init("DB Shoulder Press", 45, .dumbbell, .shoulders),
        .init("Overhead Press", 85, .barbell, .shoulders),
        .init("Machine Shoulder Press", 45, .machine, .shoulders),
        .init("Lateral Raises", 20, .dumbbell, .shoulders),
        .init("Cable Lateral Raise", 10, .cable, .shoulders),
        .init("Rear Delt Fly", 15, .dumbbell, .shoulders),
        .init("Cable Y-Raise", 7.5, .cable, .shoulders),
        .init("Lu Raises", 10, .dumbbell, .shoulders),
        .init("Cable Front Raise", 15, .cable, .shoulders),
        .init("Plate Bus Driver", 10, .dumbbell, .shoulders),
        .init("Banded Shoulder Dislocate", 0, .bodyweight, .shoulders),
        .init("Face Pulls", 50, .cable, .shoulders),
        .init("Reverse Pec Deck", 70, .machine, .shoulders),
        .init("Face Pull w/ External Rotation", 30, .cable, .shoulders),
        .init("Cable External Rotation", 10, .cable, .shoulders),

        // Triceps
        .init("Close Grip Bench", 115, .barbell, .triceps),
        .init("Skull Crushers", 20, .dumbbell, .triceps),
        .init("Tricep Pushdown", 57.5, .cable, .triceps),
        .init("Tricep Overhead Extension", 47.5, .cable, .triceps),
        .init("Dips", 0, .bodyweight, .triceps),
        .init("Tricep Kickback", 15, .dumbbell, .triceps),
        .init("JM Press", 75, .barbell, .triceps),
        .init("Cable Tricep Kickback", 12.5, .cable, .triceps),
        .init("Diamond Push-ups", 0, .bodyweight, .triceps),
        .init("Single Arm Tricep Pushdown", 20, .cable, .triceps),
        .init("French Press", 25, .dumbbell, .triceps),
        .init("Bench Dips", 0, .bodyweight, .triceps),

        // Back
        .init("Pull-ups", 0, .bodyweight, .back),
        .init("Chin-ups", 0, .bodyweight, .back),
        .init("Lat Pulldown", 145, .machine, .back),
        .init("One Arm Lat Pulldown", 57.5, .cable, .back),
        .init("Straight Arm Pulldown", 30, .cable, .back),
        .init("Neutral Grip Lat Pulldown", 130, .machine, .back),
        .init("Seated Row", 145, .cable, .back),
        .init("Chest Supported Row", 55, .dumbbell, .back),
        .init("Barbell Row", 135, .barbell, .back),
        .init("DB Row", 50, .dumbbell, .back),
        .init("T-Bar Row", 90, .barbell, .back),
        .init("Meadows Row", 45, .barbell, .back),
        .init("Pendlay Row", 135, .barbell, .back),
        .init("Seal Row", 40, .dumbbell, .back),
        .init("Machine Row", 115, .machine, .back),
        .init("Inverted Row", 0, .bodyweight, .back),
        .init("Single Arm Cable Row", 50, .cable, .back),
        .init("Rack Pull", 225, .barbell, .back),
        .init("Kayak Row", 40, .cable, .back),
        .init("Prone Y-T-W Raises", 5, .dumbbell, .back),
        .init("Band Pull-Apart", 0, .bodyweight, .back),
        .init("Kelso Shrug", 30, .dumbbell, .back),
        .init("Snatch Grip Barbell Shrug", 135, .barbell, .back),

        // Biceps
        .init("Barbell Curl", 30, .barbell, .biceps),
        .init("Hammer Curl", 25, .dumbbell, .biceps),
        .init("Incline Hammer Curl", 25, .dumbbell, .biceps),
        .init("Preacher Curl", 12.5, .machine, .biceps),
        .init("Incline Curl", 20, .dumbbell, .biceps),
        .init("Cable Curl", 30, .cable, .biceps),
        .init("Spider Curl", 15, .dumbbell, .biceps),
        .init("EZ Bar Curl", 45, .barbell, .biceps),
        .init("Concentration Curl", 20, .dumbbell, .biceps),
        .init("Bayesian Curl", 20, .cable, .biceps),

        // Forearms
        .init("Wrist Curl", 20, .dumbbell, .forearms),
        .init("Reverse Curl", 40, .barbell, .forearms),

        // Quads
        .init("Squat", 185, .barbell, .quads),
        .init("Front Squat", 135, .barbell, .quads),
        .init("Hack Squat", 45, .machine, .quads),
        .init("Leg Press", 270, .machine, .quads),
        .init("Goblet Squat", 45, .dumbbell, .quads),
        .init("Pendulum Squat", 90, .machine, .quads),
        .init("Belt Squat", 135, .machine, .quads),
        .init("Split Squat", 25, .dumbbell, .quads),
        .init("Bulgarian Split Squat", 20, .dumbbell, .quads),
        .init("Step Ups", 10, .dumbbell, .quads),
        .init("Walking Lunges", 25, .dumbbell, .quads),
        .init("Reverse Lunge", 25, .dumbbell, .quads),
        .init("Leg Extension", 180, .machine, .quads),
        .init("Sissy Squat", 0, .bodyweight, .quads),
        .init("KB Goblet Squat Hold", 25, .kettlebell, .quads),

        // Hamstrings
        .init("Romanian Deadlift", 135, .barbell, .hamstrings),
        .init("Deadlift", 225, .barbell, .hamstrings),
        .init("DB Romanian Deadlift", 50, .dumbbell, .hamstrings),
        .init("Hamstring Curl", 100, .machine, .hamstrings),
        .init("Nordic Curl", 0, .bodyweight, .hamstrings),
        .init("Good Morning", 95, .barbell, .hamstrings),
        .init("Single Leg RDL", 30, .dumbbell, .hamstrings),
        .init("Glute Ham Raise", 0, .bodyweight, .hamstrings),
        .init("Jefferson Curl", 15, .dumbbell, .hamstrings),

        // Glutes
        .init("Hip Thrust", 135, .barbell, .glutes),
        .init("Cable Pull Through", 40, .cable, .glutes),
        .init("Kettlebell Swing", 35, .kettlebell, .glutes),
        .init("Reverse Hyperextension", 90, .machine, .glutes),
        .init("Cable Kickback", 25, .cable, .glutes),
        .init("Hip 90/90 Stretch", 0, .bodyweight, .glutes),

        // Calves
        .init("Calf Raises", 150, .machine, .calves),
        .init("Seated Calf Raise", 90, .machine, .calves),
        .init("Single Leg Calf Raise", 0, .bodyweight, .calves),
        .init("Donkey Calf Raise", 135, .machine, .calves),

        // Core
        .init("Pallof Press", 25, .cable, .core),
        .init("Ab Wheel Rollout", 0, .bodyweight, .core),
        .init("Dead Bug", 0, .bodyweight, .core),
        .init("Copenhagen Plank", 0, .bodyweight, .core),
        .init("Hanging Leg Raise", 0, .bodyweight, .core),
        .init("Farmer's Carry", 70, .dumbbell, .core),
        .init("Suitcase Carry", 50, .dumbbell, .core),
        .init("Cable Woodchop", 30, .cable, .core),
        .init("Weighted Leg Raises", 10, .dumbbell, .core),
        .init("Plank", 0, .bodyweight, .core),
    ]

    struct LibraryItem {
        let name: String
        let weight: Double
        let equipment: Equipment
        let muscleGroup: MuscleGroup

        init(_ name: String, _ weight: Double, _ equipment: Equipment, _ muscleGroup: MuscleGroup) {
            self.name = name
            self.weight = weight
            self.equipment = equipment
            self.muscleGroup = muscleGroup
        }
    }
}
