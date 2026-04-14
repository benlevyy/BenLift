import SwiftUI

/// Rest timer overlay shown during iPhone workout between sets.
///
/// Reads `restEndsAt` from the snapshot (absolute date) and uses TimelineView to
/// tick once a second. This is drift-proof across backgrounding because the
/// remaining time is always computed from the absolute end date.
struct PhoneRestTimerView: View {
    @Bindable var workoutVM: PhoneWorkoutViewModel
    var onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let remaining = workoutVM.restEndsAt.map { $0.timeIntervalSince(now) } ?? 0
        let duration = workoutVM.restTimerDuration
        let isOverRest = remaining <= 0
        let displayTime = isOverRest ? "+\(formatTime(abs(remaining)))" : formatTime(remaining)
        let ringProgress: Double = duration > 0 && !isOverRest ? max(0, min(1, 1 - (remaining / duration))) : 1.0
        let ringColor: Color = {
            if !isOverRest { return .accentBlue }
            let over = abs(remaining)
            if over < 30 { return .prGreen }
            if over < 60 { return .legsOrange }
            return .failedRed
        }()
        let timerColor: Color = {
            if !isOverRest { return .primary }
            let over = abs(remaining)
            if over < 30 { return .prGreen }
            if over < 60 { return .legsOrange }
            return .failedRed
        }()

        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {} // Prevent taps passing through

            VStack(spacing: 20) {
                Text("Rest")
                    .font(.headline)
                    .foregroundColor(.secondaryText)

                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 8)

                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: ringProgress)

                    VStack(spacing: 2) {
                        Text(displayTime)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(timerColor)

                        if isOverRest {
                            Text("over rest")
                                .font(.caption)
                                .foregroundColor(timerColor.opacity(0.7))
                        }
                    }
                }
                .frame(width: 160, height: 160)

                if workoutVM.currentHeartRate > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.failedRed)
                        Text("\(Int(workoutVM.currentHeartRate)) bpm")
                            .font(.subheadline.monospacedDigit())
                    }
                }

                HStack(spacing: 20) {
                    Button {
                        workoutVM.adjustRestTimer(by: -30)
                    } label: {
                        Text("-30")
                            .font(.subheadline.bold())
                            .frame(width: 56, height: 40)
                            .background(Color.cardSurface)
                            .cornerRadius(8)
                    }

                    Button {
                        onDismiss()
                    } label: {
                        Text(isOverRest ? "Go" : "Skip")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                            .frame(width: 80, height: 44)
                            .background(isOverRest ? Color.prGreen : Color.secondaryText)
                            .cornerRadius(10)
                    }

                    Button {
                        workoutVM.adjustRestTimer(by: 30)
                    } label: {
                        Text("+30")
                            .font(.subheadline.bold())
                            .frame(width: 56, height: 40)
                            .background(Color.cardSurface)
                            .cornerRadius(8)
                    }
                }

                Button {
                    workoutVM.undoLastSet()
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                        Text("Undo Last Set")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.failedRed)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.failedRed.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(32)
            .background(Color.appBackground)
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.2), radius: 20)
            .padding(.horizontal, 24)
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let min = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", min, sec)
    }
}
