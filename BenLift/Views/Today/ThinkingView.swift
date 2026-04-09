import SwiftUI

struct ThinkingView: View {
    enum Phase {
        case analyzing
        case building
    }

    let phase: Phase
    @State private var dotCount = 0
    @State private var messageIndex = 0
    @State private var barProgress: [CGFloat] = [0, 0, 0, 0]
    @State private var showMessage = true

    private var messages: [String] {
        switch phase {
        case .analyzing:
            return [
                "Checking recovery status",
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
        VStack(spacing: 16) {
            // Animated bars — use GeometryReader to stay within bounds
            GeometryReader { geo in
                let barArea = geo.size.width - 30 // padding
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentBlue.opacity(0.3 + Double(i) * 0.15))
                            .frame(width: barArea * barProgress[i] * 0.25, height: 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
            }
            .frame(height: 6)

            // Current step message
            HStack(spacing: 0) {
                Text(messages[messageIndex % messages.count])
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .opacity(showMessage ? 1 : 0)

                Text(String(repeating: ".", count: dotCount))
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .frame(width: 20, alignment: .leading)
            }

            // Phase label
            Text(phase == .analyzing ? "ANALYZING" : "BUILDING")
                .font(.caption2.bold())
                .foregroundColor(.accentBlue.opacity(0.5))
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear {
            startAnimations()
        }
    }

    private func startAnimations() {
        // Dot animation
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                dotCount = (dotCount + 1) % 4
            }
        }

        // Message rotation
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                showMessage = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                messageIndex += 1
                withAnimation(.easeIn(duration: 0.15)) {
                    showMessage = true
                }
            }
        }

        // Bar animation
        animateBars()
    }

    private func animateBars() {
        for i in 0..<4 {
            let delay = Double(i) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.5)) {
                    barProgress[i] = CGFloat.random(in: 0.4...1.0)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                barProgress = [0, 0, 0, 0]
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                animateBars()
            }
        }
    }
}
