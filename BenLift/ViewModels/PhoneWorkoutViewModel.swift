import SwiftUI
import SwiftData
import ActivityKit

/// Phone-side workout view model. **Mirror only** in v1 — the Watch is always the
/// authoritative owner of the in-progress state. This class:
///   1. Holds the latest `WorkoutSnapshot` received from the watch
///   2. Tracks LOCAL input state (currentWeight/Reps wheels, viewing index)
///   3. Sends `WorkoutCommand`s to the watch when the user takes an action
///
/// It does NOT mutate workout state itself. The next snapshot is the answer.
@Observable
class PhoneWorkoutViewModel {

    // MARK: - Workout Mode (kept for compat; v1 is mirror-only)

    enum WorkoutMode {
        case standalone         // Phone-only (deferred — falls back to mirror in v1)
        case mirroredFromWatch  // Watch is owner, phone reflects snapshots
    }

    var workoutMode: WorkoutMode = .mirroredFromWatch

    // MARK: - The single source of truth

    /// Latest snapshot received from the watch. Nil before first connect.
    var snapshot: WorkoutSnapshot?

    // MARK: - Local input state (NEVER overwritten by snapshots)

    var currentWeight: Double = 0
    var currentReps: Double = 0
    var weightIncrement: Double = 5.0

    /// Phone's currently-viewed exercise. May differ from `snapshot.activeExerciseIndex`
    /// while user is browsing. Selecting an exercise on phone sends a command to align.
    var viewingExerciseIndex: Int? = nil

    // MARK: - Lifecycle / UI flags

    var justFinishedAt: Date?  // suppresses phantom re-presentation just after a finish

    /// Sets the user has logged on the phone but that haven't yet been reflected in
    /// a snapshot from the watch. Overlaid on top of `snapshot.exercises` so the user
    /// sees their action immediately. Cleared as the matching set appears in the snapshot.
    /// This is the optimistic UI layer that makes the phone feel responsive even when
    /// the watch is briefly unreachable (sleeping wrist, BT flap, etc.).
    var pendingSets: [PendingSet] = []

    /// Count of pending sets that were dropped on the most recent snapshot
    /// apply because they aged past `pendingStaleThreshold` without a matching
    /// set appearing. UI can watch this to show a "couldn't sync to watch" toast
    /// and let the user re-log if the ghost set disappearing was unexpected.
    var droppedStalePendingCount: Int = 0

    /// Pending sets older than this without a snapshot match are considered
    /// undelivered and dropped. Tuned for normal BT flaps (~1-3s) plus a
    /// generous cushion — anything past this and the command probably never
    /// landed (no active mirrored session, watch app was backgrounded, etc.).
    static let pendingStaleThreshold: TimeInterval = 15.0

    struct PendingSet: Identifiable {
        let id: UUID = UUID()
        let exerciseIndex: Int
        let set: WatchSetResult
        let sentAt: Date
        /// True when the `sendToWatch` attempt reported that no mirrored
        /// session was available to deliver on — effectively this pending is
        /// starting life already-undelivered. Used to surface immediate
        /// feedback rather than waiting out the stale timeout.
        let delivered: Bool

        /// Undelivered pending sets get a shorter grace window — the command
        /// provably never reached the watch, so waiting the full stale
        /// threshold just leaves a lie on screen. Delivered ones wait longer
        /// because a legitimate snapshot is usually imminent.
        func isStale(now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(sentAt)
            let threshold: TimeInterval = delivered
                ? PhoneWorkoutViewModel.pendingStaleThreshold
                : PhoneWorkoutViewModel.undeliveredGracePeriod
            return age > threshold
        }
    }

    /// Short window before an undelivered (send-failed) pending set is
    /// dropped. Kept >0 so the UI flickers briefly instead of ignoring the
    /// tap outright — which felt broken in manual testing.
    static let undeliveredGracePeriod: TimeInterval = 3.0

    /// True while any pending set has crossed the stale threshold OR was
    /// marked undelivered at send time. Drives a disconnected-banner on the UI.
    var hasUndeliveredPending: Bool {
        let now = Date()
        return pendingSets.contains { $0.isStale(now: now) }
    }

    /// Exercise names the user has swiped-skipped locally but whose snapshot
    /// hasn't yet reflected the change. Overlaid on `exerciseStates` to ghost
    /// the card instantly. Cleared when the snapshot catches up.
    var optimisticallySkipped: Set<String> = []

    /// ModelContext for persisting SessionEvents as the AI learning log.
    /// Injected from the app at launch so we don't need to thread it through
    /// every mutation. Optional because some tests run without SwiftData.
    var modelContext: ModelContext?

    /// When we last got a snapshot from the watch. Used to show a "Reconnecting…"
    /// banner when the watch goes quiet for >5 seconds during an active workout.
    var lastSnapshotReceivedAt: Date?

    /// Periodic sweep that drops pending sets which aged past the stale
    /// threshold with no matching snapshot. Covers the "watch is fully
    /// disconnected, no snapshot will arrive to trigger reconciliation" case —
    /// without this, undelivered pending sets linger in the UI forever.
    private var pendingSweepTimer: Timer?

    // Activity signature used to debounce the abandon-reminder reschedule so it only
    // resets on real user actions (sets logged, exercise changed), not HR updates.
    private var lastActivitySignature: String?
    /// `workoutStartDate` of the session we last ran first-snapshot init for.
    /// Prevents duplicate LiveActivity starts + reminder notifications when a
    /// session flickers active→inactive→active (rare watch crash-restart).
    private var lastInitializedSessionStart: Date?
    /// True if we should show a "watch disconnected" banner.
    var isWatchStale: Bool {
        guard isWorkoutActive else { return false }
        guard let last = lastSnapshotReceivedAt else { return false }
        return Date().timeIntervalSince(last) > 5.0
    }

    // MARK: - Mid-Workout Adapt (UI state, AI calls happen on phone)

    var isAdapting: Bool = false
    var adaptSuggestion: MidWorkoutAdaptResponse?
    var adaptError: String?
    var adaptTargetIndex: Int?

    /// Mid-workout adjustments the user has accepted this session.
    /// Passed into subsequent adapt prompts so the model can spot patterns
    /// (e.g., 3 consecutive pressing swaps -> infer shoulder issue).
    /// Cleared on workout start/end.
    var workoutAdjustments: [AdjustmentRecord] = []

    // MARK: - Compat: nested type alias so existing views can keep saying
    // `PhoneWorkoutViewModel.ExerciseState`
    typealias ExerciseState = SnapshotExercise

    // MARK: - Computed: read-through to snapshot

