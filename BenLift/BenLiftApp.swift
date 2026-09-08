import SwiftUI
import SwiftData

@main
struct BenLiftApp: App {
    let container: ModelContainer
    let syncManager: WorkoutSyncManager?
    let phoneMirroring: PhoneMirroringController
    /// Non-nil when the store could not be opened. Surfaced as a recovery
    /// screen instead of a launch crash.
    let storeFailure: String?

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
            ActivityLog.self,
            SessionEvent.self,
            // Durable user decisions the resolver enforces in Swift.
            UserRule.self,
            // Calendar / week strip.
            MuscleGroupPin.self,
            SeedPattern.self,
            // Chat-first rebuild: the deterministic plan, the daily thread,
            // and the API spend log.
            DailyPlan.self,
            PlannedLift.self,
            ChatThread.self,
            ChatMessage.self,
            AIUsageLog.self,
        ])

        // A schema migration failure used to be `try!` — an unrecoverable
        // launch crash with the user's whole training history behind it.
        // Now it degrades to an in-memory store plus a visible explanation,
        // so the app opens and the data on disk is left untouched for
        // recovery rather than being silently replaced.
        var failure: String?
        var resolved: ModelContainer
        do {
            resolved = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
            print("[BenLift] SwiftData container initialized")
        } catch {
            failure = "\(error)"
            print("[BenLift] Store failed to open: \(error)")
            resolved = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        container = resolved
        storeFailure = failure

        let context = container.mainContext
        if failure == nil {
            DefaultExercises.seedIfNeeded(in: context)
            Self.migrateGoalTextIfNeeded(in: context)
        }

        // One-shot: re-save the API key with AfterFirstUnlock so a locked
        // phone can still read it.
        if !UserDefaults.standard.bool(forKey: "didMigrateKeychainAccessibility") {
            KeychainService.migrateAccessibility(key: KeychainService.apiKeyKey)
            UserDefaults.standard.set(true, forKey: "didMigrateKeychainAccessibility")
        }

        WatchSyncService.shared.activate()

        phoneMirroring = PhoneMirroringController()
        phoneMirroring.phoneWorkoutVM.modelContext = container.mainContext

        syncManager = failure == nil ? WorkoutSyncManager(container: container) : nil

        LiveActivityManager.shared.endAnyActivity()
        NotificationService.shared.bootstrap()
    }

    /// Fold the nine deprecated coaching-profile columns into the single
    /// `goalText` field. Runs once; leaves the old columns alone so nothing
    /// is lost if this needs revisiting.
    private static func migrateGoalTextIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: "didMigrateGoalText") else { return }

        let descriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true }
        )
        if let program = try? context.fetch(descriptor).first, program.goalText.isEmpty {
            let parts: [String?] = [
                program.goal.isEmpty ? nil : program.goal,
                program.specificTargets,
                program.musclePriorities,
                program.otherActivities,
                program.activitySchedule,
                program.ongoingConcerns,
                program.recoveryNotes,
                program.coachingStyle,
                program.customCoachNotes
            ]
            let merged = parts
                .compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ". ")

            if !merged.isEmpty {
                program.goalText = merged
                try? context.save()
                print("[BenLift] Folded coaching profile into goalText")
            }
        }
        UserDefaults.standard.set(true, forKey: "didMigrateGoalText")
    }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if let storeFailure {
                StoreFailureView(message: storeFailure)
            } else if hasCompletedOnboarding {
                ContentView(phoneMirroring: phoneMirroring)
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
        .modelContainer(container)
    }
}

/// Shown when the on-disk store can't be opened. The app is running on an
/// in-memory store, so nothing written now will persist — say so plainly
/// rather than letting the user log a session into the void.
struct StoreFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(Color.failedRed)

            Text("Can't open your training data")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.primaryText)

            Text("""
            Your history is still on the device — the app just couldn't load \
            it this launch. Nothing you do right now will be saved. Try \
            reopening; if it keeps happening, the detail below is what went \
            wrong.
            """)
            .font(.system(size: 14))
            .foregroundStyle(Color.bodyText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
