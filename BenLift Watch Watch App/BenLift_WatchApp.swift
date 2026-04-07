import SwiftUI

@main
struct BenLift_Watch_Watch_AppApp: App {
    @StateObject private var workoutVM = WorkoutViewModel()

    init() {
        WatchSyncService.shared.activate()
        print("[BenLift/Watch] App launched")
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(workoutVM: workoutVM)
        }
    }
}

struct WatchRootView: View {
    @ObservedObject var workoutVM: WorkoutViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch workoutVM.currentScreen {
                case .home:
                    WatchHomeView(workoutVM: workoutVM)
                case .exerciseList:
                    ExerciseListHubView(workoutVM: workoutVM)
                case .exercise:
                    ExerciseView(workoutVM: workoutVM)
                case .restTimer:
                    RestTimerView(workoutVM: workoutVM)
                case .summary:
                    WorkoutSummaryView(workoutVM: workoutVM)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: workoutVM.currentScreen)
        }
    }
}
