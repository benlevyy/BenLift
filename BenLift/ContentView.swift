import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sharedCoachVM = CoachViewModel()
    @State private var sharedProgramVM = ProgramViewModel()
    @State private var sharedIntelligenceVM = IntelligenceViewModel()

    /// App-scoped mirroring controller — owns the PhoneWorkoutViewModel and the
    /// sheet-presentation flag. Injected from BenLiftApp so callbacks were wired
    /// before HK could deliver any events.
    @Bindable var phoneMirroring: PhoneMirroringController

    var body: some View {
        TabView {
            TodayView(
                coachVM: sharedCoachVM,
                programVM: sharedProgramVM,
                phoneMirroring: phoneMirroring
            )
                .tabItem {
                    Label("Today", systemImage: "figure.strengthtraining.traditional")
                }

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            ProgramOverview(coachVM: sharedCoachVM, programVM: sharedProgramVM, intelligenceVM: sharedIntelligenceVM)
                .tabItem {
                    // Training > Recovery — the tab is really the training
                    // dashboard (muscle map + volume + trends + intelligence),
                    // not just recovery. Chart icon fits the trend-y content.
                    Label("Training", systemImage: "chart.bar.xaxis")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.light)
        // .sheet w/ .large detent presents ~2× faster than .fullScreenCover
        // (snappier slide). Drag indicator hidden + interactive-dismiss
        // disabled (PhoneWorkoutView already does this internally) so the
        // visual is indistinguishable from a full-screen cover.
        .sheet(isPresented: $phoneMirroring.showPhoneWorkout) {
            PhoneWorkoutView(
                workoutVM: phoneMirroring.phoneWorkoutVM,
                programVM: sharedProgramVM
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .onAppear {
            sharedProgramVM.loadCurrentProgram(modelContext: modelContext)
            sharedIntelligenceVM.loadIntelligence(modelContext: modelContext)
            // Auto-fire recommendation → plan on app open (skip if cached and nothing changed)
            if !sharedCoachVM.shouldSkipRegeneration(modelContext: modelContext) {
                Task {
                    await sharedCoachVM.getRecommendationAndPlan(
                        modelContext: modelContext,
                        program: sharedProgramVM.currentProgram
                    )
                }
            }

            // If Watch workout is already active at launch, join it.
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
            }
        }
    }
}
