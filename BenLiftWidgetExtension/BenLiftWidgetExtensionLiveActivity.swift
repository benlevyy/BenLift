import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

struct BenLiftWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner presentation
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.currentExerciseName)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("\(context.state.setsCompleted)/\(context.state.totalSets) sets")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.heartRate > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                Text("\(context.state.heartRate)")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundColor(.white)
                            }
                        }
                        Text("\(context.state.totalVolume) lbs")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if context.state.isResting, let endDate = context.state.restEndDate {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.caption)
                                Text(timerInterval: Date.now...endDate, countsDown: true)
                                    .font(.subheadline.bold().monospacedDigit())
                                    .frame(maxWidth: 60)
                            }
                            .foregroundColor(.orange)
                        } else {
                            Text("\(context.state.exercisesCompleted)/\(context.attributes.totalExercises) exercises")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }

                        Spacer()

                        Button(intent: SwapExerciseIntent()) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                Text("Swap")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .tint(.green)
                    }
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } compactTrailing: {
                if context.state.isResting, let endDate = context.state.restEndDate {
                    Text(timerInterval: Date.now...endDate, countsDown: true)
                        .font(.caption.bold().monospacedDigit())
                        .foregroundColor(.orange)
                        .frame(maxWidth: 50)
                } else {
                    Text("\(context.state.setsCompleted)/\(context.state.totalSets)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundColor(.white)
                }
            } minimal: {
                Image(systemName: "dumbbell.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        LockScreenLiveActivityView(context: context)
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: isLuminanceReduced ? 6 : 10) {
            // Top: session name + elapsed timer
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "dumbbell.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text(context.attributes.sessionName)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                Spacer()
                Text(context.attributes.startDate, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: 70, alignment: .trailing)
            }

            // Current exercise + set progress
            HStack {
                Text(context.state.currentExerciseName)
                    .font((isLuminanceReduced ? Font.subheadline : Font.title3).bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text("\(context.state.setsCompleted)/\(context.state.totalSets)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, isLuminanceReduced ? 8 : 10)
                    .padding(.vertical, isLuminanceReduced ? 2 : 4)
                    .background(isLuminanceReduced ? Color.clear : Color.green.opacity(0.25))
                    .cornerRadius(8)
            }

            // Rest timer (when resting) — shown prominently
            if context.state.isResting, let endDate = context.state.restEndDate {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(isLuminanceReduced ? .subheadline : .body)
                        .foregroundColor(.orange)
                    Text("Rest")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(timerInterval: Date.now...endDate, countsDown: true)
                        .font((isLuminanceReduced ? Font.title3 : Font.title2).bold().monospacedDigit())
                        .foregroundColor(.orange)
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                .padding(isLuminanceReduced ? 4 : 8)
                .background(isLuminanceReduced ? Color.clear : Color.orange.opacity(0.15))
                .cornerRadius(8)
            }

            // Bottom row: HR + volume + swap
            HStack(spacing: isLuminanceReduced ? 10 : 14) {
                if context.state.heartRate > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text("\(context.state.heartRate)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.white)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "scalemass")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(context.state.totalVolume) lbs")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                }

                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(context.state.exercisesCompleted)/\(context.attributes.totalExercises)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                }

                Spacer()

                Button(intent: SwapExerciseIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        Text("Swap")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, isLuminanceReduced ? 10 : 12)
                    .padding(.vertical, isLuminanceReduced ? 4 : 6)
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, isLuminanceReduced ? 12 : 16)
        .padding(.top, isLuminanceReduced ? 22 : 20)
        .padding(.bottom, isLuminanceReduced ? 18 : 18)
    }
}

// MARK: - Previews

extension WorkoutActivityAttributes {
    fileprivate static var preview: WorkoutActivityAttributes {
        WorkoutActivityAttributes(sessionName: "Heavy Push", totalExercises: 6, startDate: .now)
    }
}

extension WorkoutActivityAttributes.ContentState {
    fileprivate static var active: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            currentExerciseName: "Bench Press",
            currentExerciseIndex: 1,
            setsCompleted: 2,
            totalSets: 4,
            restEndDate: nil,
            isResting: false,
            heartRate: 142,
            elapsedSeconds: 1230,
            totalVolume: 4520,
            exercisesCompleted: 1
        )
    }

    fileprivate static var resting: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            currentExerciseName: "Bench Press",
            currentExerciseIndex: 1,
            setsCompleted: 3,
            totalSets: 4,
            restEndDate: Date().addingTimeInterval(87),
            isResting: true,
            heartRate: 128,
            elapsedSeconds: 1340,
            totalVolume: 5040,
            exercisesCompleted: 1
        )
    }
}

#Preview("Notification", as: .content, using: WorkoutActivityAttributes.preview) {
    BenLiftWidgetExtensionLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.active
    WorkoutActivityAttributes.ContentState.resting
}
