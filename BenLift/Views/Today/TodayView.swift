import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
    /// App-scoped mirroring controller. Exposes `phoneWorkoutVM` for binding
    /// + `showPhoneWorkout` for sheet presentation + the `startStandaloneSession`
    /// entry point for the phone-owned-workout fallback.
    @Bindable var phoneMirroring: PhoneMirroringController

    private var phoneWorkoutVM: PhoneWorkoutViewModel { phoneMirroring.phoneWorkoutVM }

    @State private var analysisVM = AnalysisViewModel()
    @State private var savedSession: WorkoutSession?

    // Check-in state — pulled from HealthKit on appear so the recovery strip
    // can render inline without requiring the user to open a separate sheet.
    @State private var healthContext: HealthContext?
    /// Local mirror of `coachVM.concerns` so the text field is responsive
    /// without fighting the view model on every keystroke. Committed on
    /// submit → flips `coachVM.concerns` → drives `isPlanStale`.
    @State private var concernsDraft: String = ""
    /// Drives the keyboard-dismiss toolbar. The concerns field uses a
    /// vertical-axis TextField (multi-line), where Return inserts a newline
    /// instead of submitting — so without this there's literally no way to
    /// close the keyboard on iOS.
    @FocusState private var concernsFocused: Bool


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Workout in progress banner (tap to resume)
                    if phoneWorkoutVM.isWorkoutActive {
                        phoneWorkoutBanner
                    }

                    // Inline check-in — feeling + time + recovery + concerns.
                    // Changes stage locally; the plan regenerates only when
                    // the user taps the Refresh pill (or pull-to-refresh).
                    checkInRow

                    // Refresh pill — shown when the plan's inputs have drifted
                    // from what produced the currently-displayed plan.
                    if coachVM.isPlanStale && !coachVM.isGenerating && !coachVM.isLoadingRecommendation {
                        refreshPill
                    }

                    // Skeleton only on true cold start (no plan yet AND no
                    // recommendation). On refresh, the existing plan stays
                    // visible (dimmed) until the new recommendation event
                    // lands and atomically replaces it — no flash to empty,
                    // refresh feels like an in-place update.
                    let isLoading = coachVM.isLoadingRecommendation || coachVM.isGenerating
                    let showSkeleton = coachVM.recommendation == nil
                        && coachVM.editedExercises.isEmpty
                        && isLoading

                    if showSkeleton {
                        ThinkingView(
                            phase: coachVM.isLoadingRecommendation ? .analyzing : .building
                        )
                        .transition(.opacity)
                    } else {
                        if let rec = coachVM.recommendation {
                            recommendationHeader(rec)
                                .transition(.opacity)
                        }
                        if !coachVM.editedExercises.isEmpty {
                            planSection
                                .transition(.opacity)
                        }
                    }

                    // Error
                    if let error = coachVM.planError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.failedRed)
                            .padding(8)
                            .background(Color.failedRed.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            // Dragging the scroll view up / down while the keyboard is up
            // dismisses it — same gesture users learn from Mail / Messages.
            // Paired with the keyboard-toolbar Done button so there are two
            // ways out.
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                // Pull-to-refresh: always regenerate
                withAnimation(.easeOut(duration: 0.2)) {
                    coachVM.editedExercises = []
                    coachVM.currentPlan = nil
                    coachVM.recommendation = nil
                }
                // Run in an unstructured Task so the request isn't cancelled if
                // the refresh gesture is interrupted or the view scrolls away.
                await Task {
                    await coachVM.getRecommendationAndPlan(
                        modelContext: modelContext,
                        program: programVM.currentProgram
                    )
                }.value
            }
            .navigationTitle("Today")
            .onAppear {
                programVM.loadCurrentProgram(modelContext: modelContext)
                concernsDraft = coachVM.concerns
                Task { healthContext = await HealthKitService.shared.fetchHealthContext() }
            }
            // Keep the local draft in sync when the VM resets concerns
            // after a successful plan generation. Without this, the
            // field stays full of the now-consumed intent and the UX
            // implies it's still pending.
            .onChange(of: coachVM.concerns) { _, newValue in
                if newValue != concernsDraft {
                    concernsDraft = newValue
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .workoutSessionSaved)) { notification in
                if let sessionId = notification.object as? UUID {
                    let descriptor = FetchDescriptor<WorkoutSession>(
                        predicate: #Predicate { $0.id == sessionId }
                    )
                    if let session = try? modelContext.fetch(descriptor).first {
                        savedSession = session
                        Task {
                            await analysisVM.analyzeWorkout(
                                session: session,
                                planSummary: coachVM.currentPlan?.sessionStrategy,
                                modelContext: modelContext,
                                program: programVM.currentProgram,
                                healthContext: nil
                            )
                        }
                    }
                }
            }
            .sheet(item: $savedSession) { session in
                PostWorkoutSheet(
                    session: session,
                    analysisVM: analysisVM,
                    programVM: programVM
                )
            }
        }
    }

    // MARK: - Recommendation Header

    /// Both LLM paragraphs (reasoning + strategy note) live behind one
    /// "Why" disclosure so the default state is just the session title —
    /// no wall of grey text on the home screen.
    @State private var showRationale = false

    private func recommendationHeader(_ rec: RecoveryRecommendation) -> some View {
        let strategy = coachVM.currentPlan?.sessionStrategy
        let hasDetail = !rec.reasoning.isEmpty || (strategy?.isEmpty == false)

        return VStack(alignment: .leading, spacing: showRationale ? 10 : 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rec.recommendedSessionName)
                    .font(.title3.bold())
                Spacer()
                if hasDetail {
                    Button {
                        Haptics.selection()
                        withAnimation(.smooth(duration: 0.3)) { showRationale.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showRationale ? 180 : 0))
                            .foregroundColor(.secondaryText)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if showRationale {
                VStack(alignment: .leading, spacing: 6) {
                    if !rec.reasoning.isEmpty {
                        Text(rec.reasoning)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                    if let strategy, !strategy.isEmpty {
                        Text(strategy)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Plan Section

    /// Vestigial — kept only because the `exerciseRow` signature still
    /// references it for the trailing delete affordance during transition.
    /// Long-press context menu is now the canonical edit path; this is
    /// always false. Will be removed once the inline Edit toggle is
    /// fully gone from the row body.
    @State private var isEditingPlan = false

    /// Reminders-style explicit reorder mode. Entered by tapping "Move"
    /// in a row's context menu; exited via the "Done" button that
    /// surfaces above the plan list while it's active. Drag handles +
    /// the drag gesture are gated on this so a casual touch can't
    /// reshuffle the plan accidentally.
    @State private var isMoveMode = false

    // MARK: - Custom Drag State (Home Screen-style reorder)
    //
    // We don't use `.draggable` / `.dropDestination` for reorder because
    // their thumbnail preview detaches from the layout (a small chip
    // floats; the row's slot disappears). For Apple-Home-Screen feel,
    // the row itself follows the finger at full size while neighbors
    // slide aside to open a slot. We track:
    //  - `dragSourceIndex`: which row the user grabbed
    //  - `dragTranslationY`: cumulative finger displacement
    //  - `dragTargetIndex`: which slot the row currently occupies
    // Other rows compute their offset from these to slide aside.

    @State private var dragSourceIndex: Int? = nil
    @State private var dragTranslationY: CGFloat = 0
    @State private var dragTargetIndex: Int? = nil

    /// Approximate height of one plan row including its trailing
    /// 4pt VStack spacing. Tunable; small mismatches just mean the
    /// "snap" between slots fires a little earlier or later. Measured
    /// once and assumed uniform — every row uses the same vertical
    /// padding so this holds in practice.
    private let rowSlotHeight: CGFloat = 64

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Strategy note has moved into the recommendation header's
            // "Why" disclosure (recommendationHeader) so the home screen
            // doesn't have two stacked paragraphs of grey LLM text.

            // Move-mode banner — only visible while reorder is active.
            // Mirrors Reminders' "Done" affordance for entering/exiting
            // an explicit edit state.
            if isMoveMode {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                    Text("Drag to reorder")
                        .font(.caption.bold())
                    Spacer()
                    Button("Done") {
                        Haptics.selection()
                        withAnimation(.smooth(duration: 0.3)) { isMoveMode = false }
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.accentBlue)
                }
                .foregroundColor(.accentBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentBlue.opacity(0.08))
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Exercise list — LazyVStack, not List, so there's a single
            // scroll container (the outer ScrollView). A nested List with
            // scrollDisabled still had gesture + fixed-height-frame issues
            // that cut rows off and made scrolling feel flaky.
            // Eager VStack (not Lazy) so rows don't collapse to zero
            // height when their identity churns — the cause of the
            // mid-swap "empty gap" before. Only ~5–7 rows so eager
            // layout is cheap. Identity by exercise name; safer than
            // index-based keys when the list mutates mid-stream during
            // a streaming plan generation (an out-of-range access if
            // SwiftUI re-reads indices during a shrink).
            VStack(spacing: 4) {
                ForEach(coachVM.editedExercises) { exercise in
                    if let idx = coachVM.editedExercises.firstIndex(where: { $0.name == exercise.name }) {
                        exerciseRow(idx: idx, exercise: exercise)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                // Inline footer — always last, visually quieter than a
                // populated row. Hidden during initial generation to
                // avoid offering "Add" before the AI plan exists.
                if !coachVM.isLoadingRecommendation {
                    addExerciseFooterRow
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: coachVM.editedExercises.map(\.name))
            // Subtle dim while a new plan is regenerating — signals "this
            // is becoming stale" without flashing to empty. Existing rows
            // stay tappable; the user just sees they're being refreshed.
            .opacity((coachVM.isGenerating || coachVM.isLoadingRecommendation) ? 0.55 : 1.0)
            .animation(.smooth(duration: 0.3), value: coachVM.isGenerating)

            // Edit / Add / Regenerate moved into the recommendation
            // header's ⋯ menu (see `planMenu`). Plan section is now just
            // rows + Start.

            startControl
        }
        .sheet(isPresented: $showAddExercise) {
            AddExerciseToPlanSheet(focus: coachVM.targetMuscleGroups) { exercise in
                let newExercise = PlannedExercise(
                    name: exercise.name, sets: 3, targetReps: "8-12",
                    suggestedWeight: exercise.defaultWeight, repScheme: nil,
                    warmupSets: nil, notes: nil, intent: "isolation"
                )
                // addExerciseToPlan also archives any existing exerciseOut
                // UserRule for this exercise — user explicitly re-adding
                // is the clearest "never mind" signal.
                coachVM.addExerciseToPlan(newExercise, modelContext: modelContext)
            }
        }
    }

    @State private var showAddExercise = false
    @State private var showWatchAlert = false

    // MARK: - Button Styles

    /// Scale + opacity press feedback for inline icon buttons. `.plain`
    /// gives no visual response to a tap, which made the Today plan rows
    /// feel inert. This mirrors what `List` rows do implicitly.
    private struct PressableIconStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
                .opacity(configuration.isPressed ? 0.65 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }

    // MARK: - Exercise Row

    /// Plan-list row. No inline action buttons — all modifications happen
    /// via gestures: long-press for the context menu (Swap / Remove),
    /// pull-to-refresh on the scroll view for full regenerate, and the
    /// trailing inline "+ Add exercise" footer for additions. Matches
    /// Photos / Files / Reminders interaction model.
    /// A spinner replaces the muscle dot when this row is mid-swap so
    /// the user has feedback that the LLM call is running without
    /// reserving a permanent button slot for it.
    private func exerciseRow(idx: Int, exercise: PlannedExercise) -> some View {
        HStack(spacing: 10) {
            Group {
                if coachVM.swappingIndex == idx {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.accentBlue)
                } else {
                    Circle()
                        .fill(intentColor(exercise.intent))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(exercise.sets)×\(exercise.targetReps)")
                        .font(.caption.monospacedDigit())
                    if exercise.weight > 0 {
                        Text("@ \(Int(exercise.weight)) lbs")
                            .font(.caption)
                            .foregroundColor(.accentBlue)
                    }
                }
            }
            Spacer()
            // Drag handle — only present in move mode. Reads as
            // "you can grab this," and acts as a visual confirmation
            // the user is in reorder mode.
            if isMoveMode {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.medium))
                    .foregroundColor(.secondaryText)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isMoveMode ? Color.accentBlue.opacity(0.06) : Color.cardSurface)
        .cornerRadius(10)
        .scaleEffect(isMoveMode ? 1.0 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            // Move first — most discoverable action for "I want to
            // rearrange." Outside move mode the user can't drag, so
            // this is the entry point.
            Button {
                Haptics.selection()
                withAnimation(.smooth(duration: 0.3)) { isMoveMode = true }
            } label: {
                Label("Move", systemImage: "arrow.up.arrow.down")
            }

            Button {
                Haptics.selection()
                Task { await coachVM.quickSwap(at: idx, modelContext: modelContext) }
            } label: {
                Label("Swap Exercise", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(coachVM.swappingIndex != nil)

            Divider()

            Button(role: .destructive) {
                Haptics.warning()
                coachVM.removeExercise(at: idx, modelContext: modelContext)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        // Home-Screen-style reorder: the row itself rides the finger at
        // full size, and neighbors slide aside to open a slot. Lifted
        // row gets a soft shadow + 1.03× scale so it reads as "picked
        // up." Gated on move mode so casual touches can't trigger.
        .offset(y: rowYOffset(idx: idx))
        .scaleEffect(dragSourceIndex == idx ? 1.03 : 1.0)
        .shadow(
            color: dragSourceIndex == idx ? .black.opacity(0.18) : .clear,
            radius: 10,
            y: 4
        )
        .zIndex(dragSourceIndex == idx ? 1 : 0)
        .animation(.smooth(duration: 0.25), value: dragTargetIndex)
        .animation(.smooth(duration: 0.2), value: dragSourceIndex)
        .gesture(isMoveMode ? makeDragGesture(idx: idx) : nil)
    }

    // MARK: - Custom Drag Math

    /// Per-row Y offset during a drag.
    /// - The dragged row follows the finger directly (`dragTranslationY`).
    /// - Rows between source and target slide one slot in the opposite
    ///   direction to make room.
    /// Returns 0 for everyone when no drag is in flight.
    private func rowYOffset(idx: Int) -> CGFloat {
        guard let from = dragSourceIndex else { return 0 }
        if idx == from {
            return dragTranslationY
        }
        guard let to = dragTargetIndex, from != to else { return 0 }
        if from < to {
            // Dragging downward — rows in (from, to] slide UP one slot.
            return (idx > from && idx <= to) ? -rowSlotHeight : 0
        } else {
            // Dragging upward — rows in [to, from) slide DOWN one slot.
            return (idx >= to && idx < from) ? rowSlotHeight : 0
        }
    }

    /// Builds the drag gesture for a row. Tracks finger movement, snaps
    /// the target slot when the finger crosses the midpoint into a new
    /// row's territory, and commits on release.
    private func makeDragGesture(idx: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragSourceIndex == nil {
                    // First movement — pick up the row.
                    dragSourceIndex = idx
                    dragTargetIndex = idx
                    Haptics.impact(.light)
                }
                dragTranslationY = value.translation.height
                let count = coachVM.editedExercises.count
                guard count > 0 else { return }
                // Snap target to the slot the row's center is currently
                // occupying. Half-slot bias means the swap "feels"
                // crossing into the neighbor's space.
                let slotsMoved = Int((dragTranslationY / rowSlotHeight).rounded())
                let proposed = max(0, min(count - 1, idx + slotsMoved))
                if proposed != dragTargetIndex {
                    Haptics.selection()
                    withAnimation(.smooth(duration: 0.22)) {
                        dragTargetIndex = proposed
                    }
                }
            }
            .onEnded { _ in
                let from = dragSourceIndex
                let to = dragTargetIndex
                if let from, let to, from != to, from < coachVM.editedExercises.count {
                    Haptics.impact(.medium)
                    let name = coachVM.editedExercises[from].name
                    withAnimation(.smooth(duration: 0.3)) {
                        coachVM.moveExercise(named: name, toIndex: to)
                    }
                }
                // Reset drag state regardless of commit so visuals
                // settle cleanly even if the drag was a no-op.
                withAnimation(.smooth(duration: 0.22)) {
                    dragSourceIndex = nil
                    dragTargetIndex = nil
                    dragTranslationY = 0
                }
            }
    }

    // ReorderableModifier removed — replaced by home-screen-style
    // DragGesture math above (rowYOffset / makeDragGesture).

    // MARK: - Add-Exercise Footer Row

    /// Trailing row at the bottom of the plan list that opens the
    /// add-exercise sheet. Same Reminders / Notes pattern: the "next"
    /// row is always an inline affordance instead of a separate button
    /// elsewhere on the page.
    private var addExerciseFooterRow: some View {
        Button {
            Haptics.selection()
            showAddExercise = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundColor(.accentBlue)
                    .frame(width: 12, height: 12)
                Text("Add Exercise")
                    .font(.subheadline)
                    .foregroundColor(.accentBlue)
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline Check-In Row

    /// Compact card above the plan: feeling chips + time chips + live
    /// HealthKit recovery pills + free-text concerns. Changes stage onto
    /// `coachVM` but don't regenerate — the Refresh pill below the card
    /// becomes visible when inputs have drifted from the shown plan.
    private var checkInRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            feelingChips
            timeChips
            if healthContext != nil { recoveryPills }
            concernsField
        }
        .padding(12)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    /// Chip widths are size-limited so the row has breathing room and is
    /// harder to fat-finger. Previously each chip stretched with
    /// `.frame(maxWidth: .infinity)`, which made adjacent taps feel sloppy.
    private let chipMaxWidth: CGFloat = 56
    private let chipHeight: CGFloat = 32

    private var feelingChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How do you feel?")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        coachVM.feeling = level
                    } label: {
                        VStack(spacing: 0) {
                            Text("\(level)")
                                .font(.subheadline.bold())
                            Text(feelingLabel(level))
                                .font(.system(size: 9))
                        }
                        .frame(maxWidth: chipMaxWidth)
                        .frame(height: chipHeight + 8)
                        .background(coachVM.feeling == level ? feelingColor(level) : Color.gray.opacity(0.12))
                        .foregroundColor(coachVM.feeling == level ? .white : .primary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var timeChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Time")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
            HStack(spacing: 8) {
                // Tapping the currently-selected chip clears availableTime
                // (sets nil → AI picks). Gives the user an escape without
                // needing a separate "Any" affordance.
                ForEach([30, 45, 60, 90], id: \.self) { minutes in
                    Button {
                        coachVM.availableTime = coachVM.availableTime == minutes ? nil : minutes
                    } label: {
                        Text("\(minutes)")
                            .font(.subheadline.bold())
                            .frame(maxWidth: chipMaxWidth)
                            .frame(height: chipHeight)
                            .background(coachVM.availableTime == minutes ? Color.accentBlue : Color.gray.opacity(0.12))
                            .foregroundColor(coachVM.availableTime == minutes ? .white : .primary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var recoveryPills: some View {
        HStack(spacing: 10) {
            if let sleep = healthContext?.sleepHours {
                pill(icon: "bed.double.fill", value: String(format: "%.1fh", sleep))
            }
            if let rhr = healthContext?.restingHR {
                pill(icon: "heart.fill", value: "\(Int(rhr))")
            }
            if let hrv = healthContext?.hrv {
                pill(icon: "waveform.path.ecg", value: "\(Int(hrv))ms")
            }
            if let weight = healthContext?.bodyWeight {
                pill(icon: "scalemass.fill", value: "\(Int(weight))")
            }
            Spacer(minLength: 0)
        }
    }

    private func pill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.secondaryText)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(6)
    }

    private var concernsField: some View {
        TextField("Anything to adjust? (e.g. shoulder sore, go heavy)",
                  text: $concernsDraft, axis: .vertical)
            .lineLimit(1...3)
            .font(.caption)
            .textFieldStyle(.roundedBorder)
            .focused($concernsFocused)
            .submitLabel(.done)
            .onSubmit { commitConcerns() }
            .toolbar {
                // Keyboard toolbar Done — the only reliable dismiss for a
                // vertical-axis TextField (Return = newline, not submit).
                // Gated on focus so the toolbar doesn't stack with the
                // rest timer overlay's toolbar when present.
                if concernsFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            commitConcerns()
                            concernsFocused = false
                        }
                        .font(.subheadline.bold())
                    }
                }
            }
    }

    /// Push the local concerns draft into coachVM. No auto-regen — the
    /// Refresh pill surfaces when inputs have drifted so the user chooses
    /// when to spend the API round-trip.
    private func commitConcerns() {
        let trimmed = concernsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != coachVM.concerns else { return }
        coachVM.concerns = trimmed
    }

    // MARK: - Refresh Pill

    /// Visible only when `coachVM.isPlanStale`. Calls the cheap `refreshPlan`
    /// path (which uses `generatePlan` if a recommendation already exists —
    /// roughly half the API cost of the combined `getRecommendationAndPlan`).
    /// Pull-to-refresh still triggers the full regeneration.
    private var refreshPill: some View {
        Button {
            Task {
                await coachVM.refreshPlan(
                    modelContext: modelContext,
                    program: programVM.currentProgram
                )
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Refresh plan")
                    .font(.subheadline.bold())
                Spacer()
                Text("Inputs changed")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentBlue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func feelingLabel(_ level: Int) -> String {
        switch level {
        case 1: return "Beat"
        case 2: return "Tired"
        case 3: return "OK"
        case 4: return "Good"
        case 5: return "Great"
        default: return ""
        }
    }

    // MARK: - Helpers

    private func intentColor(_ intent: String?) -> Color {
        switch intent {
        case "primary compound": return .accentBlue
        case "secondary compound": return .pushBlue
        case "isolation": return .secondaryText
        case "finisher": return .legsOrange
        default: return .secondaryText
        }
    }

    private func feelingColor(_ level: Int) -> Color {
        switch level {
        case 1: return .failedRed
        case 2: return .legsOrange
        case 3: return .secondaryText
        case 4: return .pushBlue
        case 5: return .prGreen
        default: return .secondaryText
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "fresh": return .prGreen
        case "ready": return .pushBlue
        case "recovering": return .legsOrange
        case "sore": return .failedRed
        default: return .secondaryText
        }
    }


    // MARK: - Start Control

    /// Tap Start → phone always starts a standalone session and immediately
    /// begins broadcasting its state to the watch (applicationContext push).
    /// If the watch is present and awake, it picks the workout up from the
    /// home screen card automatically — nothing for the user to configure.
    /// If the watch isn't there, the phone runs solo. One button, one path,
    /// no "which device owns this" ceremony.
    ///
    /// Full watch engagement (HR, ring credit, HKWorkoutSession mirroring)
    /// remains available via its own entry point: tap Start directly on
    /// the watch's Plan Ready card. Starting from the watch goes through
    /// the existing watch-owner + HK mirror path unchanged.
    private var startControl: some View {
        Button {
            // Instant haptic so the tap feels acknowledged before the sheet
            // animation gets going — masks the ~0.3s presentation delay.
            Haptics.impact(.medium)
            guard let plan = coachVM.buildWatchPlan() else { return }
            phoneMirroring.startStandaloneSession(plan: plan)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentBlue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }

    // MARK: - Phone Workout Banner

    private var phoneWorkoutBanner: some View {
        Button {
            phoneMirroring.showPhoneWorkout = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundColor(.accentBlue)
                Text("Workout in progress")
                    .font(.subheadline)
                    .foregroundColor(.accentBlue)
                Spacer()
                Text("Resume")
                    .font(.caption.bold())
                    .foregroundColor(.accentBlue)
            }
            .padding(12)
            .background(Color.accentBlue.opacity(0.1))
            .cornerRadius(10)
        }
    }

}


// MARK: - Post-Workout Sheet

struct PostWorkoutSheet: View {
    let session: WorkoutSession
    @Bindable var analysisVM: AnalysisViewModel
    @Bindable var programVM: ProgramViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.prGreen)

                        Text("\(session.displayName) Complete")
                            .font(.title2.bold())

                        Text(session.date.shortFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondaryText)
                    }

                    // Stats
                    HStack(spacing: 20) {
                        statItem("\(session.entries.count)", label: "Exercises")
                        statItem("\(totalSets)", label: "Sets")
                        statItem("\(Int(totalVolume))", label: "Volume (lbs)")
                        if let duration = session.duration {
                            statItem(TimeInterval(duration).formattedDuration, label: "Duration")
                        }
                    }
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(12)

                    // AI Analysis
                    if analysisVM.isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("AI is analyzing your session...")
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        .padding()
                    }

                    if let analysis = analysisVM.currentAnalysis {
                        // Rating
                        Text(analysis.overallRating.displayName)
                            .font(.title3.bold())
                            .foregroundColor(analysis.overallRating.color)

                        // Coach note
                        Text(analysis.coachNote)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cardSurface)
                            .cornerRadius(12)

                        // PRs
                        if !analysis.progressionEvents.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Progression Events")
                                    .font(.caption.bold())
                                    .foregroundColor(.secondaryText)

                                ForEach(analysis.progressionEvents) { event in
                                    HStack(spacing: 6) {
                                        Image(systemName: event.type.contains("pr") ? "star.fill" : "arrow.right")
                                            .foregroundColor(event.type.contains("pr") ? .prGreen : .secondaryText)
                                            .font(.caption)
                                        VStack(alignment: .leading) {
                                            Text(event.exercise)
                                                .font(.subheadline.bold())
                                            Text(event.detail)
                                                .font(.caption)
                                                .foregroundColor(.secondaryText)
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color.prGreen.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }

                    if let error = analysisVM.analysisError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.failedRed)
                    }

                    // Exercise breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Exercises")
                            .font(.caption.bold())
                            .foregroundColor(.secondaryText)

                        ForEach(session.sortedEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.exerciseName)
                                    .font(.subheadline.bold())
                                ForEach(entry.workingSets) { set in
                                    Text("  \(Int(set.weight)) × \(set.reps.formattedReps)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(set.isFailed ? .failedRed : .primary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Session Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var totalSets: Int {
        session.entries.reduce(0) { $0 + $1.workingSets.count }
    }

    private var totalVolume: Double {
        session.totalVolume
    }

    private func statItem(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondaryText)
        }
    }
}

// MARK: - Add Exercise to Plan Sheet

struct AddExerciseToPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Muscle groups to prioritize in the list. Empty = show every muscle
    /// group (no narrowing). Pass `coachVM.targetMuscleGroups` to align with
    /// today's AI-recommended focus.
    let focus: [MuscleGroup]
    let onSelect: (Exercise) -> Void

    @Query private var allExercises: [Exercise]
    @State private var searchText = ""
    @State private var showAll = false

    private var filteredExercises: [Exercise] {
        let scoped: [Exercise]
        if focus.isEmpty || showAll {
            scoped = allExercises
        } else {
            scoped = allExercises.filter { focus.contains($0.muscleGroup) }
        }
        if searchText.isEmpty { return scoped }
        return scoped.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var groupedExercises: [(MuscleGroup, [Exercise])] {
        let grouped = Dictionary(grouping: filteredExercises) { $0.muscleGroup }
        return MuscleGroup.allCases.compactMap { group in
            guard let exercises = grouped[group], !exercises.isEmpty else { return nil }
            return (group, exercises)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedExercises, id: \.0) { group, exercises in
                    Section(group.displayName) {
                        ForEach(exercises) { exercise in
                            Button {
                                onSelect(exercise)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(exercise.name)
                                    Spacer()
                                    if let w = exercise.defaultWeight {
                                        Text("\(Int(w)) lbs")
                                            .font(.caption)
                                            .foregroundColor(.secondaryText)
                                    }
                                    Text(exercise.equipment.displayName)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.cardSurface)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Focus toggle — only shown when there's actually a focus to
                // widen out of; without it the button would do nothing.
                if !focus.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(showAll ? "Focus" : "All") {
                            showAll.toggle()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}
