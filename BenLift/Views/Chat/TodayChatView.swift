import SwiftUI
import SwiftData

/// The Today tab, rebuilt chat-first.
///
/// Opens instantly: the plan is resolved from history in Swift, so there is
/// nothing to wait for and no skeleton state. The conversation is the screen;
/// the plan card is the first thing in it.
struct TodayChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var chatVM: ChatViewModel
    @Bindable var phoneMirroring: PhoneMirroringController

    @State private var weekStripExpanded = false
    @State private var showIntelligencePicker = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            inputBar
        }
        .background(Color.appBackground)
        .onAppear {
            chatVM.load(modelContext: modelContext)
            Task {
                await chatVM.loadCrossTraining()
                chatVM.load(modelContext: modelContext)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Haptics.selection()
                    withAnimation(.smooth(duration: 0.28)) { weekStripExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(chatVM.plan?.displayName ?? "Today")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.primaryText)
                        Text("·")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.tertiaryText)
                        Text(weekdayLabel)
                            .font(.system(size: 22))
                            .foregroundStyle(Color.secondaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondaryText)
                            .rotationEffect(.degrees(weekStripExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if phoneMirroring.phoneWorkoutVM.isWorkoutActive {
                    resumeButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if weekStripExpanded {
                WeekStripView(aiTargetMuscleForToday: chatVM.plan?.muscleGroups.first)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var resumeButton: some View {
        Button {
            phoneMirroring.showPhoneWorkout = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Color.prGreen).frame(width: 7, height: 7)
                Text("Resume")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.prGreen)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.prGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var weekdayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: Date())
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let plan = chatVM.plan {
                        // The opening card only shows Start when no later
                        // edit has produced a newer one.
                        PlanCardView(
                            plan: plan,
                            title: "Today's plan",
                            showsStart: chatVM.latestPlanCardMessageID == nil,
                            onStart: start
                        )
                        .id("plan-top")
                    }

                    ForEach(messages) { message in
                        messageView(message)
                            .id(message.id)
                    }

                    if chatVM.isSending {
                        thinkingRow
                    }

                    if let error = chatVM.sendError {
                        errorRow(error)
                    }

                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chatVM.isSending) { _, sending in
                if sending {
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var messages: [ChatMessage] {
        chatVM.thread?.sortedMessages.filter { $0.role != .system } ?? []
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.appBackground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accent)
                    .clipShape(
                        .rect(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 5,
                            topTrailingRadius: 18
                        )
                    )
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                // Answers render as plain text, not a bubble — it reads as
                // the app talking rather than a chat partner, and long
                // replies stay legible.
                VStack(alignment: .leading, spacing: 7) {
                    Text(message.text)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                    receipt(message)
                }
                .padding(.horizontal, 4)

                // The edited plan re-renders as a fresh card; earlier ones
                // collapse so the transcript doesn't stack full plans.
                if message.producedPlanCard, let plan = chatVM.plan {
                    if message.id == chatVM.latestPlanCardMessageID {
                        PlanCardView(plan: plan, title: "Updated plan", showsStart: true, onStart: start)
                    } else {
                        CollapsedPlanRow(plan: plan, liftCount: plan.lifts.count)
                    }
                }
            }

        case .system:
            EmptyView()
        }
    }

    private func receipt(_ message: ChatMessage) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
            Text(receiptText(message))
                .font(.system(size: 10.5))
                .monospacedDigit()
        }
        .foregroundStyle(Color.tertiaryText)
    }

    private func receiptText(_ message: ChatMessage) -> String {
        let level = message.intelligence?.displayName ?? "Quick"
        guard let seconds = message.latencySeconds else { return level }
        return String(format: "%@ · %.1fs", level, seconds)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Color.secondaryText)
            Text((chatVM.activeIntelligence ?? chatVM.intelligence).displayName)
                .font(.system(size: 12))
                .foregroundStyle(Color.tertiaryText)
        }
        .padding(.horizontal, 4)
    }

    private func errorRow(_ error: String) -> some View {
        Text(error)
            .font(.system(size: 12))
            .foregroundStyle(Color.failedRed)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.failedRed.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Tell the coach…", text: $chatVM.draft, axis: .vertical)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)

                Button {
                    Haptics.selection()
                    showIntelligencePicker = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: intelligenceIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(chatVM.intelligence.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.accent.opacity(0.10))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .sheet(isPresented: $showIntelligencePicker) {
            IntelligencePickerSheet(selection: $chatVM.intelligence)
                .presentationDetents([.height(320)])
        }
    }

    private var sendButton: some View {
        Button {
            inputFocused = false
            Haptics.impact(.light)
            Task { await chatVM.send(modelContext: modelContext) }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(canSend ? Color.appBackground : Color.tertiaryText)
                .frame(width: 40, height: 40)
                .background(canSend ? Color.accent : Color.controlFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        !chatVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatVM.isSending
    }

    private var intelligenceIcon: String {
        switch chatVM.intelligence {
        case .quick: return "bolt.fill"
        case .balanced: return "clock"
        case .deep: return "brain"
        }
    }

    // MARK: Actions

    private func start() {
        guard let plan = chatVM.plan, let watchPlan = plan.toWatchPlan() else { return }
        phoneMirroring.startStandaloneSession(plan: watchPlan)
    }
}

// MARK: - Intelligence picker

struct IntelligencePickerSheet: View {
    @Binding var selection: Intelligence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Intelligence.allCases) { level in
                Button {
                    Haptics.selection()
                    selection = level
                    dismiss()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: icon(level))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(level == selection ? Color.accent : Color.secondaryText)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.displayName)
                                .font(.system(size: 14.5, weight: level == selection ? .semibold : .medium))
                                .foregroundStyle(level == selection ? Color.accent : Color.bodyText)
                            Text(level.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondaryText)
                        }
                        Spacer()
                        if level == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .background(level == selection ? Color.accent.opacity(0.10) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 8)

            HStack(spacing: 7) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .semibold))
                Text("Steps up on its own when a question needs it.")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Color.tertiaryText)
            .padding(.horizontal, 12)

            Spacer()
        }
        .padding(16)
        .background(Color.appBackground)
    }

    private func icon(_ level: Intelligence) -> String {
        switch level {
        case .quick: return "bolt.fill"
        case .balanced: return "clock"
        case .deep: return "brain"
        }
    }
}
