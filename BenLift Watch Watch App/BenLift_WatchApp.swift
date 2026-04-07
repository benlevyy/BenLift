import SwiftUI

@main
struct BenLift_Watch_Watch_AppApp: App {
    @StateObject private var workoutVM = WorkoutViewModel()

    init() {
        // Activate WatchConnectivity
        WatchSyncService.shared.activate()
        print("[BenLift/Watch] App launched")
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(workoutVM: workoutVM)
        }
    }
}

/// Root view that switches screens based on WorkoutViewModel state
struct WatchRootView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch workoutVM.currentScreen {
                case .home:
                    WatchHomeView(workoutVM: workoutVM)
                case .exercise:
                    ExerciseView(workoutVM: workoutVM)
                case .restTimer:
                    RestTimerView(workoutVM: workoutVM)
                case .transition:
                    TransitionView(workoutVM: workoutVM)
                case .summary:
                    WorkoutSummaryView(workoutVM: workoutVM)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: workoutVM.currentScreen)
        }
    }
}
