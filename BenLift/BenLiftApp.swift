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
            // Today-override carrier — written by chat's set_focus, read by
            // the resolver ahead of the rotation.
            MuscleGroupPin.self,
            // Future cross-training the user has told the coach about.
            PlannedActivity.self,
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
            Self.retireImplicitExerciseRules(in: context)
            Self.backfillSessionCategories(in: context)
            Self.clearFutureDatedPins(in: context)
            PlannedActivity.pruneStale(in: context)
        }

        // One-shot: re-save the API key with AfterFirstUnlock so a locked
        // phone can still read it.
        if !UserDefaults.standard.bool(forKey: "didMigrateKeychainAccessibility") {
            KeychainService.migrateAccessibility(key: KeychainService.apiKeyKey)
            UserDefaults.standard.set(true, forKey: "didMigrateKeychainAccessibility")
        }

        WatchSyncService.shared.activate()
        // Custom exercises reach the watch via a queued transfer; sending
        // on launch covers lifts made before this existed. No-op when the
        // list hasn't changed since the last send.
        if failure == nil {
            WatchLibrarySync.pushCustomExercises(from: context)
        }

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

    /// The old app wrote an `exerciseOut` rule every time an exercise was
    /// removed from a plan. Those rules were advisory — prompt text the model
    /// could weigh against everything else — so removing bench once because
    /// the rack was busy quietly became a standing preference nobody agreed to.
    ///
    /// `PlanResolver` enforces rules in Swift instead, which is the right
    /// behaviour for a rule the user actually meant, and the wrong behaviour
    /// for a pile of inferred ones: promoting them all to hard filters
    /// retroactively can strip a replayed session down to almost nothing.
    ///
    /// So the accumulated ones are archived on first launch. They stay in the
    /// database (`isActive = false`), and anything genuinely wanted comes back
    /// by saying so in chat, which is now the only way a rule gets created.
    private static func retireImplicitExerciseRules(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: "didRetireImplicitRules") else { return }

        let descriptor = FetchDescriptor<UserRule>()
        if let rules = try? context.fetch(descriptor) {
            let implicit = rules.filter {
                $0.isActive && $0.kindRaw == UserRuleKind.exerciseOut.rawValue
            }
            for rule in implicit { rule.isActive = false }
            if !implicit.isEmpty {
                // Today's plan was already resolved against these rules and
                // persisted, and `resolve` deliberately never overwrites a
                // stored plan. Drop the unedited ones so the correction is
                // visible on this launch rather than tomorrow's.
                let planDescriptor = FetchDescriptor<DailyPlan>()
                if let plans = try? context.fetch(planDescriptor) {
                    for plan in plans where !plan.wasEdited {
                        context.delete(plan)
                    }
                }
                try? context.save()
                print("[BenLift] Archived \(implicit.count) inferred exerciseOut rule(s): \(implicit.map(\.subject).joined(separator: ", "))")
            }
        }
        UserDefaults.standard.set(true, forKey: "didRetireImplicitRules")
    }

    /// Manually-entered sessions were never labelled — `ManualWorkoutEntryView`
    /// didn't pass a `category` — so every one of them fell through to
    /// inference at read time. Inference then counted `core`, which belongs to
    /// all three categories, so mixed days scored near-ties and resolved
    /// arbitrarily. Hence long runs of days all labelled the same thing.
    ///
    /// Backfill the label once, from the exercises actually logged. Additive
    /// only: a session that already carries a category is never touched, and
    /// nothing about the exercises or sets changes.
    private static func backfillSessionCategories(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: "didBackfillSessionCategories") else { return }

        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        let lookup = Dictionary(
            exercises.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        var labelled = 0
        var undecided = 0
        for session in sessions where session.category == nil {
            if let inferred = PlanResolver.inferCategory(of: session, lookup: lookup) {
                session.category = inferred
                labelled += 1
            } else {
                // A genuine tie, or nothing recognisable. Left alone rather
                // than guessed at — that guessing is the bug.
                undecided += 1
            }
        }

        if labelled > 0 || undecided > 0 {
            try? context.save()
            print("[BenLift] Labelled \(labelled) session(s); \(undecided) left undecided")
        }
        UserDefaults.standard.set(true, forKey: "didBackfillSessionCategories")
    }

    /// Future-day pinning is gone — both the week strip's pin sheet and
    /// set_focus used to write pins for days to come, and nothing does now. A stale future pin left behind would still be
    /// honoured by the resolver when its day arrived, silently overriding
    /// the rotation with a decision nobody remembers making. Clear them once.
    private static func clearFutureDatedPins(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: "didClearFuturePins") else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let pins = try? context.fetch(FetchDescriptor<MuscleGroupPin>()) {
            let future = pins.filter { $0.date > today }
            for pin in future { context.delete(pin) }
            if !future.isEmpty {
                try? context.save()
                print("[BenLift] Cleared \(future.count) future-dated pin(s)")
            }
        }
        UserDefaults.standard.set(true, forKey: "didClearFuturePins")
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