    /// Snapshot exercises with optimistic pending sets overlaid. Views read this
    /// instead of the raw snapshot so user actions show up immediately.
    var exerciseStates: [SnapshotExercise] {
        guard let base = snapshot?.exercises else { return [] }
        if pendingSets.isEmpty && optimisticallySkipped.isEmpty { return base }
        return base.enumerated().map { idx, ex in
            let appended = pendingSets.filter { $0.exerciseIndex == idx }.map(\.set)
            // Overlay the optimistic skip flag so the card ghosts immediately;
            // the real flag lands on the next snapshot and this Set clears.
            let optimisticSkip = optimisticallySkipped.contains(ex.name) ? true : nil
            let mergedSkipped = ex.isSkipped ?? optimisticSkip
            if appended.isEmpty && mergedSkipped == ex.isSkipped { return ex }
            return SnapshotExercise(
                name: ex.name,
                targetSets: ex.targetSets,
                targetReps: ex.targetReps,
                suggestedWeight: ex.suggestedWeight,
                warmupSets: ex.warmupSets,
                intent: ex.intent,
                notes: ex.notes,
                lastWeight: ex.lastWeight,
                lastReps: ex.lastReps,
                loggedSets: ex.loggedSets + appended,
                isWarmupPhase: ex.isWarmupPhase,
                isSkipped: mergedSkipped
            )
        }
    }
    var activeExerciseIndex: Int? { snapshot?.activeExerciseIndex }
    var sessionName: String? { snapshot?.sessionName }
    var sessionStrategy: String? { snapshot?.sessionStrategy }
    var category: WorkoutCategory? { snapshot?.category }
    var muscleGroups: [MuscleGroup] {
        snapshot?.muscleGroups.compactMap { MuscleGroup(rawValue: $0) } ?? []
    }
    var isWorkoutActive: Bool { snapshot?.isActive ?? false }
    var workoutStartDate: Date? { snapshot?.workoutStartDate }
    var currentHeartRate: Double { snapshot?.currentHeartRate ?? 0 }
    var activeCalories: Double { snapshot?.activeCalories ?? 0 }

    var activeExercise: SnapshotExercise? {
        guard let idx = activeExerciseIndex, idx < exerciseStates.count else { return nil }
        return exerciseStates[idx]
    }

    var activeExerciseInfo: WatchExerciseInfo? { activeExercise?.info }

    /// Per-exercise increment based on equipment (2.5 for cables/dumbbells/pin-machines,
    /// 5 for barbells/kettlebells). Prefers the snapshot's equipment if the watch sent
    /// one; else looks it up by name in `DefaultExercises`; else falls back to the
    /// user's global `weightIncrement` setting.
    var effectiveWeightIncrement: Double {
        let equipment = activeExerciseInfo?.equipment
            ?? DefaultExercises.all.first(where: { $0.name == activeExerciseInfo?.name })?.equipment
        if let equipment {
            let inc = equipment.defaultIncrement
            return inc > 0 ? inc : weightIncrement
        }
        return weightIncrement
    }

    /// What the user is currently looking at on the phone — may not match watch's active.
    var viewingExercise: SnapshotExercise? {
        guard let idx = viewingExerciseIndex, idx < exerciseStates.count else { return activeExercise }
        return exerciseStates[idx]
    }

