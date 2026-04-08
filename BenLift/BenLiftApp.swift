import SwiftUI
import SwiftData

@main
struct BenLiftApp: App {
    let container: ModelContainer

    init() {
        print("[BenLift] App launching...")
        let schema = Schema([
            Exercise.self,
            WorkoutTemplate.self,
            TemplateExercise.self,
            WorkoutSession.self,
            ExerciseEntry.self,
            SetLog.self,
            TrainingProgram.self,
            PostWorkoutAnalysis.self,
            WeeklyReview.self,
            ActivityLog.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        container = try! ModelContainer(for: schema, configurations: config)
        print("[BenLift] SwiftData container initialized")

        // Seed default exercises on first launch
        let context = container.mainContext
        DefaultExercises.seedIfNeeded(in: context)

        // Debug: check API key status
        let hasKey = KeychainService.load(key: KeychainService.apiKeyKey) != nil
        print("[BenLift] API key in Keychain: \(hasKey)")

        // Activate WatchConnectivity
        WatchSyncService.shared.activate()
    }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
        .modelContainer(container)
    }
}
