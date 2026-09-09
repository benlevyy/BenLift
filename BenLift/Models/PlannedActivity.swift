import Foundation
import SwiftData

/// Something the user has told the coach they're doing on a future day —
/// "climbing tomorrow", "long run Saturday".
///
/// HealthKit only knows the past. A session that hasn't happened yet exists
/// nowhere the app can reach, so this is the only way today's coach can know
/// about tomorrow's climb. Recorded by chat, shown in the week strip, and
/// read back into chat context.
@Model
final class PlannedActivity {
    var id: UUID
    /// Start of the day it's planned for.
    var date: Date
    /// HealthKit's vocabulary ("climbing", "running", "cycling"), so a plan
    /// and the session that eventually lands from HealthKit describe
    /// themselves the same way.
    var activityType: String
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        activityType: String,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.activityType = activityType
        self.note = note
        self.createdAt = createdAt
    }

    var displayName: String {
        activityType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Types worth offering. Matches what HealthKit reports and what the
    /// strip and Hub already have icons for.
    static let knownTypes = [
        "climbing", "running", "cycling", "swimming", "hiking",
        "rowing", "yoga", "hiit", "skiing", "other",
    ]

    /// Upcoming plans, today onward, soonest first.
    @MainActor
    static func upcoming(in context: ModelContext, from date: Date = Date()) -> [PlannedActivity] {
        let day = Calendar.current.startOfDay(for: date)
        let all = (try? context.fetch(FetchDescriptor<PlannedActivity>())) ?? []
        return all.filter { $0.date >= day }.sorted { $0.date < $1.date }
    }

    /// Drop plans for days that have been and gone. Once a day passes,
    /// HealthKit is the authority on whether it actually happened.
    @MainActor
    static func pruneStale(in context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let all = try? context.fetch(FetchDescriptor<PlannedActivity>()) else { return }
        let stale = all.filter { $0.date < today }
        guard !stale.isEmpty else { return }
        for plan in stale { context.delete(plan) }
        try? context.save()
    }
}
