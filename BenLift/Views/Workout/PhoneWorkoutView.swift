import SwiftUI
import SwiftData

/// Root container for iPhone workout execution. Presented as fullScreenCover from TodayView.
struct PhoneWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var workoutVM: PhoneWorkoutViewModel
    var programVM: ProgramViewModel
    @State private var navigationPath: [Int] = [] // exercise indices
    @State private var showAdaptSheet = false
    /// Mode the adapt sheet should open in. Set by the caller before flipping
    /// `showAdaptSheet` so the sheet doesn't have to sniff VM state.
    @State private var adaptSheetMode: MidWorkoutAdaptSheet.Mode = .manual
    @State private var showFinishSheet = false
    /// Tracks the `restEndsAt` value the user has dismissed locally. The rest overlay
    /// stays hidden until the watch sends a new snapshot with a different restEndsAt
    /// (a new rest period). Lets the user dismiss the overlay even if the watch is slow
    /// to ack the skipRest command.
    @State private var locallyDismissedRest: Date?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if workoutVM.snapshot == nil {
                // Skeleton state — waiting for first snapshot from watch
                connectingState
            } else {
                NavigationStack(path: $navigationPath) {
                    VStack(spacing: 0) {
                        // Persistent top bar
                        topBar

                        // Exercise list hub
                        PhoneExerciseListView(
                            workoutVM: workoutVM,
                            onSelectExercise: { index in
                                workoutVM.selectExercise(at: index)
                                navigationPath.append(index)
                            },
                            onAdapt: {
                                adaptSheetMode = .manual
                                showAdaptSheet = true
                            },
                            onSwap: { index in
                                // Swipe-left swap: auto-fill "user requested
                                // alternative" reason, fire the LLM, open the
                                // adapt sheet in compact mode where the result
                                // renders with a single Accept button.
                                workoutVM.adaptTargetIndex = index
                                adaptSheetMode = .swipe
                                showAdaptSheet = true
                                Task {
                                    await workoutVM.swipeSwap(
                                        at: index,
                                        program: programVM.currentProgram
                                    )
                                }
                            },
                            onFinish: { showFinishSheet = true }
                        )
                    }
                    .navigationDestination(for: Int.self) { index in
                        PhoneExerciseDetailView(
                            workoutVM: workoutVM,
                            exerciseIndex: index,
                            onAdaptExercise: {
                                workoutVM.adaptTargetIndex = index
                                showAdaptSheet = true
                            },
                            onComplete: {
                                navigationPath.removeLast()
                            }
                        )
                    }
                }

                // Rest timer overlay — hide if the user has locally dismissed THIS rest
                let restEnd = workoutVM.restEndsAt
                let shouldShowRest = workoutVM.isResting && restEnd != locallyDismissedRest
                if shouldShowRest {
                    PhoneRestTimerView(workoutVM: workoutVM) {
                        // Optimistic local dismissal — hide immediately, snapshot
                        // will eventually catch up. Avoids the "tap mash" loop when
                        // watch reachability flaps.
                        locallyDismissedRest = restEnd
                        workoutVM.skipRest()
                        if workoutVM.shouldReturnToListAfterRest {
                            navigationPath.removeAll()
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: workoutVM.isResting)
        .sheet(isPresented: $showAdaptSheet) {
            MidWorkoutAdaptSheet(
                workoutVM: workoutVM,
                program: programVM.currentProgram,
                mode: adaptSheetMode
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFinishSheet) {
            FinishWorkoutSheet(workoutVM: workoutVM) { effort in
                workoutVM.finishWorkout(
                    modelContext: modelContext,
                    feeling: nil,
                    concerns: nil,
                    effortScore: effort
                )
                showFinishSheet = false
                dismiss()
            } onCancel: {
                showFinishSheet = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .interactiveDismissDisabled(workoutVM.isWorkoutActive || workoutVM.snapshot == nil)
        .onReceive(NotificationCenter.default.publisher(for: .liveActivitySwapTapped)) { _ in
            showAdaptSheet = true
        }
    }

    // MARK: - Connecting Skeleton

    private var connectingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.secondaryText)
                .symbolEffect(.pulse)
            Text("Connecting to Apple Watch…")
                .font(.headline)
            Text("Open BenLift on your watch to start a workout")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Cancel") {
                dismiss()
            }
            .padding(.top, 8)
        }
        .task {
            // Self-dismiss if no snapshot arrives in 10s — protects against
            // ghost-session state where HK mirroring or WCSession fired a
            // "workout started" signal but the watch never actually sent a
            // snapshot (crash, lost connection, pre-Slice-1 stale cache).
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if workoutVM.snapshot == nil {
                print("[BenLift/Phone] No snapshot after 10s — dismissing ghost session")
                dismiss()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // Elapsed time
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(workoutVM.elapsedTime.formattedMinSec)
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundColor(.primary)
            }

            // Heart rate
            if workoutVM.currentHeartRate > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundColor(.failedRed)
                    Text("\(Int(workoutVM.currentHeartRate))")
                        .font(.subheadline.bold().monospacedDigit())
                }
            }

            Spacer()

            // Volume
            Text("\(Int(workoutVM.totalVolume)) lbs")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondaryText)

            // End workout button
            Button {
                showFinishSheet = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.cardSurface)
    }
}

// MARK: - Finish Workout Sheet

/// Post-"End Workout" confirmation with an Apple-style 1...10 effort picker
/// (RPE/Workout Effort). The picked score is passed to `finishWorkout` so
/// the watch can attach it to the saved HKWorkout via
/// `HKWorkoutEffortRelationship`. "Skip" saves the workout without effort.
private struct FinishWorkoutSheet: View {
    @Bindable var workoutVM: PhoneWorkoutViewModel
    let onConfirm: (Double?) -> Void
    let onCancel: () -> Void

    @State private var effort: Int = 6

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Rate Effort")
                    .font(.title2.bold())
                Text(effortLabel(effort))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: effort)
            }
            .padding(.top, 12)

            // Stats strip — monochrome, no cards. Lets the picker breathe.
            HStack(spacing: 24) {
                stat("\(workoutVM.totalSetsCompleted)", "sets")
                stat("\(Int(workoutVM.totalVolume))", "lbs")
                stat(workoutVM.elapsedTime.formattedMinSec, "time")
                if workoutVM.currentHeartRate > 0 {
                    stat("\(Int(workoutVM.currentHeartRate))", "bpm")
                }
            }
            .foregroundColor(.secondary)

            // Big number + slider. One affordance, one gesture.
            VStack(spacing: 16) {
                Text("\(effort)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: effort)
                    .foregroundColor(.primary)

                Slider(
                    value: Binding(
                        get: { Double(effort) },
                        set: { effort = max(1, min(10, Int($0.rounded()))) }
                    ),
                    in: 1...10,
                    step: 1
                ) {
                    Text("Effort")
                } minimumValueLabel: {
                    Text("1").font(.caption2).foregroundColor(.secondary)
                } maximumValueLabel: {
                    Text("10").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .sensoryFeedback(.selection, trigger: effort)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    onConfirm(Double(effort))
                } label: {
                    Text("Save Workout")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .sensoryFeedback(.success, trigger: 0)

                Button("Skip rating") {
                    onConfirm(nil)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
        }
        .padding(20)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }

    private func effortLabel(_ score: Int) -> String {
        switch score {
        case 1...2: return "Easy"
        case 3...4: return "Light"
        case 5...6: return "Moderate"
        case 7...8: return "Hard"
        case 9: return "Very Hard"
        default: return "All Out"
        }
    }
}
