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

    /// One line on what the rest is for. Nil when nothing is active.
    private var upNextLabel: String? {
        guard let ex = workoutVM.activeExercise else { return nil }
        if ex.isComplete {
            return "\(ex.info.name) done · back to list"
        }
        var line = "Next: \(ex.info.name) · set \(ex.workingSetsCompleted + 1) of \(ex.targetSets)"
        // currentWeight is what the next set will log; suggestedWeight is
        // only the plan's opening number. 0 means bodyweight, so say nothing.
        if workoutVM.currentWeight > 0 {
            line += " · \(workoutVM.currentWeight.formattedLoad)"
        }
        return line
    }

    var body: some View {
        // Tight: this is a VStack with no ScrollView and has to fit 41mm.
        VStack(spacing: 4) {
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

            // What's next
            if let upNext = upNextLabel {
                Text(upNext)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            // Elapsed + HR
            HStack(spacing: 16) {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    // Same reason as the hub header: elapsed is derived, so
                    // it needs its own tick or it freezes between sets.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(workoutVM.elapsedTime.formattedMinSec)
                            .font(.caption2.monospacedDigit())
                    }
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
