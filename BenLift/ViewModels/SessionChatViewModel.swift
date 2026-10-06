import Foundation
import SwiftData
import Observation

/// Chat about a workout that already happened.
///
/// Has its own thread, keyed to the session. It used to borrow that day's
/// Today thread on the theory that one day is one conversation — but the two
/// are not the same conversation at all: reviewing a session reopened that
/// morning's planning chatter, review answers appeared inline on the Today
/// tab, and "Clear today's chat" deleted them. The context and the tools
/// differ too: a finished session can't be edited, so the plan-mutating tools
/// are withheld and the prompt is about explaining rather than planning.
@MainActor
@Observable
final class SessionChatViewModel {

    let session: WorkoutSession

    private(set) var thread: ChatThread?
    var draft: String = ""
    private(set) var isSending = false
    var sendError: String?
    private(set) var pendingRules: [PendingRuleProposal] = []

    /// Shares the Today picker's setting — one preference, not two.
    var intelligence: Intelligence {
        Intelligence(rawValue: UserDefaults.standard.string(forKey: "chatIntelligence") ?? "") ?? .quick
    }
    private(set) var activeIntelligence: Intelligence?

    private let service = ChatService()

    init(session: WorkoutSession) {
        self.session = session
    }

    // MARK: Load

    func load(modelContext: ModelContext) {
        let sessionID = session.id
        let descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let threads = (try? modelContext.fetch(descriptor)) ?? []

        if let existing = threads.first(where: {
            $0.kind == .session && $0.sessionID == sessionID
        }) {
            thread = existing
        } else {
            // Dated to the workout, not to now, so review threads still sort
            // chronologically alongside the planning ones.
            let fresh = ChatThread(
                date: Calendar.current.startOfDay(for: session.date),
                kind: .session,
                sessionID: sessionID
            )
            modelContext.insert(fresh)
            try? modelContext.save()
            thread = fresh
        }
    }

    // MARK: Send

    func send(modelContext: ModelContext) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let thread else { return }

        draft = ""
        sendError = nil
        isSending = true
        defer {
            isSending = false
            activeIntelligence = nil
        }

        let level = ChatViewModel.escalate(from: intelligence, message: text)
        activeIntelligence = level

        let userMessage = ChatMessage(role: .user, text: text, order: thread.nextOrder)
        userMessage.thread = thread
        thread.messages.append(userMessage)
        try? modelContext.save()

        let history = thread.sortedMessages
            .filter { $0.role != .system && $0.id != userMessage.id }
            .map { (role: $0.role == .user ? "user" : "assistant", text: $0.text) }

        let blocks = ChatContextBuilder.reviewBlocks(session: session, modelContext: modelContext)

        // No plan: this session is finished, and the plan-mutating tools are
        // withheld rather than pointed at today's plan by accident.
        let executor = ChatToolExecutor(
            modelContext: modelContext,
            plan: nil,
            allowedTools: ChatTools.reviewToolNames
        )

        do {
            let result = try await service.send(
                userMessage: text,
                history: history,
                systemBlocks: blocks,
                intelligence: level,
                tools: ChatTools.reviewDefinitions,
                toolHandler: { calls in executor.execute(calls) }
            )

            let reply = ChatMessage(
                role: .assistant,
                text: result.text,
                order: thread.nextOrder,
                intelligence: level,
                latencySeconds: result.latencySeconds,
                appliedTools: result.appliedTools
            )
            reply.thread = thread
            thread.messages.append(reply)

            pendingRules.append(contentsOf: executor.pendingRules)

            modelContext.insert(AIUsageLog(
                intelligence: level,
                inputTokens: result.usage.inputTokens,
                outputTokens: result.usage.outputTokens,
                cachedInputTokens: result.usage.cachedInputTokens,
                latencySeconds: result.latencySeconds
            ))
            try? modelContext.save()

        } catch {
            sendError = error.localizedDescription
            draft = text
            thread.messages.removeAll { $0.id == userMessage.id }
            modelContext.delete(userMessage)
            try? modelContext.save()
        }
    }

    // MARK: Rule approval

    func approve(_ proposal: PendingRuleProposal, modelContext: ModelContext) {
        modelContext.insert(UserRule(
            kind: proposal.kind,
            subject: proposal.subject,
            target: proposal.target,
            reason: proposal.reason
        ))
        try? modelContext.save()
        pendingRules.removeAll { $0.id == proposal.id }
    }

    func dismiss(_ proposal: PendingRuleProposal) {
        pendingRules.removeAll { $0.id == proposal.id }
    }

    var messages: [ChatMessage] {
        thread?.sortedMessages.filter { $0.role != .system } ?? []
    }
}
