import SwiftUI
import SwiftData

@main
struct BenLiftApp: App {
    let container: ModelContainer
    let syncManager: WorkoutSyncManager

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
            UserProfile.self,
            UserIntelligence.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        container = try! ModelContainer(for: schema, configurations: config)
        print("[BenLift] SwiftData container initialized")

        // Seed default exercises on first launch
        let context = container.mainContext
        DefaultExercises.seedIfNeeded(in: context)

        // Migrate: seed UserIntelligence from existing coaching profile data
        let intelDescriptor = FetchDescriptor<UserIntelligence>()
        if (try? context.fetchCount(intelDescriptor)) == 0 {
            let intel = UserIntelligence()

            let programDescriptor = FetchDescriptor<TrainingProgram>(
                predicate: #Predicate { $0.isActive == true }
            )
            if let program = try? context.fetch(programDescriptor).first {
                intel.injuries = program.ongoingConcerns ?? ""
                intel.userNotes = [program.coachingStyle, program.customCoachNotes]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ". ")
            }

            let profileDescriptor = FetchDescriptor<UserProfile>()
            if let profile = try? context.fetch(profileDescriptor).first, !profile.profileText.isEmpty {
                intel.pendingObservations = profile.profileText
            }

            context.insert(intel)
            try? context.save()
            print("[BenLift] UserIntelligence seeded from existing data")
        }

        // Debug: check API key status
        let hasKey = KeychainService.load(key: KeychainService.apiKeyKey) != nil
        print("[BenLift] API key in Keychain: \(hasKey)")

        // Activate WatchConnectivity
        WatchSyncService.shared.activate()

        // Start background sync manager — persists Watch results to SwiftData
        // regardless of which view is active
        syncManager = WorkoutSyncManager(container: container)
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
