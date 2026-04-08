import SwiftUI

struct RestTimerView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    private var isOverRest: Bool {
        workoutVM.restTimerRemaining <= 0
    }

    private var displayTime: String {
        if isOverRest {
            return "+\(formatTime(abs(workoutVM.restTimerRemaining)))"
        }
        return formatTime(workoutVM.restTimerRemaining)
    }

    private var ringProgress: Double {
        guard workoutVM.restTimerDuration > 0 else { return 0 }
        if isOverRest { return 1.0 }
        return 1.0 - (workoutVM.restTimerRemaining / workoutVM.restTimerDuration)
    }

    private var ringColor: Color {
        if !isOverRest { return .blue }
        let over = abs(workoutVM.restTimerRemaining)
        if over < 30 { return .green }
        if over < 60 { return .yellow }
        return .red
    }

    private var timerColor: Color {
        if !isOverRest { return .white }
        let over = abs(workoutVM.restTimerRemaining)
        if over < 30 { return .green }
        if over < 60 { return .yellow }
        return .red
    }

    var body: some View {
        VStack(spacing: 6) {
            // Timer ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: ringProgress)

                VStack(spacing: 0) {
                    Text(displayTime)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(timerColor)

                    if isOverRest {
                        Text("over rest")
                            .font(.system(size: 9))
                            .foregroundColor(timerColor.opacity(0.7))
                    }
                }
            }
            .frame(width: 90, height: 90)

            // Elapsed + HR
            HStack(spacing: 16) {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(workoutVM.elapsedTime.formattedMinSec)
                        .font(.caption2.monospacedDigit())
                }

                if workoutVM.currentHeartRate > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                        Text("\(Int(workoutVM.currentHeartRate))")
                            .font(.caption2.monospacedDigit())
                    }
                }
            }

            // Controls
            HStack(spacing: 12) {
                Button {
                    workoutVM.adjustRestTimer(by: -30)
                } label: {
                    Text("-30")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)

                Button {
                    workoutVM.skipRest()
                } label: {
                    Text(isOverRest ? "Go" : "Skip")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(isOverRest ? .green : .gray)

                Button {
                    workoutVM.adjustRestTimer(by: 30)
                } label: {
                    Text("+30")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let min = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", min, sec)
    }
}
