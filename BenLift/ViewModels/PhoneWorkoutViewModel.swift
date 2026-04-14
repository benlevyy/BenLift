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

    struct PendingSet: Identifiable {
        let id: UUID = UUID()
        let exerciseIndex: Int
        let set: WatchSetResult
        let sentAt: Date
    }

    /// When we last got a snapshot from the watch. Used to show a "Reconnecting…"
    /// banner when the watch goes quiet for >5 seconds during an active workout.
    var lastSnapshotReceivedAt: Date?

    // Activity signature used to debounce the abandon-reminder reschedule so it only
    // resets on real user actions (sets logged, exercise changed), not HR updates.
    private var lastActivitySignature: String?
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
        if pendingSets.isEmpty { return base }
        return base.enumerated().map { idx, ex in
            let appended = pendingSets.filter { $0.exerciseIndex == idx }.map(\.set)
            if appended.isEmpty { return ex }
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
                isWarmupPhase: ex.isWarmupPhase
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

    /// Cable exercises use 2.5 lb pin increments; everything else uses the user's
    /// configured increment (default 5 lb plates).
    var effectiveWeightIncrement: Double {
        if let name = activeExerciseInfo?.name, name.localizedCaseInsensitiveContains("cable") {
            return 2.5
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

        let weightSetting = UserDefaults.standard.double(forKey: "weightIncrement")
        if weightSetting > 0 { weightIncrement = weightSetting }

        // Ask the watch for its current state. The first snapshot will set up everything.
        sendCommand(.requestSnapshot)
        print("[BenLift/Phone] Joined mirrored workout — requested snapshot")
    }

    // MARK: - Command sending (the phone's only way to mutate state)

    private func sendCommand(_ cmd: WorkoutCommand) {
        WorkoutMirroringService.shared.sendToWatch(.command(cmd))
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
        sendCommand(.selectExercise(index: index))
    }

    func logSet() {
        guard let viewing = viewingExerciseIndex else { return }
        // Per Q2: only allow logging on the exercise the watch is currently active on.
        guard viewing == activeExerciseIndex else {
            print("[BenLift/Phone] Log blocked — viewing \(viewing) but watch active is \(String(describing: activeExerciseIndex))")
            return
        }
        let isWarmup = activeExercise?.isWarmupPhase ?? false

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
        pendingSets.append(PendingSet(
            exerciseIndex: viewing,
            set: optimisticSet,
            sentAt: Date()
        ))

        sendCommand(.logSet(
            exerciseIndex: viewing,
            weight: currentWeight,
            reps: currentReps,
            isWarmup: isWarmup
        ))
    }

    func undoLastSet() {
        guard let idx = viewingExerciseIndex ?? activeExerciseIndex else { return }
        sendCommand(.undoSet(exerciseIndex: idx))
    }

    func skipWarmups() {
        // Watch doesn't have a skipWarmups command yet; emulate by selecting the
        // exercise (which on the watch side advances out of warmup if applicable).
        // For now this is a no-op on the phone — user can do it on the watch.
        print("[BenLift/Phone] skipWarmups not yet wired through commands")
    }

    func skipRest() {
        sendCommand(.skipRest)
    }

    func adjustRestTimer(by seconds: Double) {
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
        sendCommand(.addExercise(info: info))
    }

    // MARK: - Finish Workout

    /// Saves the workout to SwiftData using the data in the LATEST snapshot, then
    /// sends `.end` to the watch so it shuts down its session.
    func finishWorkout(modelContext: ModelContext, feeling: Int?, concerns: String?) {
        guard let snap = snapshot, snap.isActive else { return }

        let duration = elapsedTime
        let nonEmptyExercises = snap.exercises.filter { !$0.loggedSets.isEmpty }

        // Only persist if at least one exercise has logged sets
        if !nonEmptyExercises.isEmpty {
            let session = WorkoutSession(
                date: snap.workoutStartDate,
                category: snap.category,
                sessionName: snap.sessionName,
                muscleGroups: snap.muscleGroups.compactMap { MuscleGroup(rawValue: $0) },
                duration: duration,
                feeling: feeling,
                concerns: concerns,
                aiPlanUsed: true
            )

            for (order, ex) in snap.exercises.enumerated() {
                guard !ex.loggedSets.isEmpty else { continue }
                let entry = ExerciseEntry(exerciseName: ex.name, order: order)
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

        // End Live Activity
        LiveActivityManager.shared.endActivity(finalState: buildContentState())

        // Tell watch to shut down
        sendCommand(.end)
        WatchSyncService.shared.sendWorkoutEnded()

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
        // Drop stale (out-of-order) snapshots
        if let current = snapshot, s.version <= current.version {
            return
        }
        let wasActive = snapshot?.isActive ?? false
        snapshot = s
        lastSnapshotReceivedAt = Date()

        // Reconcile optimistic pending sets — drop ones that are now in the snapshot.
        // Match by weight + reps + timestamp-within-2s tolerance (the watch will have
        // its own timestamp from when it processed the command).
        pendingSets.removeAll { pending in
            guard pending.exerciseIndex < s.exercises.count else { return true }
            let snapSets = s.exercises[pending.exerciseIndex].loggedSets
            return snapSets.contains { snapSet in
                snapSet.weight == pending.set.weight &&
                snapSet.reps == pending.set.reps &&
                abs(snapSet.timestamp.timeIntervalSince(pending.set.timestamp)) < 5.0
            }
        }

        // Cache to disk for force-quit recovery
        SnapshotCache.save(s)

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

        // Workout just became active — start Live Activity
        // (first snapshot of an active workout, or transition from inactive→active)
        if !wasActive && s.isActive {
            LiveActivityManager.shared.startActivity(
                sessionName: s.sessionName ?? "Workout",
                totalExercises: s.exercises.count
            )
            NotificationService.shared.notifyWorkoutStarted(sessionName: s.sessionName ?? "Workout")
            lastActivitySignature = nil
            workoutAdjustments = []
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
            // Replace specific exercise via command
            let info = WatchExerciseInfo(
                name: replacement.name,
                sets: replacement.sets,
                targetReps: replacement.targetReps,
                suggestedWeight: replacement.weight,
                warmupSets: replacement.warmupSets,
                notes: replacement.notes,
                intent: replacement.intent,
                lastWeight: nil,
                lastReps: nil
            )
            sendCommand(.adaptExercise(index: targetIdx, replacement: info))
            workoutAdjustments.append(AdjustmentRecord(
                kind: .swap,
                summary: "Swapped \(originalName) -> \(replacement.name)"
            ))
        } else {
            // Append all suggested exercises
            for exercise in suggestion.exercises {
                let info = WatchExerciseInfo(
                    name: exercise.name,
                    sets: exercise.sets,
                    targetReps: exercise.targetReps,
                    suggestedWeight: exercise.weight,
                    warmupSets: exercise.warmupSets,
                    notes: exercise.notes,
                    intent: exercise.intent,
                    lastWeight: nil,
                    lastReps: nil
                )
                sendCommand(.addExercise(info: info))
                workoutAdjustments.append(AdjustmentRecord(
                    kind: .addExercise,
                    summary: "Added \(exercise.name) mid-workout"
                ))
            }
        }

        adaptSuggestion = nil
        adaptTargetIndex = nil
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
            lastReps: lastReps
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
