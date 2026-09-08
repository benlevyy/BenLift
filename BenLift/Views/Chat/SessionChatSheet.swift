import SwiftUI
import SwiftData

/// Chat about a past workout, opened from its detail screen.
///
/// This replaces the post-workout analysis the rebuild deleted. That version
/// fired a model call after every single session whether or not anyone wanted
/// one, and produced a paragraph most of which went unread. This costs nothing
/// until asked, and can answer the question actually being asked instead of
/// guessing at it in advance.
struct SessionChatSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var chatVM: SessionChatViewModel
    @FocusState private var inputFocused: Bool

    init(session: WorkoutSession) {
        _chatVM = State(initialValue: SessionChatViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                inputBar
            }
            .background(Color.appBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { chatVM.load(modelContext: modelContext) }
        }
    }

    private var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: chatVM.session.date)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatVM.messages.isEmpty { starters }

                    ForEach(chatVM.messages) { message in
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
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chatVM.messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// An empty transcript with a text field is a blank stare. These are the
    /// three questions actually worth asking about a finished session.
    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this session")
                .font(.system(size: 13))
                .foregroundStyle(Color.tertiaryText)

            ForEach(["How did this compare to last time?",
                     "Am I progressing on these lifts?",
                     "Anything I should change?"], id: \.self) { prompt in
                Button {
                    Haptics.selection()
                    chatVM.draft = prompt
                    inputFocused = false
                    Task { await chatVM.send(modelContext: modelContext) }
                } label: {
                    HStack {
                        Text(prompt)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.bodyText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.tertiaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
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

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this session…", text: $chatVM.draft, axis: .vertical)
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        !chatVM.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatVM.isSending
    }
}
