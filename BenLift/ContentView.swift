import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sharedCoachVM = CoachViewModel()
    @State private var sharedProgramVM = ProgramViewModel()

    var body: some View {
        TabView {
            TodayView(coachVM: sharedCoachVM, programVM: sharedProgramVM)
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            ProgramOverview(coachVM: sharedCoachVM, programVM: sharedProgramVM)
                .tabItem {
                    Label("Recovery", systemImage: "heart.text.square")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.light)
        .onAppear {
            sharedProgramVM.loadCurrentProgram(modelContext: modelContext)
            // Auto-fire recommendation → plan on app open
            if sharedCoachVM.recommendation == nil && sharedCoachVM.editedExercises.isEmpty {
                Task {
                    await sharedCoachVM.getRecommendationAndPlan(
                        modelContext: modelContext,
                        program: sharedProgramVM.currentProgram
                    )
                }
            }
        }
    }
}
