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

        // Bottom-anchored card with a light backdrop. Taps on the
        // backdrop are still blocked (so the exercise list above reads as
        // "on pause"), but the visual weight is dialed way back — you can
        // see what you just did without the app feeling hidden away.
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {} // blocks taps without dismissing

            VStack(spacing: 14) {
                // Small status header — confirms "rest" + shows HR inline
                // without a separate row.
                HStack(spacing: 10) {
                    Text("Rest")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondaryText)
                    if workoutVM.currentHeartRate > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundColor(.failedRed)
                            Text("\(Int(workoutVM.currentHeartRate))")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondaryText)
                        }
                    }
                    Spacer()
                    // Small undo link — deliberately demoted from a prominent
                    // block button. Rare action; shouldn't compete with Skip/Go.
                    Button {
                        workoutVM.undoLastSet()
                        onDismiss()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption2)
                            Text("Undo")
                                .font(.caption.bold())
                        }
                        .foregroundColor(.failedRed)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 16) {
                    // Ring + time — smaller than the centered version, same
                    // info. 110pt still reads from arm's length but leaves
                    // room for the action stack on the right.
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: ringProgress)
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: ringProgress)
                        VStack(spacing: 0) {
                            Text(displayTime)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(timerColor)
                            if isOverRest {
                                Text("over")
                                    .font(.caption2)
                                    .foregroundColor(timerColor.opacity(0.7))
                            }
                        }
                    }
                    .frame(width: 110, height: 110)

                    // Primary action + adjust stack on the right so the
                    // thumb lands naturally. Skip/Go gets the lion's share
                    // of visual weight — it's what the user reaches for.
                    VStack(spacing: 8) {
                        Button {
                            onDismiss()
                        } label: {
                            Text(isOverRest ? "Go" : "Skip")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(isOverRest ? Color.prGreen : Color.accentBlue)
                                .cornerRadius(12)
                        }
                        HStack(spacing: 8) {
                            Button {
                                workoutVM.adjustRestTimer(by: -30)
                            } label: {
                                Text("−30")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(Color.cardSurface)
                                    .cornerRadius(8)
                            }
                            Button {
                                workoutVM.adjustRestTimer(by: 30)
                            } label: {
                                Text("+30")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(Color.cardSurface)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.appBackground)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: -2)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let min = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", min, sec)
    }
}