    var elapsedTime: TimeInterval {
        guard let start = workoutStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var totalVolume: Double {
        exerciseStates.reduce(0) { $0 + $1.totalVolume }
    }

    var totalSetsCompleted: Int {
        exerciseStates.reduce(0) { $0 + $1.workingSetsCompleted }
    }

    var allExercisesComplete: Bool {
        !exerciseStates.isEmpty && exerciseStates.allSatisfy(\.isComplete)
    }

    var isWarmupPhase: Bool { activeExercise?.isWarmupPhase ?? false }
    var warmupSetIndex: Int { activeExercise?.warmupSetsCompleted ?? 0 }
    var totalWarmupSets: Int { activeExercise?.totalWarmups ?? 0 }
    var targetSets: Int { activeExercise?.targetSets ?? 3 }
    var workingSetsCompleted: Int { activeExercise?.workingSetsCompleted ?? 0 }

    // Rest timer — derived from absolute end-time so backgrounding can't drift
    var isResting: Bool { snapshot?.restEndsAt != nil }
    var restTimerDuration: TimeInterval { snapshot?.restDuration ?? 150 }
    var restEndsAt: Date? { snapshot?.restEndsAt }
    /// Live remaining seconds. SwiftUI views should wrap reads in TimelineView for ticks.
    var restTimerRemaining: TimeInterval {
        guard let end = restEndsAt else { return 0 }
        return end.timeIntervalSince(Date())
    }

    /// Returns true if the current exercise is complete after rest
    var shouldReturnToListAfterRest: Bool {
        guard let idx = activeExerciseIndex else { return true }
        return idx < exerciseStates.count && exerciseStates[idx].isComplete
    }

    // MARK: - Initialize for mirroring

    /// Called when the iPhone joins an active mirrored session. Resets local state
    /// and asks the watch for the current snapshot. The next message that arrives
    /// will populate everything.
    func startMirroredWorkout(plan: WatchWorkoutPlan?) {
        snapshot = nil
        viewingExerciseIndex = nil
        currentWeight = 0
        currentReps = 0
        workoutMode = .mirroredFromWatch
        justFinishedAt = nil
        pendingSets = []
        droppedStalePendingCount = 0

        let weightSetting = UserDefaults.standard.double(forKey: "weightIncrement")
        if weightSetting > 0 { weightIncrement = weightSetting }

        // Ask the watch for its current state. The first snapshot will set up everything.
        sendCommand(.requestSnapshot)
        startPendingSweep()
        print("[BenLift/Phone] Joined mirrored workout — requested snapshot")
    }

    /// Start a phone-owned workout — used when the watch isn't paired/
    /// reachable and the user taps "Start here now" on Today. Phone becomes
    /// the source of truth: mutators write snapshot in-place instead of
    /// sending commands to the watch. No HK session means no HR data, but
    /// set logging / rest timer / finish-save all work.
    ///
    /// A `nil` plan is valid — starts a blank "Manual Workout" session the
    /// user can fill in via the add-exercise path. Symmetric with the
    /// watch's `startEmptyWorkout`.
    @MainActor
    func startStandaloneWorkout(plan: WatchWorkoutPlan?) {
        let effectivePlan = plan ?? WatchWorkoutPlan(
            sessionName: "Manual Workout",
            muscleGroups: [],
            category: nil,
            exercises: [],
            sessionStrategy: nil,
            aiPlanUsed: false
        )

        pendingSets = []
        droppedStalePendingCount = 0
        viewingExerciseIndex = nil
        workoutMode = .standalone
        justFinishedAt = nil
        lastActivitySignature = nil
        workoutAdjustments = []

        let weightSetting = UserDefaults.standard.double(forKey: "weightIncrement")
        if weightSetting > 0 { weightIncrement = weightSetting }

        // Build the initial snapshot from the plan. Phone owns state from
        // here on — no watch roundtrip, no commands, no reconciliation.
        let exercises: [SnapshotExercise] = effectivePlan.exercises.map { info in
            SnapshotExercise(
                name: info.name,
                targetSets: info.sets,
                targetReps: info.targetReps,
                suggestedWeight: info.suggestedWeight,
                warmupSets: info.warmupSets,
                intent: info.intent,
                notes: info.notes,
                lastWeight: info.lastWeight,
                lastReps: info.lastReps,
                loggedSets: [],
                isWarmupPhase: (info.warmupSets?.count ?? 0) > 0,
                isSkipped: false
            )
        }
        let restDuration = effectivePlan.restTimerDuration ?? 150

        let initialSnapshot = WorkoutSnapshot(
            version: 1,
            isActive: true,
            workoutStartDate: Date(),
            sessionName: effectivePlan.sessionName,
            muscleGroups: effectivePlan.muscleGroups,
            category: effectivePlan.category,
            sessionStrategy: effectivePlan.sessionStrategy,
            exercises: exercises,
            activeExerciseIndex: exercises.isEmpty ? nil : 0,
            restEndsAt: nil,
            restDuration: restDuration,
            currentHeartRate: 0,
            activeCalories: 0,
            aiPlanUsed: effectivePlan.aiPlanUsed
        )

        snapshot = initialSnapshot
        lastSnapshotReceivedAt = Date()
        lastInitializedSessionStart = initialSnapshot.workoutStartDate
        viewingExerciseIndex = initialSnapshot.activeExerciseIndex
        initializeInputWheelsForViewing()

        // Same side-effects the mirrored-snapshot path fires on session start.
        LiveActivityManager.shared.startActivity(
            sessionName: effectivePlan.sessionName ?? "Workout",
            totalExercises: exercises.count
        )
        NotificationService.shared.notifyWorkoutStarted(sessionName: effectivePlan.sessionName ?? "Workout")
        SnapshotCache.save(initialSnapshot)
        // Kick the watch a first snapshot immediately — if it's already
        // awake, the user's workout appears on the wrist within a beat.
        WatchSyncService.shared.sendPhoneOwnedSnapshot(initialSnapshot)

        print("[BenLift/Phone] Started STANDALONE workout: \(exercises.count) exercises, plan=\(effectivePlan.sessionName ?? "manual")")
    }

    /// Read weight + reps defaults off the exercise the phone is currently
    /// viewing. Used by both standalone-start and selectExercise so the
    /// input wheels always reflect the exercise on screen.
    private func initializeInputWheelsForViewing() {
        guard let idx = viewingExerciseIndex,
              let snap = snapshot,
              idx < snap.exercises.count else { return }
        let ex = snap.exercises[idx]
        if ex.isWarmupPhase,
           let warmups = ex.warmupSets,
           ex.warmupSetsCompleted < warmups.count {
            let next = warmups[ex.warmupSetsCompleted]
            currentWeight = next.displayWeight
            currentReps = Double(next.reps)
        } else {
            currentWeight = ex.lastWeight ?? ex.suggestedWeight
            currentReps = 0
        }
    }

    /// In-place snapshot mutator used by every standalone command path.
    /// Bumps version, writes to disk cache, fires UI side-effects that the
    /// mirrored path gets from `applySnapshot`, and broadcasts the snapshot
    /// to the watch so the read-only watch view stays in sync.
    private func commitStandaloneMutation(_ mutate: (inout WorkoutSnapshot) -> Void) {
        guard var snap = snapshot else { return }
        mutate(&snap)
        snap.version += 1
        snapshot = snap
        lastSnapshotReceivedAt = Date()
        if snap.isActive {
            SnapshotCache.save(snap)
            let totalSets = snap.exercises.reduce(0) { $0 + $1.loggedSets.count }
            let sig = "\(totalSets)|\(String(describing: snap.activeExerciseIndex))"
            if sig != lastActivitySignature {
                NotificationService.shared.scheduleAbandonReminder()
                lastActivitySignature = sig
            }
        } else {
            SnapshotCache.clear()
        }
        updateLiveActivity()
        // Broadcast to watch so a read-only view can render "what's happening."
        // Uses applicationContext — latest snapshot always wins, no flood.
        WatchSyncService.shared.sendPhoneOwnedSnapshot(snap)
    }

    /// Start (or restart) the per-set rest timer in a standalone session.
    /// Uses an absolute `restEndsAt` so the UI's TimelineView countdown
    /// stays accurate across backgrounding. One-shot Timer fires a success
    /// haptic when rest runs out — no looping to maintain.
    @MainActor
    private func beginStandaloneRest(duration: TimeInterval) {
        let endsAt = Date().addingTimeInterval(duration)
        commitStandaloneMutation { snap in
            snap.restEndsAt = endsAt
            snap.restDuration = duration
        }
        standaloneRestHapticTimer?.invalidate()
        standaloneRestHapticTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { _ in
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// Watch-side maps exercise intent to rest duration; phone does the same
    /// so a standalone session feels like a watch session.
    private func restDurationForIntent(_ intent: String?) -> TimeInterval {
        switch intent {
        case "primary compound": return 180
        case "secondary compound": return 120
        case "isolation": return 75
        case "finisher": return 60
        default: return snapshot?.restDuration ?? 150
        }
    }

    private var standaloneRestHapticTimer: Timer?

    /// Drops pending sets whose `sendToWatch` was reported undelivered, or
    /// that have outlived the stale threshold without a matching snapshot set.
    /// Runs on a repeating timer so the "watch is fully offline, no snapshot
    /// will come to reconcile" case still self-heals.
    func sweepStalePendingSets() {
        let now = Date()
        let before = pendingSets.count
        pendingSets.removeAll { $0.isStale(now: now) }
        let dropped = before - pendingSets.count
        if dropped > 0 {
            droppedStalePendingCount += dropped
            print("[BenLift/Phone] Sweep dropped \(dropped) stale pending set(s)")
        }
    }

    private func startPendingSweep() {
        pendingSweepTimer?.invalidate()
        pendingSweepTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sweepStalePendingSets()
        }
    }

    private func stopPendingSweep() {
        pendingSweepTimer?.invalidate()
        pendingSweepTimer = nil
    }

    // MARK: - Command sending (the phone's only way to mutate state)

    @discardableResult
    private func sendCommand(_ cmd: WorkoutCommand) -> Bool {
        WorkoutMirroringService.shared.sendToWatch(.command(cmd))
    }

    /// Force a fresh snapshot pull from the watch. Called after reachability
    /// flaps so stale UI state gets corrected. Cheap — owner just re-broadcasts
    /// what it already has.
    func requestFreshSnapshot() {
        sendCommand(.requestSnapshot)
    }

    // MARK: - Actions (each is just "send a command and wait for snapshot")

    func selectExercise(at index: Int) {
        viewingExerciseIndex = index
        // Initialize the input wheels from the exercise we're viewing.
        if index < exerciseStates.count {
            let state = exerciseStates[index]
            if state.isWarmupPhase, let warmups = state.warmupSets, state.warmupSetsCompleted < warmups.count {
                let next = warmups[state.warmupSetsCompleted]
                currentWeight = next.displayWeight
                currentReps = Double(next.reps)
            } else {
                currentWeight = state.lastWeight ?? state.suggestedWeight
                currentReps = 0
            }
        }
        if workoutMode == .standalone {
            // Standalone = phone is owner; update activeExerciseIndex locally.
            commitStandaloneMutation { snap in
                snap.activeExerciseIndex = index
            }
        } else {
            sendCommand(.selectExercise(index: index))
        }
    }

    func logSet() {
        guard let viewing = viewingExerciseIndex else { return }
        // Per Q2: only allow logging on the exercise the watch is currently active on.
        guard viewing == activeExerciseIndex else {
            print("[BenLift/Phone] Log blocked — viewing \(viewing) but watch active is \(String(describing: activeExerciseIndex))")
            return
        }
        let isWarmup = activeExercise?.isWarmupPhase ?? false

        if workoutMode == .standalone {
            standaloneLogSet(index: viewing, isWarmup: isWarmup)
            return
        }

        // Optimistic update: append set immediately so the UI feels instant.
        // The watch's eventual snapshot will include this set and we'll dedupe it out.
        let baseCount: Int = {
            guard let exs = snapshot?.exercises, viewing < exs.count else { return 0 }
            return exs[viewing].loggedSets.count
        }()
        let optimisticSet = WatchSetResult(
            setNumber: baseCount + 1 + pendingSets.filter { $0.exerciseIndex == viewing }.count,
            weight: currentWeight,
            reps: currentReps,
            timestamp: Date(),
            isWarmup: isWarmup
        )
        // Fire the command first so we can mark the pending with whether
        // delivery was even attempted (no mirrored session = undelivered).
        let delivered = sendCommand(.logSet(
            exerciseIndex: viewing,
            weight: currentWeight,
            reps: currentReps,
            isWarmup: isWarmup
        ))
        pendingSets.append(PendingSet(
            exerciseIndex: viewing,
            set: optimisticSet,
            sentAt: Date(),
            delivered: delivered
        ))
    }

    /// Phone-owned logSet — same outcome as the watch's version: append the
    /// set, advance warmup state, maybe start a rest timer, and re-prime
    /// the input wheels for the next set. `overrideWeight` / `overrideReps`
    /// let a remote command (watch→phone during phone-owned session) supply
    /// its own values instead of the phone's local wheel state.
    @MainActor
    private func standaloneLogSet(
        index: Int,
        isWarmup: Bool,
        overrideWeight: Double? = nil,
        overrideReps: Double? = nil
    ) {
        let weight = overrideWeight ?? currentWeight
        let reps = overrideReps ?? currentReps

        var intentForRest: String?
        commitStandaloneMutation { snap in
            guard index < snap.exercises.count else { return }
            var ex = snap.exercises[index]
            let setNumber = ex.loggedSets.count + 1
            ex.loggedSets.append(WatchSetResult(
                setNumber: setNumber,
                weight: weight,
                reps: reps,
                timestamp: Date(),
                isWarmup: isWarmup
            ))
            // Warmup-phase transition: if the user just finished their last
            // planned warmup, flip out of warmup so the next set goes into
            // the working-set counter.
            if isWarmup,
               let warmups = ex.warmupSets,
               ex.loggedSets.filter(\.isWarmup).count >= warmups.count {
                ex.isWarmupPhase = false
            }
            snap.exercises[index] = ex
            intentForRest = ex.intent
        }

        // Re-prime the input wheels so the user can log the next set
        // without manually dialing. Only done after working sets — for
        // warmup sets, watch loads the next warmup's suggested values.
        guard let snap = snapshot, index < snap.exercises.count else { return }
        let ex = snap.exercises[index]
        if ex.isWarmupPhase,
           let warmups = ex.warmupSets,
           ex.warmupSetsCompleted < warmups.count {
            let next = warmups[ex.warmupSetsCompleted]
            currentWeight = next.displayWeight
            currentReps = Double(next.reps)
        } else if !isWarmup {
            // Keep the same weight, clear reps for the next working set.
            currentReps = 0
        }

        // Rest timer only after working sets — warmups go straight to the
        // next warmup. Mirrors watch behavior in `WorkoutViewModel.logSet`.
        if !isWarmup {
            beginStandaloneRest(duration: restDurationForIntent(intentForRest))
        }
    }

    func undoLastSet() {
        guard let idx = viewingExerciseIndex ?? activeExerciseIndex else { return }
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                guard idx < snap.exercises.count,
                      !snap.exercises[idx].loggedSets.isEmpty else { return }
                let removed = snap.exercises[idx].loggedSets.removeLast()
                if removed.isWarmup {
                    snap.exercises[idx].isWarmupPhase = true
                }
                // Restore the inputs so the user can re-log the undone set.
                currentWeight = removed.weight
                currentReps = removed.reps
            }
            return
        }
        sendCommand(.undoSet(exerciseIndex: idx))
    }

