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

    /// Rules Claude has proposed and the user hasn't answered yet. Rendered
    /// as an approve/dismiss card in the transcript — nothing is written to
    /// the database until it's approved.
    private(set) var pendingRules: [PendingRuleProposal] = []

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
    /// Read by the week strip so it can show climbs, rides and runs beside
    /// the lifting. Loaded once from HealthKit and shared rather than fetched
    /// again per view.
    private(set) var crossTraining: [CrossTrainingActivity] = []

    // MARK: Load

    /// Resolve today's plan and open today's thread. Cheap and synchronous —
    /// safe to call from `onAppear` every time.
    func load(modelContext: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())

        // A pin set from the week strip lands straight in SwiftData, and
        // `resolve` never overwrites a stored plan — so without this, pinning
        // a day after its plan exists silently does nothing.
        if let stored = PlanResolver.existingPlan(on: today, modelContext: modelContext),
           !stored.wasEdited {
            var invalid = false
            let split = TrainingSplit.current
            let storedDayName = stored.dayName ?? stored.category?.displayName

            // The split changed in Settings — an unedited plan for a day type
            // the split no longer has is rebuilt on next open. This is the
            // only wiring the Settings picker needs.
            if let storedDayName {
                if let day = split.days.first(where: { $0.name == storedDayName }) {
                    // Same day name, different muscles — a custom day was
                    // edited. The plan no longer trains what the day says.
                    if Set(day.muscleGroups) != Set(stored.muscleGroups) {
                        invalid = true
                    }
                } else {
                    invalid = true
                }
            }

            if let pinned = PlanResolver.pinnedDay(on: today, split: split, modelContext: modelContext),
               storedDayName != pinned.name {
                invalid = true
            }

            // First open of the day resolves before HealthKit has answered, so
            // the plan is persisted with no cross-training flag — and resolve
            // never overwrites a stored plan, so without this check the flag
            // (and its straps/dropped-forearm adjustments) would never appear
            // at all. Once activities land, an unedited flagless plan that
            // should carry one is rebuilt.
            if stored.crossTrainingFlag == nil,
               PlanResolver.crossTrainingFlag(for: stored.muscleGroups, activities: crossTraining, on: today) != nil {
                invalid = true
            }

            if invalid {
                modelContext.delete(stored)
                try? modelContext.save()
            }
        }

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

    /// Throw today's plan away and rebuild it from history.
    ///
    /// `load` deliberately never overwrites a stored plan, which is right for
    /// an ordinary open but leaves no way to pick up a changed rule or a
    /// session logged since. This is that way. A plan chat has edited is left
    /// alone — those edits are the user's, not the resolver's to discard.
    func reresolve(modelContext: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        if let existing = PlanResolver.existingPlan(on: today, modelContext: modelContext) {
            guard !existing.wasEdited else { return }
            modelContext.delete(existing)
            try? modelContext.save()
        }
        load(modelContext: modelContext)
    }

    /// Discard chat's edits and rebuild today's plan from history.
    ///
    /// `reresolve` deliberately refuses to touch an edited plan — those edits
    /// are the user's and shouldn't evaporate on a stray pull-to-refresh. That
    /// left no way back to the deterministic plan once chat had touched it,
    /// which is what this is for. Deliberate, and confirmed at the call site.
    func resetPlanToDefault(modelContext: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())

        if let existing = PlanResolver.existingPlan(on: today, modelContext: modelContext) {
            modelContext.delete(existing)
        }

        // The messages that produced those edits no longer describe the plan
        // on screen, so they stop rendering plan cards. The conversation
        // itself stays — it's a record of what was said, and still useful
        // context for the next turn.
        thread?.messages.forEach { $0.producedPlanCard = false }

        try? modelContext.save()
        load(modelContext: modelContext)
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

            // Freeze what the plan looks like after this turn's edits, so the
            // card can be reopened after a later edit supersedes it.
            if reply.producedPlanCard {
                // `plan` is already unwrapped by the guard at the top of send().
                reply.planSnapshot = PlanSnapshot(of: plan, title: "Updated plan")
            }

            pendingRules.append(contentsOf: executor.pendingRules)
            if executor.didChangeFocus {
                // The day type changed, so the plan was rebuilt underneath us.
                load(modelContext: modelContext)
            }

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

    // MARK: Watch handoff

    /// Build the payload for Start, carrying enough history that the watch's
    /// add-exercise picker suggests real weights rather than its hardcoded
    /// library defaults.
    ///
    /// The watch has no database. Anything it needs to know about what the
    /// user actually lifts has to travel with the plan.
    func watchPlan(modelContext: ModelContext) -> WatchWorkoutPlan? {
        guard let plan else { return nil }

        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let sessions = ((try? modelContext.fetch(descriptor)) ?? []).prefix(30)

        var weights: [String: Double] = [:]
        var frequency: [String: Int] = [:]
        for session in sessions {
            for entry in session.entries where !entry.isSkipped {
                let key = entry.exerciseName.lowercased()
                frequency[key, default: 0] += 1
                // Newest wins: sessions are newest-first, so only fill a gap.
                if weights[key] == nil,
                   let working = PlanResolver.workingWeight(of: entry.workingSets) {
                    weights[key] = working
                }
            }
        }

        let recent = frequency
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(20)
            .map(\.key)

        return plan.toWatchPlan(recentExercises: Array(recent), recentWeights: weights)
    }

    // MARK: Clearing

    /// Wipe today's conversation. The plan is untouched — an edited plan
    /// stays edited (the card footer still offers Reset to default), and the
    /// next message starts from a clean context.
    func clearChat(modelContext: ModelContext) {
        guard let thread else { return }
        for message in thread.messages {
            modelContext.delete(message)
        }
        thread.messages.removeAll()
        pendingRules.removeAll()
        sendError = nil
        try? modelContext.save()
    }

    // MARK: Rule approval

    /// Write the rule. Only reachable from the approve button — nothing else
    /// creates a UserRule any more.
    func approve(_ proposal: PendingRuleProposal, modelContext: ModelContext) {
        let rule = UserRule(
            kind: proposal.kind,
            subject: proposal.subject,
            target: proposal.target,
            reason: proposal.reason
        )
        modelContext.insert(rule)
        try? modelContext.save()
        pendingRules.removeAll { $0.id == proposal.id }

        // An exerciseOut rule changes what the resolver produces, so today's
        // plan is out of date the moment it's approved.
        if proposal.kind == .exerciseOut { reresolve(modelContext: modelContext) }
    }

    func dismiss(_ proposal: PendingRuleProposal) {
        pendingRules.removeAll { $0.id == proposal.id }
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
