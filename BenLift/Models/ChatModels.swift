import Foundation
import SwiftData

// MARK: - Intelligence level

/// User-facing name for how much reasoning a chat turn gets. Maps onto the
/// API's `output_config.effort`. The model never changes — effort is the
/// lever, so a Quick turn is the same Opus 5 thinking less, not a weaker
/// model.
enum Intelligence: String, Codable, CaseIterable, Identifiable {
    case quick, balanced, deep

    var id: String { rawValue }

    /// Value sent as `output_config.effort`.
    var effort: String {
        switch self {
        case .quick: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        }
    }

    var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .balanced: return "Balanced"
        case .deep: return "Deep"
        }
    }

    var subtitle: String {
        switch self {
        case .quick: return "Swaps, weights, short answers · ~2s"
        case .balanced: return "Several constraints at once · ~8s"
        case .deep: return "Injuries, planning the week out · ~30s"
        }
    }
}

// MARK: - Chat role

enum ChatRole: String, Codable {
    case user
    case assistant
    /// Resolver-authored context the user didn't type — e.g. the seeded
    /// "here is today's plan" turn. Rendered differently, never sent as a
    /// user message.
    case system
}

// MARK: - Chat Thread

/// One conversation per day, seeded with that day's resolved plan. Keeping
/// threads day-scoped bounds context size without compaction; anything
/// worth remembering longer becomes a `UserRule` instead of living in
/// scrollback.
@Model
final class ChatThread {
    var id: UUID
    /// Start of the day this thread belongs to.
    var date: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        messages: [ChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.messages = messages
        self.createdAt = createdAt
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.order < $1.order }
    }

    var nextOrder: Int {
        (messages.map(\.order).max() ?? -1) + 1
    }
}

// MARK: - Chat Message

@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var text: String
    var timestamp: Date
    var order: Int
    /// Intelligence level this turn actually ran at — shown in the receipt
    /// under an assistant message. Nil for user messages.
    var intelligenceRaw: String?
    /// Wall-clock round trip, for the "Quick · 1.8s" receipt.
    var latencySeconds: Double?
    /// Names of the plan edits this turn applied, e.g.
    /// ["replace_exercise", "set_load"]. Drives the "superseded" collapse
    /// of the previous plan card.
    var appliedToolsData: Data?
    /// True when this assistant turn produced a new plan card.
    var producedPlanCard: Bool
    /// The plan as it stood after this turn's edits — what the collapsed card
    /// for this message reopens to once a later edit supersedes it.
    var planSnapshotData: Data?
    var thread: ChatThread?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        order: Int,
        timestamp: Date = Date(),
        intelligence: Intelligence? = nil,
        latencySeconds: Double? = nil,
        appliedTools: [String] = [],
        producedPlanCard: Bool = false
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.order = order
        self.timestamp = timestamp
        self.intelligenceRaw = intelligence?.rawValue
        self.latencySeconds = latencySeconds
        self.appliedToolsData = appliedTools.isEmpty ? nil : Data.encodeJSON(appliedTools)
        self.producedPlanCard = producedPlanCard
    }

    var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var intelligence: Intelligence? {
        get { intelligenceRaw.flatMap(Intelligence.init(rawValue:)) }
        set { intelligenceRaw = newValue?.rawValue }
    }

    var appliedTools: [String] {
        get { appliedToolsData?.decodeJSON([String].self) ?? [] }
        set { appliedToolsData = newValue.isEmpty ? nil : Data.encodeJSON(newValue) }
    }

    var planSnapshot: PlanSnapshot? {
        get { planSnapshotData?.decodeJSON(PlanSnapshot.self) }
        set { planSnapshotData = newValue.flatMap { Data.encodeJSON($0) } }
    }
}
