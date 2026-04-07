import SwiftUI

struct RestTimerView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    var body: some View {
        let progress = 1.0 - (workoutVM.restTimerRemaining / workoutVM.restTimerDuration)

        VStack(spacing: 16) {
            // Circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                // Countdown
                Text(TimeInterval(workoutVM.restTimerRemaining).formattedMinSec)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 120, height: 120)

            // Skip button
            Button {
                workoutVM.skipRest()
            } label: {
                Text("Skip")
                    .font(.body)
            }
            .buttonStyle(.bordered)
        }
    }
}
