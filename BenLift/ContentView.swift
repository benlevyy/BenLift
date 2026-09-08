import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var chatVM = ChatViewModel()
    @State private var programVM = ProgramViewModel()

    /// App-scoped mirroring controller — owns the PhoneWorkoutViewModel and
    /// the sheet-presentation flag. Injected from BenLiftApp so callbacks
    /// were wired before HealthKit could deliver any events.
    @Bindable var phoneMirroring: PhoneMirroringController

    var body: some View {
        TabView {
            TodayChatView(chatVM: chatVM, phoneMirroring: phoneMirroring)
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            HubView(programVM: programVM)
                .tabItem {
                    Label("Hub", systemImage: "chart.line.uptrend.xyaxis")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.light)
        // .sheet w/ .large detent presents ~2x faster than .fullScreenCover.
        // Drag indicator hidden + interactive dismiss disabled (PhoneWorkoutView
        // does this internally) so it reads as a full-screen cover.
        .sheet(isPresented: $phoneMirroring.showPhoneWorkout) {
            PhoneWorkoutView(
                workoutVM: phoneMirroring.phoneWorkoutVM,
                chatVM: chatVM
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .onAppear {
            programVM.loadCurrentProgram(modelContext: modelContext)
            // No network call here, deliberately. The plan is resolved from
            // history in Swift — opening the app never waits on a model.
            chatVM.load(modelContext: modelContext)

            if WatchSyncService.shared.isWorkoutActive {
                phoneMirroring.joinActiveWorkoutIfNeeded()
            }
        }
        .onChange(of: WatchSyncService.shared.isWorkoutActive) { _, isActive in
            if isActive {
                phoneMirroring.handleWatchSessionWorkoutStarted()
            } else {
                phoneMirroring.handleWatchSessionWorkoutEnded()
            }
        }
        .onChange(of: phoneMirroring.phoneWorkoutVM.isWorkoutActive) { _, isActive in
            if !isActive {
                phoneMirroring.handlePhoneWorkoutEnded()
                // Re-resolve so a freshly-saved session feeds tomorrow's
                // rotation immediately rather than on next launch.
                chatVM.load(modelContext: modelContext)
            }
        }
    }
}
