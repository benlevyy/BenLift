import Foundation

/// One day of a training split: a name and the muscle groups it trains.
struct SplitDay: Equatable {
    let name: String
    let muscleGroups: [MuscleGroup]
}

/// The structure the rotation advances through. A split is nothing more than
/// an ordered list of days — the resolver walks the cycle, matches history
/// against each day's muscle groups, and replays. Adding a split here is the
/// whole job of adding one to the app.
/// One user-defined day of a custom split, persisted as JSON in UserDefaults
/// — it's configuration, not training data, so it lives beside the split
/// selection rather than in SwiftData.
struct CustomSplitDay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var muscleGroupsRaw: [String]

    var muscleGroups: [MuscleGroup] {
        muscleGroupsRaw.compactMap(MuscleGroup.init(rawValue:))
    }

    static let storageKey = "customSplitDays"

    static func load() -> [CustomSplitDay] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return data.decodeJSON([CustomSplitDay].self) ?? []
    }

    static func save(_ days: [CustomSplitDay]) {
        UserDefaults.standard.set(Data.encodeJSON(days), forKey: storageKey)
    }
}

enum TrainingSplit: String, Codable, CaseIterable, Identifiable {
    case pushPullLegs
    case upperLower
    case fullBody
    case custom

    var id: String { rawValue }

    static let storageKey = "trainingSplit"

    /// The user's selection, from Settings. Read at resolve time so a change
    /// takes effect on the next plan without any wiring between screens.
    static var current: TrainingSplit {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(TrainingSplit.init(rawValue:)) ?? .pushPullLegs
    }

    var displayName: String {
        switch self {
        case .pushPullLegs: return "Push / Pull / Legs"
        case .upperLower: return "Upper / Lower"
        case .fullBody: return "Full Body"
        case .custom: return "Custom"
        }
    }

    var days: [SplitDay] {
        switch self {
        case .pushPullLegs:
            return [
                SplitDay(name: "Push", muscleGroups: [.chest, .shoulders, .triceps, .core]),
                SplitDay(name: "Pull", muscleGroups: [.back, .biceps, .forearms, .core]),
                SplitDay(name: "Legs", muscleGroups: [.quads, .hamstrings, .glutes, .calves, .core]),
            ]
        case .upperLower:
            return [
                SplitDay(name: "Upper", muscleGroups: [.chest, .back, .shoulders, .biceps, .triceps, .core]),
                SplitDay(name: "Lower", muscleGroups: [.quads, .hamstrings, .glutes, .calves, .core]),
            ]
        case .fullBody:
            return [
                SplitDay(name: "Full Body", muscleGroups: [
                    .chest, .back, .shoulders, .quads, .hamstrings, .glutes, .core,
                ]),
            ]
        case .custom:
            // A day needs a name and at least one muscle group to be usable —
            // the editor enforces that, and this filters anything that slips
            // through. An empty custom split falls back to push/pull/legs so
            // the resolver never walks an empty cycle.
            let days = CustomSplitDay.load()
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.muscleGroups.isEmpty }
                .map { SplitDay(name: $0.name, muscleGroups: $0.muscleGroups + [.core]) }
            return days.isEmpty ? TrainingSplit.pushPullLegs.days : days
        }
    }

    /// The stored PPL category a day corresponds to, when one exists. Sessions
    /// keep carrying the legacy category label where it applies; other splits
    /// leave it nil and lean on muscle groups, which is what inference reads
    /// anyway.
    func category(for day: SplitDay) -> WorkoutCategory? {
        WorkoutCategory(rawValue: day.name.lowercased())
    }
}
