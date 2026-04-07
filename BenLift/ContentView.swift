import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            ProgramOverview()
                .tabItem {
                    Label("Program", systemImage: "chart.bar.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.dark)
    }
}
