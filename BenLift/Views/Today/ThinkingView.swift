import SwiftUI

/// AI-loading state. Visually structured like the destination plan view —
/// title placeholder + skeleton rows — so the loading reads as "the plan
/// is filling in" rather than "waiting from zero." A single slow-fill
/// progress bar replaces the previous random-bars dance because directional
/// motion feels purposeful while equal-energy motion reads as stuck.
struct ThinkingView: View {
    enum Phase {
        case analyzing
        case building
    }

    let phase: Phase

    @State private var progress: CGFloat = 0
    @State private var messageIndex = 0
    @State private var showMessage = true
    @State private var shimmerX: CGFloat = -1

    private var messages: [String] {
        switch phase {
        case .analyzing:
            return [
                "Checking recovery",
                "Reviewing recent sessions",
                "Reading health data",
                "Picking muscle groups",
            ]
        case .building:
            return [
                "Selecting exercises",
                "Calculating weights",
                "Programming warmups",
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
                }
            }

            // One purposeful, slow-fill bar. Eases out so it slows as it
            // approaches the held value — reads as "converging" instead
            // of "stuck."
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentBlue)

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
        .onAppear {
            // 6s ease-out fill to 85%. The remaining 15% holds until the
            // parent removes this view; never reaches 100% on its own,
            // so the user never sees a "why isn't it done yet" full bar.
            withAnimation(.easeOut(duration: 6.0)) {
                progress = 0.85
            }
            startMessageCycle()
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

    private func startMessageCycle() {
        // 1.4s — fast enough that the user reliably sees a new step within
        // the typical 4–6s wait, slow enough that lines stay readable.
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.15)) { showMessage = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                messageIndex += 1
                withAnimation(.easeIn(duration: 0.15)) { showMessage = true }
            }
        }
    }

    private func startShimmer() {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            shimmerX = 1.5
        }
    }
}
