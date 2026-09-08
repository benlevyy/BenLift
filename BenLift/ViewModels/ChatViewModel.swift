import Foundation
import SwiftData
import Observation

/// Drives the chat-first Today screen.
///
/// Owns today's plan (resolved deterministically, never re-resolved once it
/// exists) and today's thread. The only thing in this class that touches the
/// network is `send` — nothing fires on load, on appear, or on a timer.
@MainActor
@Observable
final class ChatViewModel {

    // MARK: State

    private(set) var plan: DailyPlan?
    private(set) var thread: ChatThread?
    var draft: String = ""
    private(set) var isSending = false
    var sendError: String?

    /// The level the user picked. Auto-escalation can raise a single turn
    /// above this, but never lowers it.
    var intelligence: Intelligence {
        get { Intelligence(rawValue: storedIntelligence) ?? .quick }
        set { storedIntelligence = newValue.rawValue }
    }
    private var storedIntelligence: String =
        UserDefaults.standard.string(forKey: "chatIntelligence") ?? Intelligence.quick.rawValue {
        didSet { UserDefaults.standard.set(storedIntelligence, forKey: "chatIntelligence") }
    }

    /// Level the in-flight turn is actually running at, so the UI can show
    /// "Balanced" when a Quick request got escalated.
    private(set) var activeIntelligence: Intelligence?

    private let service = ChatService()
    private var crossTraining: [CrossTrainingActivity] = []

    // MARK: Load

    /// Resolve today's plan and open today's thread. Cheap and synchronous —
    /// safe to call from `onAppear` every time.
    func load(modelContext: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())

        let resolved = PlanResolver.resolve(
            for: today,
            modelContext: modelContext,
            activities: crossTraining
        )
        plan = resolved
        thread = Self.thread(for: today, modelContext: modelContext)
    }

    /// Pull cross-training from HealthKit. Display and chat context only —
    /// it is deliberately not in the plan-decision path, so this can land
    /// late without changing what was already resolved.
    func loadCrossTraining() async {
        let raw = await HealthKitService.shared.fetchRecentActivities(days: 7)
        crossTraining = raw.map {
            CrossTrainingActivity(
                type: $0.type,
                date: $0.date,
                duration: $0.duration,
                distanceMiles: nil
            )
        }
    }

    private static func thread(for day: Date, modelContext: ModelContext) -> ChatThread {
        let descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let threads = (try? modelContext.fetch(descriptor)) ?? []
        if let existing = threads.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            return existing
        }
        let fresh = ChatThread(date: day)
        modelContext.insert(fresh)
        try? modelContext.save()
        return fresh
    }

    // MARK: Send

    /// - Parameter liveWorkout: pass the running session's view model when
    ///   chat is opened from inside a workout, so edits land on the live
    ///   session as well as the stored plan.
    func send(modelContext: ModelContext, liveWorkout: PhoneWorkoutViewModel? = nil) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard let plan, let thread else { return }

        draft = ""
        sendError = nil
        isSending = true
        defer {
            isSending = false
            activeIntelligence = nil
        }

        let level = Self.escalate(from: intelligence, message: text)
        activeIntelligence = level

        let userMessage = ChatMessage(role: .user, text: text, order: thread.nextOrder)
        userMessage.thread = thread
        thread.messages.append(userMessage)
        try? modelContext.save()

        let history = thread.sortedMessages
            .filter { $0.role != .system && $0.id != userMessage.id }
            .map { (role: $0.role == .user ? "user" : "assistant", text: $0.text) }

        let blocks = ChatContextBuilder.systemBlocks(
            plan: plan,
            modelContext: modelContext,
            crossTraining: crossTraining,
            liveWorkout: liveWorkout
        )

        let executor = ChatToolExecutor(
            modelContext: modelContext,
            plan: plan,
            liveWorkout: liveWorkout
        )

        do {
            let result = try await service.send(
                userMessage: text,
                history: history,
                systemBlocks: blocks,
                intelligence: level,
                toolHandler: { calls in executor.execute(calls) }
            )

            let reply = ChatMessage(
                role: .assistant,
                text: result.text,
                order: thread.nextOrder,
                intelligence: level,
                latencySeconds: result.latencySeconds,
                appliedTools: result.appliedTools,
                producedPlanCard: !result.appliedTools.isEmpty
            )
            reply.thread = thread
            thread.messages.append(reply)

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
            // Put the text back so a failed send doesn't lose what he typed.
            draft = text
            thread.messages.removeAll { $0.id == userMessage.id }
            modelContext.delete(userMessage)
            try? modelContext.save()
        }
    }

    // MARK: Escalation

    /// Raise the effort for a turn that plainly needs more thought than a
    /// swap does. Never lowers what the user picked.
    static func escalate(from base: Intelligence, message: String) -> Intelligence {
        let text = message.lowercased()

        let deepSignals = [
            "injur", "pain", "hurts", "tweak", "strain", "impinge", "tendon",
            "plan my week", "next few weeks", "programme", "program my",
            "deload", "peak", "stalling", "plateau"
        ]
        if deepSignals.contains(where: text.contains) {
            return base == .deep ? base : .deep
        }

        let balancedSignals = ["why", "should i", "instead of", "explain", "compare", "worth"]
        let multiClause = text.split(whereSeparator: { ",;".contains($0) }).count >= 3
        if multiClause || balancedSignals.contains(where: text.contains) || text.count > 180 {
            return base == .quick ? .balanced : base
        }

        return base
    }

    // MARK: Derived

    /// Index of the last message that produced a plan card. Everything before
    /// it renders collapsed, so the transcript doesn't stack full plans.
    var latestPlanCardMessageID: UUID? {
        thread?.sortedMessages.last { $0.producedPlanCard }?.id
    }

    var hasConversation: Bool {
        !(thread?.messages.isEmpty ?? true)
    }
}