    func skipWarmups() {
        // Watch doesn't have a skipWarmups command yet; emulate by selecting the
        // exercise (which on the watch side advances out of warmup if applicable).
        // For now this is a no-op on the phone — user can do it on the watch.
        print("[BenLift/Phone] skipWarmups not yet wired through commands")
    }

    func skipRest() {
        if workoutMode == .standalone {
            standaloneRestHapticTimer?.invalidate()
            standaloneRestHapticTimer = nil
            commitStandaloneMutation { snap in
                snap.restEndsAt = nil
            }
            return
        }
        sendCommand(.skipRest)
    }

    func adjustRestTimer(by seconds: Double) {
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                if let current = snap.restEndsAt {
                    snap.restEndsAt = current.addingTimeInterval(seconds)
                }
            }
            // Reschedule the haptic to the new end time so it fires on the
            // shifted schedule (not the original).
            if let newEnd = snapshot?.restEndsAt {
                standaloneRestHapticTimer?.invalidate()
                let interval = newEnd.timeIntervalSinceNow
                guard interval > 0 else { return }
                standaloneRestHapticTimer = Timer.scheduledTimer(
                    withTimeInterval: interval,
                    repeats: false
                ) { _ in
                    DispatchQueue.main.async {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
            return
        }
        sendCommand(.adjustRestTimer(deltaSeconds: Int(seconds)))
    }

    // MARK: - Local input state (purely local — never sent until commit)

    func adjustWeight(by amount: Double) {
        currentWeight = max(0, currentWeight + amount)
    }

    func adjustReps(by amount: Double) {
        currentReps = max(0, currentReps + amount)
    }

    func toggleFailedRep() {
        let hasFraction = currentReps.truncatingRemainder(dividingBy: 1) != 0
        if hasFraction {
            currentReps = floor(currentReps)
        } else if currentReps > 0 {
            currentReps += 0.5
        }
    }

    // MARK: - Add Exercise Mid-Workout

    func addExercise(_ info: WatchExerciseInfo) {
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                snap.exercises.append(SnapshotExercise(
                    name: info.name,
                    targetSets: info.sets,
                    targetReps: info.targetReps,
                    suggestedWeight: info.suggestedWeight,
                    warmupSets: info.warmupSets,
                    intent: info.intent,
                    notes: info.notes,
                    lastWeight: info.lastWeight,
                    lastReps: info.lastReps,
                    loggedSets: [],
                    isWarmupPhase: (info.warmupSets?.count ?? 0) > 0,
                    isSkipped: false
                ))
            }
            return
        }
        sendCommand(.addExercise(info: info))
    }

    // MARK: - Skip / Unskip / Swipe Swap
    //
    // These are the swipe-gesture actions from the list hub. Skip is purely a
    // state flag; swipe-swap reuses the existing mid-workout adaptation path,
    // but auto-fills a default reason so the user only has to tap accept.

    /// Optimistic skip: flip the flag locally so the UI ghosts the card
    /// immediately, then send the command. The snapshot will reconcile.
    func skipExercise(at index: Int) {
        guard index < exerciseStates.count else { return }
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                guard index < snap.exercises.count else { return }
                snap.exercises[index].isSkipped = true
            }
            return
        }
        optimisticallySkipped.insert(exerciseStates[index].name)
        sendCommand(.skipExercise(index: index))
    }

    func unskipExercise(at index: Int) {
        guard index < exerciseStates.count else { return }
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                guard index < snap.exercises.count else { return }
                snap.exercises[index].isSkipped = false
            }
            return
        }
        optimisticallySkipped.remove(exerciseStates[index].name)
        sendCommand(.unskipExercise(index: index))
    }

    /// Convenience wrapper around `requestAdaptation` for the swipe-left
    /// gesture. Uses `.other` as the reason so the LLM doesn't over-index on
    /// "pain" or "too hard" when the user is just asking for an alternative.
    /// Caller should present `adaptSuggestion` as an inline card on the swiped
    /// row and auto-accept on tap.
    @MainActor
    func swipeSwap(at index: Int, program: TrainingProgram?) async {
        await requestAdaptation(
            exerciseIndex: index,
            reason: .other,
            details: "User requested an alternative via swipe",
            program: program
        )
    }

    // MARK: - AI learning log (SessionEvent)

    /// Inspect the diff between the previous and next snapshot and write a
    /// `SessionEvent` row for each user-meaningful change. This is how mid-
    /// workout gestures (skip / unskip / swap / add) feed back into the AI —
    /// the next plan's prompt reads recent events to spot patterns.
    ///
    /// Owner-agnostic: works whether the mutation came from the phone (after
    /// a command round-trip) or the watch (processed locally, broadcast to us).
    /// The phone is the single place SwiftData is written, so funneling all
    /// events through here avoids cross-device persistence hassle.
    private func emitEvents(previous: WorkoutSnapshot?, next: WorkoutSnapshot) {
        guard let ctx = modelContext else { return }
        guard next.isActive else { return }  // don't emit during teardown
        // First snapshot of a session: every exercise would look "new" vs. a
        // nil baseline and fire an addExercise event. That's not a user
        // action — it's the initial plan load. Skip entirely.
        guard let previous else { return }
        // Mid-session reconnect: if the previous snapshot belonged to a
        // different workout (different start date), all the diffs would be
        // spurious. Skip across-session transitions too.
        guard previous.workoutStartDate == next.workoutStartDate else { return }

        // Uniquing by first occurrence — exercises can legitimately share a
        // name after a swap (e.g., swap puts "Barbell Row" at index 0 while
        // index 2 already had "Barbell Row"). `Dictionary(uniqueKeysWithValues:)`
        // traps on duplicates; we just keep whichever we saw first.
        let prevByName: [String: SnapshotExercise] = Dictionary(
            previous.exercises.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var events: [SessionEvent] = []

        // Detect skip / unskip / added exercises (by name diff).
        for (idx, ex) in next.exercises.enumerated() {
            guard let prev = prevByName[ex.name] else {
                // New exercise in this snapshot — addExercise path.
                events.append(SessionEvent(
                    kind: .addExercise,
                    exerciseName: ex.name,
                    exerciseIndex: idx,
                    sessionDate: next.workoutStartDate
                ))
                continue
            }
            if !prev.effectivelySkipped && ex.effectivelySkipped {
                events.append(SessionEvent(
                    kind: .skip,
                    exerciseName: ex.name,
                    exerciseIndex: idx,
                    sessionDate: next.workoutStartDate
                ))
            } else if prev.effectivelySkipped && !ex.effectivelySkipped {
                events.append(SessionEvent(
                    kind: .unskip,
                    exerciseName: ex.name,
                    exerciseIndex: idx,
                    sessionDate: next.workoutStartDate
                ))
            }
        }

        // Detect swap: same index, different name. Only fires when the new
        // exercise wasn't already in the prior snapshot under another slot,
        // so a reorder won't false-positive (Slice 4 will refine this).
        for (idx, ex) in next.exercises.enumerated() {
            guard idx < previous.exercises.count else { break }
            let prev = previous.exercises[idx]
            if prev.name != ex.name && prevByName[ex.name] == nil {
                events.append(SessionEvent(
                    kind: .swap,
                    exerciseName: prev.name,
                    replacementName: ex.name,
                    exerciseIndex: idx,
                    sessionDate: next.workoutStartDate
                ))
            }
        }

        guard !events.isEmpty else { return }
        events.forEach { ctx.insert($0) }
        do {
            try ctx.save()
            let kinds = events.map { $0.kind.rawValue }.joined(separator: ",")
            print("[BenLift/Phone] Logged \(events.count) SessionEvent(s): \(kinds)")
        } catch {
            print("[BenLift/Phone] ⚠️ Failed to persist SessionEvents: \(error)")
        }
    }

    // MARK: - Finish Workout

    /// Saves the workout to SwiftData using the data in the LATEST snapshot, then
    /// sends `.end` to the watch so it shuts down its session.
    func finishWorkout(modelContext: ModelContext, feeling: Int?, concerns: String?) {
        guard let snap = snapshot, snap.isActive else { return }

        let duration = elapsedTime
        // Persist if the user either logged sets OR explicitly skipped at least
        // one exercise — both count as "the workout actually happened".
        let meaningfulExercises = snap.exercises.filter {
            !$0.loggedSets.isEmpty || $0.effectivelySkipped
        }

        if !meaningfulExercises.isEmpty {
            let session = WorkoutSession(
                date: snap.workoutStartDate,
                category: snap.category,
                sessionName: snap.sessionName,
                muscleGroups: snap.muscleGroups.compactMap { MuscleGroup(rawValue: $0) },
                duration: duration,
                feeling: feeling,
                concerns: concerns,
                aiPlanUsed: snap.aiPlanUsed ?? true
            )

            for (order, ex) in snap.exercises.enumerated() {
                guard !ex.loggedSets.isEmpty || ex.effectivelySkipped else { continue }
                let entry = ExerciseEntry(
                    exerciseName: ex.name,
                    order: order,
                    isSkipped: ex.effectivelySkipped
                )
                for set in ex.loggedSets {
                    entry.sets.append(SetLog(
                        setNumber: set.setNumber,
                        weight: set.weight,
                        reps: set.reps,
                        timestamp: set.timestamp,
                        isWarmup: set.isWarmup
                    ))
                }
                session.entries.append(entry)
            }

            modelContext.insert(session)
            do {
                try modelContext.save()
                print("[BenLift/Phone] Saved workout: \(session.entries.count) exercises, \(session.displayName)")
                NotificationCenter.default.post(name: .workoutSessionSaved, object: session.id)
            } catch {
                print("[BenLift/Phone] Failed to save: \(error)")
            }
        } else {
            print("[BenLift/Phone] Empty workout (no sets), not saving")
        }

        // Mark the snapshot terminal so any UI observers (Live Activity,
        // banner, history deep link) see isActive=false before we tear down.
        // In mirror mode the watch sends a final isActive=false snapshot;
        // in standalone we have to emit it ourselves.
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                snap.isActive = false
                snap.restEndsAt = nil
            }
            standaloneRestHapticTimer?.invalidate()
            standaloneRestHapticTimer = nil
        }

        // End Live Activity
        LiveActivityManager.shared.endActivity(finalState: buildContentState())

        // Only tell the watch to shut down if we were actually mirroring
        // one — sending `.end` with no mirrored session would just fail
        // silently. sendWorkoutEnded (WCSession) is fine either way; it's
        // a no-op signal when nothing is listening.
        if workoutMode == .mirroredFromWatch {
            sendCommand(.end)
            WatchSyncService.shared.sendWorkoutEnded()
        }
        stopPendingSweep()

        // Local notification summary + clear abandon reminder
        NotificationService.shared.cancelAbandonReminder()
        NotificationService.shared.notifyWorkoutCompleted(
            sessionName: snap.sessionName ?? "Workout",
            volume: Int(totalVolume),
            durationSeconds: duration
        )
        lastActivitySignature = nil

        justFinishedAt = Date()
    }

    // MARK: - Receive snapshots from the watch

    func handleMirroredMessage(_ message: WorkoutMessage) {
        switch message {
        case .snapshot(let s):
            applySnapshot(s)
        case .command:
            // Phone is mirror — never receives commands. Ignore.
            break
        }
    }

    private func applySnapshot(_ s: WorkoutSnapshot) {
        // Drop stale (out-of-order) snapshots — but only if they're from the
        // SAME workout session. Comparing versions across sessions silently
        // dropped every new snapshot when the prior session's final version
        // was cached locally (e.g. v41 cached → new session sends v1 → dropped).
        if let current = snapshot,
           current.workoutStartDate == s.workoutStartDate,
           s.version <= current.version {
            return
        }
        let previous = snapshot
        let wasActive = snapshot?.isActive ?? false
        snapshot = s
        lastSnapshotReceivedAt = Date()

        // Reconcile optimistic pending sets — drop ones that are now in the snapshot.
        // Match by weight + reps + timestamp-within-5s tolerance (the watch will have
        // its own timestamp from when it processed the command).
        let now = Date()
        var droppedStale = 0
        pendingSets.removeAll { pending in
            guard pending.exerciseIndex < s.exercises.count else { return true }
            let snapSets = s.exercises[pending.exerciseIndex].loggedSets
            let matched = snapSets.contains { snapSet in
                snapSet.weight == pending.set.weight &&
                snapSet.reps == pending.set.reps &&
                abs(snapSet.timestamp.timeIntervalSince(pending.set.timestamp)) < 5.0
            }
            if matched { return true }
            // Not yet matched. If the pending has aged past the stale
            // threshold OR the send attempt failed outright, drop it so the
            // UI stops showing a set that will never be confirmed by the
            // watch. The UI observes `droppedStalePendingCount` to show a
            // "couldn't sync" toast + offer re-log.
            if pending.isStale(now: now) {
                droppedStale += 1
                return true
            }
            return false
        }
        if droppedStale > 0 {
            droppedStalePendingCount += droppedStale
            print("[BenLift/Phone] Dropped \(droppedStale) stale pending set(s) with no snapshot match")
        }

        // Clear optimistic skip flags that the snapshot has now reflected.
        // Keep flags whose exercise is still showing unskipped in the snapshot —
        // those are still in-flight commands.
        optimisticallySkipped = optimisticallySkipped.filter { name in
            guard let ex = s.exercises.first(where: { $0.name == name }) else { return false }
            return !ex.effectivelySkipped
        }

        // Derive SessionEvents from the snapshot diff (see emitEvents below).
        // Watch-owner case: the watch processed a command and broadcast; we're
        // only now seeing the result, so this is where the AI learning log
        // gets its signal.
        emitEvents(previous: previous, next: s)

        // Cache to disk for force-quit recovery — ONLY while the workout is
        // active. Persisting a final isActive=false snapshot and then being
        // backgrounded before the post-finish cleanup can cause a ghost
        // resume on next launch (cache hygiene should catch it, but belt-
        // and-braces: don't save the terminal state at all).
        if s.isActive {
            SnapshotCache.save(s)
        } else {
            SnapshotCache.clear()
        }

        // First snapshot or watch switched exercise: align viewing index
        if viewingExerciseIndex == nil {
            viewingExerciseIndex = s.activeExerciseIndex
            // Initialize input wheels for the viewed exercise
            if let idx = viewingExerciseIndex, idx < s.exercises.count {
                let ex = s.exercises[idx]
                if ex.isWarmupPhase, let warmups = ex.warmupSets, ex.warmupSetsCompleted < warmups.count {
                    let next = warmups[ex.warmupSetsCompleted]
                    currentWeight = next.displayWeight
                    currentReps = Double(next.reps)
                } else {
                    currentWeight = ex.lastWeight ?? ex.suggestedWeight
                    currentReps = 0
                }
            }
        }

        // Workout just became active — start Live Activity and run per-session
        // initialization (notification, reset adjustments). Gated on
        // `workoutStartDate` so flaky active→inactive→active cycles from the
        // same session don't re-fire everything.
        if !wasActive && s.isActive && lastInitializedSessionStart != s.workoutStartDate {
            LiveActivityManager.shared.startActivity(
                sessionName: s.sessionName ?? "Workout",
                totalExercises: s.exercises.count
            )
            NotificationService.shared.notifyWorkoutStarted(sessionName: s.sessionName ?? "Workout")
            lastActivitySignature = nil
            workoutAdjustments = []
            lastInitializedSessionStart = s.workoutStartDate
        }

        // While active, reset the abandon reminder only on real user actions.
        if s.isActive {
            let totalSets = s.exercises.reduce(0) { $0 + $1.loggedSets.count }
            let sig = "\(totalSets)|\(s.activeExerciseIndex)"
            if sig != lastActivitySignature {
                NotificationService.shared.scheduleAbandonReminder()
                lastActivitySignature = sig
            }
        }

        // Workout ended on watch
        if wasActive && !s.isActive {
            justFinishedAt = Date()
            SnapshotCache.clear()
            LiveActivityManager.shared.endAnyActivity()
            NotificationService.shared.cancelAbandonReminder()
            lastActivitySignature = nil
            workoutAdjustments = []
            stopPendingSweep()
        }

        updateLiveActivity()
    }

    // MARK: - Live Activity

    func buildContentState() -> WorkoutActivityAttributes.ContentState {
        let activeEx = activeExercise
        let exercisesCompleted = exerciseStates.filter(\.isComplete).count

        return WorkoutActivityAttributes.ContentState(
            currentExerciseName: activeEx?.name ?? exerciseStates.first(where: { !$0.isComplete })?.name ?? "Workout",
            currentExerciseIndex: activeExerciseIndex ?? 0,
            setsCompleted: activeEx?.workingSetsCompleted ?? 0,
            totalSets: activeEx?.targetSets ?? 0,
            restEndDate: restEndsAt,
            isResting: isResting,
            heartRate: Int(currentHeartRate),
            elapsedSeconds: Int(elapsedTime),
            totalVolume: Int(totalVolume),
            exercisesCompleted: exercisesCompleted
        )
    }

    func updateLiveActivity() {
        LiveActivityManager.shared.update(state: buildContentState())
    }

    // MARK: - Mid-Workout AI Adaptation

    func requestAdaptation(
        exerciseIndex: Int?,
        reason: AdaptReason,
        details: String?,
        program: TrainingProgram?
    ) async {
        isAdapting = true
        adaptError = nil
        adaptSuggestion = nil
        adaptTargetIndex = exerciseIndex

        let originalPlan = exerciseStates.map { state in
            "\(state.name): \(state.targetSets)x\(state.targetReps) @ \(Int(state.suggestedWeight)) lbs (\(state.intent ?? "unknown"))"
        }.joined(separator: "\n")

        let completedSoFar = exerciseStates.compactMap { state -> String? in
            guard !state.loggedSets.isEmpty else { return nil }
            let sets = state.loggedSets.map { "\(Int($0.weight))x\($0.reps.formattedReps)" }.joined(separator: ", ")
            return "\(state.name): \(sets)"
        }.joined(separator: "\n")

        let remaining: String
        if let targetIdx = exerciseIndex, targetIdx < exerciseStates.count {
            let state = exerciseStates[targetIdx]
            remaining = "\(state.name): \(state.targetSets)x\(state.targetReps) @ \(Int(state.suggestedWeight)) lbs"
        } else {
            remaining = exerciseStates.compactMap { state -> String? in
                guard !state.isComplete else { return nil }
                return "\(state.name): \(state.targetSets - state.workingSetsCompleted) sets remaining"
            }.joined(separator: "\n")
        }

        let reasonText: String
        if let targetIdx = exerciseIndex, targetIdx < exerciseStates.count {
            reasonText = "\(reason.promptText) — specifically for \(exerciseStates[targetIdx].name)"
        } else {
            reasonText = reason.promptText
        }

        let (system, user) = PromptBuilder.midWorkoutAdaptPrompt(
            originalPlan: originalPlan,
            completedSoFar: completedSoFar.isEmpty ? "None yet" : completedSoFar,
            remaining: remaining,
            reason: reasonText,
            details: details,
            priorAdjustments: workoutAdjustments
        )

        let model = UserDefaults.standard.string(forKey: "modelMidWorkout") ?? "claude-haiku-4-5-20251001"
        let service = ClaudeCoachService()

        do {
            let response = try await service.adaptMidWorkout(
                systemPrompt: system,
                userPrompt: user,
                model: model
            )
            adaptSuggestion = response
        } catch {
            adaptError = error.localizedDescription
        }

        isAdapting = false
    }

    func acceptAdaptation() {
        guard let suggestion = adaptSuggestion else { return }

        if let targetIdx = adaptTargetIndex, let replacement = suggestion.exercises.first {
            let originalName = (targetIdx < exerciseStates.count) ? exerciseStates[targetIdx].name : "exercise"
            replaceExerciseCommand(at: targetIdx, with: watchInfo(for: replacement))
            workoutAdjustments.append(AdjustmentRecord(
                kind: .swap,
                summary: "Swapped \(originalName) -> \(replacement.name)"
            ))
        } else {
            // Untargeted "AI Suggest Changes" — reshape what remains.
            //
            // Prior behavior appended every suggestion on top of the existing
            // plan, which stacked the list into a long redundant mess (the
            // user still had the old exercises AND the new ones). The user's
            // intent on this button is "change what I'm doing going forward,"
            // not "pile more on."
            //
            // Rule: preserve anything the user has already invested in
            // (logged sets) or explicitly set aside (skipped). Remap
            // suggestions onto the remaining unlogged + non-skipped slots
            // via `adaptExercise`. If there are more suggestions than open
            // slots, append the excess. If there are more open slots than
            // suggestions, skip the extras so the plan actually shrinks.
            let remainingIndices: [Int] = exerciseStates.enumerated().compactMap { idx, ex in
                (ex.loggedSets.isEmpty && !ex.effectivelySkipped) ? idx : nil
            }

            let suggestedInfos = suggestion.exercises.map(watchInfo(for:))

            // Phase 1: replace as many remaining slots as we have suggestions.
            for (i, info) in suggestedInfos.enumerated() where i < remainingIndices.count {
                let slot = remainingIndices[i]
                let originalName = (slot < exerciseStates.count) ? exerciseStates[slot].name : "exercise"
                replaceExerciseCommand(at: slot, with: info)
                workoutAdjustments.append(AdjustmentRecord(
                    kind: .swap,
                    summary: "Swapped \(originalName) -> \(info.name)"
                ))
            }

            // Phase 2: any leftover open slots get skipped — the user asked
            // for a shorter/different shape, honor it. Higher indices first
            // so index shifts don't affect the earlier ones on the owner side
            // (watch processes commands serially; skip is a flag, not a
            // delete, so order technically doesn't matter here — but staying
            // consistent with how a future .deleteExercise command would
            // behave is cheap insurance).
            if suggestedInfos.count < remainingIndices.count {
                for slot in remainingIndices[suggestedInfos.count...].reversed() {
                    skipExercise(at: slot)
                }
            }

            // Phase 3: any suggestions beyond the open-slot count get
            // appended. Rare (the model usually matches or trims).
            if suggestedInfos.count > remainingIndices.count {
                for info in suggestedInfos[remainingIndices.count...] {
                    addExercise(info)
                    workoutAdjustments.append(AdjustmentRecord(
                        kind: .addExercise,
                        summary: "Added \(info.name) mid-workout"
                    ))
                }
            }
        }

        adaptSuggestion = nil
        adaptTargetIndex = nil
    }

    // MARK: - Remote Commands (watch → phone, during phone-owned session)

    /// Dispatcher for commands the watch sends while the phone owns the
    /// session. Each case maps to the existing standalone-mode mutator,
    /// so the business logic lives in one place regardless of origin.
    /// Commands arrive via `WatchSyncService.receivedPhoneCommand` →
    /// `PhoneMirroringController` → here. The resulting snapshot
    /// broadcasts back to the watch via `commitStandaloneMutation`.
    @MainActor
    func handleRemoteCommand(_ cmd: WorkoutCommand) {
        guard workoutMode == .standalone else {
            print("[BenLift/Phone] Ignored remote command — session isn't phone-owned: \(cmd)")
            return
        }
        switch cmd {
        case .logSet(let idx, let weight, let reps, let isWarmup):
            // The watch already committed weight/reps to its local wheels;
            // its command carries those exact values. We route through the
            // same standalone logger the phone UI uses — but with the
            // watch-sent values, not our local `currentWeight`/`currentReps`.
            standaloneLogSet(
                index: idx,
                isWarmup: isWarmup,
                overrideWeight: weight,
                overrideReps: reps
            )
        case .undoSet(let idx):
            commitStandaloneMutation { snap in
                guard idx < snap.exercises.count,
                      !snap.exercises[idx].loggedSets.isEmpty else { return }
                let removed = snap.exercises[idx].loggedSets.removeLast()
                if removed.isWarmup {
                    snap.exercises[idx].isWarmupPhase = true
                }
            }
        case .selectExercise(let idx):
            commitStandaloneMutation { snap in
                snap.activeExerciseIndex = idx
            }
        case .skipRest:
            skipRest()  // already mode-branches correctly
        case .adjustRestTimer(let delta):
            adjustRestTimer(by: Double(delta))
        case .skipExercise(let idx):
            skipExercise(at: idx)
        case .unskipExercise(let idx):
            unskipExercise(at: idx)
        case .addExercise(let info):
            addExercise(info)
        case .adaptExercise(let idx, let replacement):
            replaceExerciseCommand(at: idx, with: replacement)
        case .end:
            // The watch asked to end. We need a modelContext to save —
            // the VM is injected with one at app launch; fall back to
            // just clearing state if for some reason it isn't.
            if let ctx = modelContext {
                finishWorkout(modelContext: ctx, feeling: nil, concerns: nil)
            } else {
                print("[BenLift/Phone] ⚠️ Remote .end with no modelContext; state won't persist")
            }
        case .requestSnapshot:
            // Rebroadcast current state — watch just wants to be sure it
            // has the latest. Bumping version forces the broadcast.
            commitStandaloneMutation { _ in }
        }
    }

    /// In-place or command-based exercise replacement, depending on mode.
    /// Both `acceptAdaptation` (targeted and untargeted) funnel through
    /// here so the standalone / mirror fork only lives in one place.
    /// Matches the watch's `.adaptExercise` semantics: the replaced slot
    /// becomes a fresh `SnapshotExercise` with no logged sets. (Callers
    /// are expected to only hit unlogged slots anyway.)
    private func replaceExerciseCommand(at index: Int, with info: WatchExerciseInfo) {
        if workoutMode == .standalone {
            commitStandaloneMutation { snap in
                guard index < snap.exercises.count else { return }
                snap.exercises[index] = SnapshotExercise(
                    name: info.name,
                    targetSets: info.sets,
                    targetReps: info.targetReps,
                    suggestedWeight: info.suggestedWeight,
                    warmupSets: info.warmupSets,
                    intent: info.intent,
                    notes: info.notes,
                    lastWeight: info.lastWeight,
                    lastReps: info.lastReps,
                    loggedSets: [],
                    isWarmupPhase: (info.warmupSets?.count ?? 0) > 0,
                    isSkipped: false
                )
            }
            return
        }
        sendCommand(.adaptExercise(index: index, replacement: info))
    }

    /// Turn a PlannedExercise from the LLM into a WatchExerciseInfo command
    /// payload. Extracted so both the targeted-swap and untargeted-reshape
    /// branches of `acceptAdaptation` build payloads the same way.
    private func watchInfo(for exercise: PlannedExercise) -> WatchExerciseInfo {
        WatchExerciseInfo(
            name: exercise.name,
            sets: exercise.sets,
            targetReps: exercise.targetReps,
            suggestedWeight: exercise.weight,
            warmupSets: exercise.warmupSets,
            notes: exercise.notes,
            intent: exercise.intent,
            lastWeight: nil,
            lastReps: nil,
            equipment: DefaultExercises.all.first(where: { $0.name == exercise.name })?.equipment
        )
    }

    func dismissAdaptation() {
        adaptSuggestion = nil
        adaptError = nil
        adaptTargetIndex = nil
    }
}

