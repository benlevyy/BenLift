import SwiftUI
import SwiftData

/// Chat, opened from inside a running workout.
///
/// Same thread as the Today screen — so it already contains this morning's
/// plan and any edits — plus the sets logged so far. That continuity is the
/// point: "shoulder's off, kill the overhead press" resolves against what he
/// has actually done, not against a fresh context.
struct WorkoutChatSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var chatVM: ChatViewModel
    @Bindable var workoutVM: PhoneWorkoutViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            contextHeader

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            messageView(message).id(message.id)
                        }
                        ForEach(chatVM.pendingRules) { proposal in
                            RuleProposalCard(
                                proposal: proposal,
                                onApprove: { chatVM.approve(proposal, modelContext: modelContext) },
                                onDismiss: { chatVM.dismiss(proposal) }
                            )
                        }
                        if chatVM.isSending { thinkingRow }
                        if let error = chatVM.sendError { errorRow(error) }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            backButton
            inputBar
        }
        .background(Color.appBackground)
    }

    // MARK: Header

    private var contextHeader: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.prGreen).frame(width: 7, height: 7)
            Text("In workout")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.prGreen)
            Text("· \(Int(workoutVM.elapsedTime / 60)) min · \(loggedCount) lift\(loggedCount == 1 ? "" : "s") logged")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var loggedCount: Int {
        workoutVM.exerciseStates.filter { !$0.loggedSets.isEmpty }.count
    }

    // MARK: Messages

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
            VStack(alignment: .leading, spacing: 7) {
                Text(message.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                    Text(receiptText(message))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.tertiaryText)
            }
            .padding(.horizontal, 4)
        case .system:
            EmptyView()
        }
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

    // MARK: Controls

    private var backButton: some View {
        Button {
            Haptics.selection()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                Text("Back to workout")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color.controlFill)
            .foregroundStyle(Color.bodyText)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Tell the coach…", text: $chatVM.draft, axis: .vertical)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.primaryText)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                inputFocused = false
                Haptics.impact(.light)
                Task {
                    await chatVM.send(modelContext: modelContext, liveWorkout: workoutVM)
                }
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
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var canSend: Bool {
        !chatVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatVM.isSending
    }
}
