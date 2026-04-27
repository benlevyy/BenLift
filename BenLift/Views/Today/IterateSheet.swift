import SwiftUI
import SwiftData

/// Bottom sheet that asks the user "what do you want to change?" and routes
/// the freeform request through `CoachViewModel.iterate(...)` — a single LLM
/// call that returns either a structured plan edit (swap / insert / delete /
/// modify) or a conversational explanation. Edits are applied directly to
/// `coachVM.currentPlan` + `editedExercises` via the view-model; this view
/// just drives the request lifecycle and surfaces the result.
///
/// Distinct from quickSwap: quickSwap is per-row ("replace this exercise"),
/// iterate is plan-wide ("prioritize pull-ups", "lighten bench, my shoulder
/// is tight", "why squat first?").
struct IterateSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var coachVM: CoachViewModel

    @State private var requestText: String = ""
    @FocusState private var requestFocused: Bool
    /// Pending auto-dismiss task for edit results so the user gets a brief
    /// "Done" beat before the sheet closes. Tracked so we can cancel it if
    /// the user taps "Got it" first or kicks off another request.
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    inputCard
                    statusSection
                }
                .padding()
            }
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismissCleanly()
                    }
                }
                if requestFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { requestFocused = false }
                            .font(.subheadline.bold())
                    }
                }
            }
        }
        .onDisappear {
            // Reset transient sheet state on the VM so the next time the
            // sheet opens we don't flash the previous result.
            autoDismissTask?.cancel()
            coachVM.iterateLastResult = nil
            coachVM.iterateError = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What do you want to change?")
                .font(.title3.bold())
            Text("e.g. \u{201C}swap the bench, my shoulder feels tight\u{201D} or \u{201C}why squat first?\u{201D}")
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Multiline TextField — vertical axis so the user can describe a
            // multi-step change without the field clipping their input.
            TextField(
                "Describe the change\u{2026}",
                text: $requestText,
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(.body)
            .textFieldStyle(.roundedBorder)
            .focused($requestFocused)
            .disabled(coachVM.isIterating)

            HStack(spacing: 10) {
                Spacer()
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if coachVM.isIterating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(coachVM.isIterating ? "Thinking\u{2026}" : "Submit")
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(submitDisabled ? Color.gray.opacity(0.3) : Color.accentBlue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(submitDisabled)
            }
        }
        .padding(12)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private var submitDisabled: Bool {
        coachVM.isIterating ||
        requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Status / Result

    @ViewBuilder
    private var statusSection: some View {
        if let error = coachVM.iterateError {
            errorCard(error)
        } else if let result = coachVM.iterateLastResult {
            switch result {
            case .edit(let edit):
                editResultCard(edit)
            case .explain(let explain):
                explainResultCard(explain)
            }
        } else if coachVM.isIterating {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("thinking\u{2026}")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .cornerRadius(12)
        }
    }

    private func editResultCard(_ edit: IterateEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.prGreen)
                Text("Done — applied \(edit.edits.count) edit\(edit.edits.count == 1 ? "" : "s").")
                    .font(.subheadline.bold())
            }
            if !edit.rationale.isEmpty {
                Text(edit.rationale)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            if let watchOuts = edit.watchOuts, !watchOuts.isEmpty {
                Text(watchOuts)
                    .font(.caption)
                    .foregroundColor(.legsOrange)
            }
            HStack {
                Spacer()
                Button("Got it") {
                    dismissCleanly()
                }
                .font(.subheadline.bold())
                .foregroundColor(.accentBlue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prGreen.opacity(0.1))
        .cornerRadius(12)
    }

    private func explainResultCard(_ explain: IterateExplain) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.accentBlue)
                Text("Answer")
                    .font(.subheadline.bold())
            }
            Text(explain.answer)
                .font(.body)
                .foregroundColor(.primary)
            HStack {
                Spacer()
                Button("Got it") {
                    dismissCleanly()
                }
                .font(.subheadline.bold())
                .foregroundColor(.accentBlue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.failedRed)
                Text("Couldn't apply that.")
                    .font(.subheadline.bold())
            }
            Text(message)
                .font(.caption)
                .foregroundColor(.secondaryText)
            HStack {
                Spacer()
                Button("Retry") {
                    submit()
                }
                .font(.subheadline.bold())
                .foregroundColor(.accentBlue)
                .disabled(submitDisabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.failedRed.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cancel any pending auto-dismiss from a prior result before kicking
        // off the new request — otherwise the sheet could close out from
        // under the user mid-thought.
        autoDismissTask?.cancel()
        autoDismissTask = nil
        // Clear the prior result so the spinner state shows cleanly.
        coachVM.iterateLastResult = nil
        coachVM.iterateError = nil
        requestFocused = false

        Task {
            await coachVM.iterate(request: trimmed, modelContext: modelContext)
            // After the call settles, if it produced an edit, queue a brief
            // auto-dismiss so the sheet doesn't linger after a successful
            // mutation. Explanations and errors stay until the user dismisses.
            if case .edit = coachVM.iterateLastResult {
                let task = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { dismissCleanly() }
                    }
                }
                autoDismissTask = task
            }
        }
    }

    private func dismissCleanly() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismiss()
    }
}
