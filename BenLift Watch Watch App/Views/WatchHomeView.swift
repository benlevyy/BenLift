import SwiftUI

struct WatchHomeView: View {
    @ObservedObject var workoutVM: WorkoutViewModel
    @State private var receivedPlan: WatchWorkoutPlan?
    /// Latest phone-owned snapshot received. When present and active, we
    /// show a "Workout on phone" card that opens a read-only mirror view —
    /// so a user who started on phone can glance at their wrist.
    @State private var phoneSnapshot: WorkoutSnapshot?

    private var phoneSessionActive: Bool {
        phoneSnapshot?.isActive == true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Active phone-owned workout — tap to view on watch. Takes
                // precedence over Plan Ready (if both were somehow set),
                // since an active session is more relevant than a pending
                // one.
                if phoneSessionActive, let snap = phoneSnapshot {
                    Button {
                        workoutVM.applyPhoneSnapshot(snap)
                        // `applyPhoneSnapshot` only switches screens on
                        // first-apply (to avoid re-presenting mid-session).
                        // When the user taps the card after having backed
                        // out to Home, we want the mirror view to come up
                        // again — force it.
                        workoutVM.currentScreen = .exerciseList
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "iphone.and.arrow.forward")
                                Text("On Phone")
                            }
                            .font(.headline)

                            Text(snap.sessionName ?? "Workout")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))

                            Text("\(snap.exercises.count) exercises")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentBlue)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                } else if let plan = receivedPlan {
                    // AI plan pushed from phone — tap to start watch-owned.
                    Button {
                        workoutVM.startWorkout(with: plan)
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Plan Ready")
                            }
                            .font(.headline)

                            Text(plan.sessionName ?? "Workout")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))

                            Text("\(plan.exercises.count) exercises")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentBlue)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }

                // Manual workout fallback — start a blank session and add
                // exercises on the fly via the hub. Visible even when a plan
                // is ready, so the user is never forced into a pushed plan.
                Button {
                    workoutVM.startEmptyWorkout()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Start Empty Workout")
                            .font(.body.bold())
                        Spacer()
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .navigationTitle("BenLift")
        .onAppear {
            receivedPlan = WatchSyncService.shared.receivedPlan
            phoneSnapshot = WatchSyncService.shared.receivedPhoneSnapshot
        }
        .onReceive(NotificationCenter.default.publisher(for: .workoutPlanReceived)) { _ in
            receivedPlan = WatchSyncService.shared.receivedPlan
        }
        .onReceive(NotificationCenter.default.publisher(for: .phoneOwnedSnapshotReceived)) { _ in
            phoneSnapshot = WatchSyncService.shared.receivedPhoneSnapshot
        }
    }
}
