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
        .preferredColorScheme(.dark)
        .onAppear {
            sharedProgramVM.loadCurrentProgram(modelContext: modelContext)
            // Auto-fetch recommendation on app open for Recovery tab
            // Uses default feeling (3/5) — user can refine on Today tab
            if sharedCoachVM.recommendation == nil {
                Task {
                    await sharedCoachVM.getRecommendation(
                        modelContext: modelContext,
                        program: sharedProgramVM.currentProgram
                    )
                }
            }
        }
    }
}