// MARK: - SnapshotExercise compat shim

extension SnapshotExercise {
    /// Lets existing view code keep saying `state.info.name`, `state.info.warmupSets`, etc.
    /// This synthesizes a `WatchExerciseInfo` from the flat snapshot fields.
    var info: WatchExerciseInfo {
        WatchExerciseInfo(
            name: name,
            sets: targetSets,
            targetReps: targetReps,
            suggestedWeight: suggestedWeight,
            warmupSets: warmupSets,
            notes: notes,
            intent: intent,
            lastWeight: lastWeight,
            lastReps: lastReps,
            equipment: DefaultExercises.all.first(where: { $0.name == name })?.equipment
        )
    }
}

// MARK: - Snapshot Cache (force-quit recovery)

enum SnapshotCache {
    private static let key = "BenLift.activeWorkoutSnapshot"
    /// Discard cached snapshots whose workout started more than this long ago.
    /// Prevents ghost-resume prompts from forgotten sessions (sub-agent edge case #7).
    private static let staleThreshold: TimeInterval = 6 * 60 * 60  // 6 hours

    static func save(_ snapshot: WorkoutSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> WorkoutSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(WorkoutSnapshot.self, from: data) else {
            // Decode failure (e.g. schema change) — wipe so we don't keep retrying
            clear()
            return nil
        }
        // Hygiene: drop snapshots that are too old or already terminated
        if !snapshot.isActive || Date().timeIntervalSince(snapshot.workoutStartDate) > staleThreshold {
            clear()
            return nil
        }
        return snapshot
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Adapt Reason

enum AdaptReason: String, CaseIterable, Identifiable {
    case equipmentTaken
    case painDiscomfort
    case tooHard
    case tooEasy
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equipmentTaken: return "Equipment Taken"
        case .painDiscomfort: return "Pain / Discomfort"
        case .tooHard: return "Too Hard"
        case .tooEasy: return "Too Easy"
        case .other: return "Other"
        }
    }

    var promptText: String {
        switch self {
        case .equipmentTaken: return "Equipment is taken or broken — suggest an alternative exercise targeting the same muscle group with available equipment"
        case .painDiscomfort: return "Experiencing pain or discomfort — suggest a safer alternative that avoids the problematic movement pattern"
        case .tooHard: return "Exercise is too difficult today — suggest an easier variation or lower intensity alternative"
        case .tooEasy: return "Exercise is too easy — suggest a more challenging variation or progression"
        case .other: return "User wants to change exercise"
        }
    }

    var icon: String {
        switch self {
        case .equipmentTaken: return "xmark.circle"
        case .painDiscomfort: return "bandage"
        case .tooHard: return "arrow.down.circle"
        case .tooEasy: return "arrow.up.circle"
        case .other: return "ellipsis.circle"
        }
    }
}
