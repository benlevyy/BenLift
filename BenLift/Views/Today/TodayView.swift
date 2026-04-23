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

                    // Loading / content — use ZStack so loading doesn't shift layout
                    let isLoading = coachVM.isLoadingRecommendation || coachVM.isGenerating

                    if isLoading {
                        ThinkingView(
                            phase: coachVM.isLoadingRecommendation ? .analyzing : .building
                        )
                    } else {
                        // AI recommendation header
                        if let rec = coachVM.recommendation {
                            recommendationHeader(rec)
                        }

                        // Exercise plan
                        if !coachVM.editedExercises.isEmpty {
                            planSection
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

    private func recommendationHeader(_ rec: RecoveryRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.recommendedSessionName)
                .font(.title3.bold())

            Text(rec.reasoning)
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Plan Section

    @State private var isEditingPlan = false

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Strategy note
            if let strategy = coachVM.currentPlan?.sessionStrategy {
                Text(strategy)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
            }

            // Exercise list — LazyVStack, not List, so there's a single
            // scroll container (the outer ScrollView). A nested List with
            // scrollDisabled still had gesture + fixed-height-frame issues
            // that cut rows off and made scrolling feel flaky.
            LazyVStack(spacing: 4) {
                ForEach(Array(coachVM.editedExercises.enumerated()), id: \.element.name) { idx, exercise in
                    exerciseRow(idx: idx, exercise: exercise)
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    isEditingPlan.toggle()
                } label: {
                    Text(isEditingPlan ? "Done" : "Edit")
                        .font(.caption)
                        .foregroundColor(.accentBlue)
                }

                Spacer()

                Button {
                    showAddExercise = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(.caption)
                    .foregroundColor(.accentBlue)
                }
            }

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

    /// Single plan-list row. Always-visible quick-swap button; delete button
    /// surfaces only in edit mode (`isEditingPlan`). Uses `PressableIconStyle`
    /// so the inline buttons have real press feedback (previous `.plain`
    /// style gave no visual response, which read as "broken"). Tap targets
    /// are a full 44×44 per Apple's HIG minimum.
    private func exerciseRow(idx: Int, exercise: PlannedExercise) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(intentColor(exercise.intent))
                .frame(width: 8, height: 8)

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

            // Delete — visible only in edit mode. Passes modelContext so
            // the removal also writes a durable exerciseOut UserRule
            // (the AI respects these deterministically next time it
            // plans).
            if isEditingPlan {
                Button {
                    coachVM.removeExercise(at: idx, modelContext: modelContext)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.failedRed)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableIconStyle())
            }

            // Quick swap — AI picks a similar alternative, no user input.
            Button {
                Task { await coachVM.quickSwap(at: idx, modelContext: modelContext) }
            } label: {
                Group {
                    if coachVM.swappingIndex == idx {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.accentBlue)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Color.accentBlue.opacity(0.15))
                .clipShape(Circle())
                .frame(width: 44, height: 44)  // 44pt hit area, 36pt visual
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableIconStyle())
            .disabled(coachVM.swappingIndex != nil)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.cardSurface)
        .cornerRadius(10)
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
