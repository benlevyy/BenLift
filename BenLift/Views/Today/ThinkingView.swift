import SwiftUI
import Combine

/// AI-loading state. Visually structured like the destination plan view —
/// title placeholder + skeleton rows — so the loading reads as "the plan
/// is filling in" rather than "waiting from zero."
///
/// Every plan now goes through Opus with adaptive thinking at `effort:
/// "high"` (see ClaudeCoachService), so the realistic wait is 30–90s, not
/// the ~15s this view was originally tuned for. A one-shot animation to a
/// fixed value and a 4-message loop both read as "stuck" once the wait
/// runs past their tuning window — so progress here is driven by elapsed
/// time instead: it keeps crawling forward for as long as the call takes,
/// slowing down but never fully stopping and never reaching 100% on its
/// own (the parent removes this view when the real plan lands).
struct ThinkingView: View {
    enum Phase {
        case analyzing
        case building
    }

    let phase: Phase

    @State private var elapsed: TimeInterval = 0
    @State private var messageIndex = 0
    @State private var showMessage = true
    @State private var shimmerX: CGFloat = -1
    private let clock = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let messageTimer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    /// Asymptotic approach to `cap` — fast in the first few seconds, then
    /// visibly slower, but always still moving. `tau` sets how quickly it
    /// closes in: at `elapsed == tau` it's ~63% of the way to `cap`.
    private var progress: CGFloat {
        let cap = 0.92
        let tau = 28.0
        return CGFloat(cap * (1 - exp(-elapsed / tau)))
    }

    private var elapsedLabel: String {
        "\(Int(elapsed))s"
    }

    private var messages: [String] {
        switch phase {
        case .analyzing:
            return [
                "Checking recovery",
                "Reviewing recent sessions",
                "Reading health data",
                "Picking muscle groups",
                "Weighing today's tradeoffs",
                "Checking against your rules and notes",
                "Comparing to your goals",
                "Cross-referencing recent volume",
            ]
        case .building:
            return [
                "Selecting exercises",
                "Calculating weights",
                "Programming warmups",
                "Sanity-checking the numbers",
                "Writing the reasoning",
                "Finalizing plan",
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + status caption — same visual position the
            // recommendation header occupies once loaded, so the swap-in
            // is a content fill, not a layout shift.
            VStack(alignment: .leading, spacing: 6) {
                placeholderBar(width: 0.55, height: 22)
                HStack(spacing: 6) {
                    Text(phase == .analyzing ? "Analyzing" : "Building")
                        .font(.caption.bold())
                        .foregroundColor(.accentBlue)
                    Text(messages[messageIndex % messages.count])
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .opacity(showMessage ? 1 : 0)
                    Spacer()
                    Text(elapsedLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondaryText)
                }
            }

            // Continuously-creeping bar — always visibly moving for as
            // long as the call runs, instead of freezing at a fixed value.
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentBlue)

            // Sets the expectation up front so a 30–60s wait doesn't read
            // as broken — this is genuinely how long extended thinking on
            // Opus takes, not a stall.
            Text("Thinking it through carefully — usually under a minute.")
                .font(.caption2)
                .foregroundColor(.secondaryText)

            // Skeleton plan rows — same shape as the real exercise rows
            // (PhoneExerciseListView style). Shimmer sweeps across all of
            // them in unison so it's clearly "loading," not stale state.
            VStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { _ in
                    skeletonRow
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
        .onReceive(clock) { _ in
            elapsed += 0.2
        }
        .onReceive(messageTimer) { _ in
            withAnimation(.easeOut(duration: 0.15)) { showMessage = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                messageIndex += 1
                withAnimation(.easeIn(duration: 0.15)) { showMessage = true }
            }
        }
        .onAppear {
            startShimmer()
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(skeletonFill)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                placeholderBar(width: 0.45, height: 12)
                placeholderBar(width: 0.25, height: 8)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(skeletonFill)
                .frame(width: 36, height: 36)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    private func placeholderBar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(skeletonFill)
                .frame(width: geo.size.width * width, height: height)
                .overlay(
                    // Subtle shimmer — a soft diagonal highlight that sweeps
                    // across. Tuned low-contrast so it's animated motion, not
                    // a flashlight.
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * width, height: height)
                    .offset(x: geo.size.width * width * shimmerX)
                    .mask(
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .frame(width: geo.size.width * width, height: height)
                    )
                )
        }
        .frame(height: height)
    }

    private var skeletonFill: Color {
        Color.gray.opacity(0.18)
    }

    private func startShimmer() {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            shimmerX = 1.5
        }
    }
}
