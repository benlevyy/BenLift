import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
    @State private var analysisVM = AnalysisViewModel()
    @State private var selectedCategory: WorkoutCategory?
    @State private var workoutResult: WatchWorkoutResult?
    @State private var showPostWorkout = false

    // Check-in state
    @State private var feeling: Int = 3
    @State private var sorenessText: String = ""
    @State private var showPlanView = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Workout in progress banner
                    if WatchSyncService.shared.isWorkoutActive {
                        workoutInProgressBanner
                    }

                    // Loading state
                    if coachVM.isLoadingRecommendation || coachVM.isGenerating {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(coachVM.isLoadingRecommendation ? "Analyzing recovery..." : "Building plan...")
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    // AI recommendation header (if available)
                    if let rec = coachVM.recommendation {
                        recommendationHeader(rec)
                    }

                    // Exercise plan (if generated)
                    if !coachVM.editedExercises.isEmpty {
                        planSection
                            .id(planRevision)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Adjust section — feeling + soreness + regenerate
                    adjustSection

                    // Error
                    if let error = coachVM.planError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.failedRed)
                            .padding(8)
                            .background(Color.failedRed.opacity(0.1))
                            .cornerRadius(6)
                    }

                    // Quick PPL fallback (collapsed)
                    pplFallbackButtons
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Today")
            .onAppear {
                coachVM.calculateDaysSinceLast(modelContext: modelContext)
                programVM.loadCurrentProgram(modelContext: modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workoutResultReceived)) { _ in
                if let result = WatchSyncService.shared.receivedWorkoutResult {
                    handleWorkoutResult(result)
                }
            }
            .sheet(isPresented: $showPostWorkout) {
                if let result = workoutResult {
                    PostWorkoutSheet(
                        result: result,
                        analysisVM: analysisVM,
                        programVM: programVM
                    )
                }
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

            // Exercise list
            List {
                ForEach(Array(coachVM.editedExercises.enumerated()), id: \.element.name) { _, exercise in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(intentColor(exercise.intent))
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(.subheadline.bold())
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
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in coachVM.moveExercise(from: from, to: to) }
                .onDelete { offsets in
                    for i in offsets { coachVM.removeExercise(at: i) }
                }
            }
            .listStyle(.plain)
            .frame(height: CGFloat(coachVM.editedExercises.count * 52 + 8))
            .environment(\.editMode, .constant(isEditingPlan ? .active : .inactive))

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

            // Send to Watch
            Button {
                if let plan = coachVM.buildWatchPlan() {
                    WatchSyncService.shared.sendWorkoutPlan(plan)
                    showWatchAlert = true
                }
            } label: {
                HStack {
                    Image(systemName: "applewatch")
                    Text("Send to Watch")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(coachVM.recommendation != nil ? Color.accentBlue : Color.pushBlue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .alert("Plan Sent", isPresented: $showWatchAlert) {
                Button("OK") {}
            } message: {
                Text("Your workout plan has been sent to your Apple Watch.")
            }
        }
        .sheet(isPresented: $showAddExercise) {
            AddExerciseToPlanSheet(category: selectedCategory ?? .push) { exercise in
                let newExercise = PlannedExercise(
                    name: exercise.name, sets: 3, targetReps: "8-12",
                    suggestedWeight: exercise.defaultWeight, repScheme: nil,
                    warmupSets: nil, notes: nil, intent: "isolation"
                )
                coachVM.editedExercises.append(newExercise)
            }
        }
    }

    @State private var showAddExercise = false
    @State private var showWatchAlert = false

    // MARK: - Adjust Section

    @State private var showAdjustSheet = false
    @State private var adjustText = ""
    @State private var planRevision = 0 // triggers animation on change

    private var adjustSection: some View {
        Button {
            showAdjustSheet = true
        } label: {
            HStack {
                Image(systemName: "pencil.circle.fill")
                Text("Adjust Plan")
            }
            .font(.subheadline)
            .foregroundColor(.accentBlue)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.accentBlue.opacity(0.1))
            .cornerRadius(10)
        }
        .sheet(isPresented: $showAdjustSheet) {
            adjustSheetContent
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var adjustSheetContent: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Feeling
                VStack(alignment: .leading, spacing: 8) {
                    Text("How do you feel?")
                        .font(.subheadline.bold())
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { level in
                            Button {
                                feeling = level
                            } label: {
                                Text("\(level)")
                                    .font(.headline)
                                    .frame(width: 48, height: 48)
                                    .background(feeling == level ? feelingColor(level) : Color.cardSurface)
                                    .foregroundColor(feeling == level ? .white : .primary)
                                    .cornerRadius(12)
                            }
                        }
                    }
                }

                // What to change
                VStack(alignment: .leading, spacing: 8) {
                    Text("What should change?")
                        .font(.subheadline.bold())
                    TextField("e.g. legs sore, swap OHP for machine, more chest...", text: $adjustText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                }

                Spacer()

                // Submit
                Button {
                    showAdjustSheet = false
                    coachVM.feeling = feeling
                    coachVM.concerns = adjustText
                    adjustText = ""
                    Task {
                        withAnimation(.easeOut(duration: 0.3)) {
                            planRevision += 1  // triggers fade-out
                        }
                        await coachVM.getRecommendationAndPlan(modelContext: modelContext, program: programVM.currentProgram)
                        withAnimation(.easeIn(duration: 0.3)) {
                            planRevision += 1  // triggers fade-in
                        }
                    }
                } label: {
                    Text("Regenerate Plan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentBlue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding()
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdjustSheet = false }
                }
            }
        }
    }

    // MARK: - PPL Fallback Buttons

    private var pplFallbackButtons: some View {
        DisclosureGroup("Quick Start (Push / Pull / Legs)") {
            HStack(spacing: 8) {
                ForEach(WorkoutCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                        coachVM.selectedCategory = category
                        coachVM.targetMuscleGroups = category.muscleGroups
                        coachVM.currentSessionName = category.displayName
                        coachVM.loadLastWeights(for: category, modelContext: modelContext)
                        coachVM.loadDefaultTemplate(category: category, modelContext: modelContext)
                        showPlanView = true
                    } label: {
                        Text(category.displayName)
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(category.color.opacity(0.2))
                            .foregroundColor(category.color)
                            .cornerRadius(8)
                    }
                }
            }
        }
        .font(.subheadline)
        .foregroundColor(.secondaryText)
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

    // MARK: - Workout Result Handling

    private func handleWorkoutResult(_ result: WatchWorkoutResult) {
        workoutResult = result
        print("[BenLift] Received workout result: \(result.entries.count) exercises, \(result.sessionName ?? result.category?.displayName ?? "Workout")")

        // Persist to SwiftData
        let muscleGroups = (result.muscleGroups ?? []).compactMap { MuscleGroup(rawValue: $0) }
        let session = WorkoutSession(
            date: result.date,
            category: result.category,
            sessionName: result.sessionName,
            muscleGroups: muscleGroups,
            duration: result.duration,
            feeling: result.feeling,
            concerns: result.concerns,
            aiPlanUsed: coachVM.currentPlan != nil
        )

        for entry in result.entries {
            let exerciseEntry = ExerciseEntry(
                exerciseName: entry.exerciseName,
                order: entry.order
            )
            for set in entry.sets {
                let setLog = SetLog(
                    setNumber: set.setNumber,
                    weight: set.weight,
                    reps: set.reps,
                    timestamp: set.timestamp,
                    isWarmup: set.isWarmup
                )
                exerciseEntry.sets.append(setLog)
            }
            session.entries.append(exerciseEntry)
        }

        modelContext.insert(session)
        try? modelContext.save()
        print("[BenLift] Saved workout session to SwiftData")

        // Show post-workout sheet
        showPostWorkout = true

        // Trigger AI analysis
        Task {
            await analysisVM.analyzeWorkout(
                session: session,
                planSummary: coachVM.currentPlan?.sessionStrategy,
                modelContext: modelContext,
                program: programVM.currentProgram,
                healthContext: nil // TODO: HEALTHKIT
            )
        }

        // Refresh days since last
        coachVM.calculateDaysSinceLast(modelContext: modelContext)
    }

    private var workoutInProgressBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "applewatch")
                .foregroundColor(.prGreen)
            Text("Workout active on Watch")
                .font(.subheadline)
                .foregroundColor(.prGreen)
            Spacer()
            Circle()
                .fill(Color.prGreen)
                .frame(width: 8, height: 8)
        }
        .padding(12)
        .background(Color.prGreen.opacity(0.1))
        .cornerRadius(10)
    }

}

// MARK: - Active Plan View

struct ActivePlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
    let category: WorkoutCategory
    let onDismiss: () -> Void

    @State private var showAIAdjust = false
    @State private var showWatchAlert = false
    @State private var showAddExercise = false
    @State private var feeling: Int = 3
    @State private var concerns: String = ""
    @State private var isEditing = false
    @State private var iterateText: String = ""

    @Query private var allExercises: [Exercise]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("\(category.displayName) Plan")
                    .font(.title3.bold())

                Spacer()

                Button {
                    isEditing.toggle()
                } label: {
                    Text(isEditing ? "Done" : "Edit")
                        .font(.subheadline)
                        .foregroundColor(.accentBlue)
                }

                Button {
                    showAIAdjust = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("AI")
                    }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentBlue.opacity(0.15))
                    .foregroundColor(.accentBlue)
                    .cornerRadius(8)
                }
            }

            // Strategy note + iterate
            if let strategy = coachVM.currentPlan?.sessionStrategy {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.accentBlue)
                            .font(.caption)
                            .padding(.top, 2)
                        Text(strategy)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }

                    // Iterate on the plan
                    HStack(spacing: 8) {
                        TextField("e.g. drop leg extension, go heavier on bench", text: $iterateText, axis: .vertical)
                            .font(.caption)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit { submitIteration() }

                        Button {
                            submitIteration()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(iterateText.isEmpty ? .secondaryText : .accentBlue)
                        }
                        .disabled(iterateText.isEmpty || coachVM.isGenerating)
                    }
                }
                .padding(10)
                .background(Color.cardSurface)
                .cornerRadius(8)
            }

            // Loading
            if coachVM.isGenerating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("AI is adjusting your plan...")
                        .foregroundColor(.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding()
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

            // Exercise list — editable
            List {
                ForEach(Array(coachVM.editedExercises.enumerated()), id: \.element.name) { index, exercise in
                    exerciseRow(exercise)
                }
                .onMove { from, to in
                    coachVM.moveExercise(from: from, to: to)
                }
                .onDelete { offsets in
                    for i in offsets {
                        coachVM.removeExercise(at: i)
                    }
                }

                // Add exercise button
                Button {
                    showAddExercise = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentBlue)
                        Text("Add Exercise")
                            .foregroundColor(.accentBlue)
                    }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: CGFloat(coachVM.editedExercises.count * 72 + 44))
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))

            // Stats
            HStack {
                Text("\(coachVM.editedExercises.count) exercises")
                Text("•")
                Text("\(coachVM.editedExercises.reduce(0) { $0 + $1.sets }) sets")
                if let duration = coachVM.currentPlan?.estimatedDuration {
                    Text("•")
                    Text("~\(duration) min")
                }
            }
            .font(.caption)
            .foregroundColor(.secondaryText)

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    coachVM.savePlanForCurrentCategory()
                    onDismiss()
                } label: {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cardSurface)
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button {
                    if let plan = coachVM.buildWatchPlan() {
                        WatchSyncService.shared.sendWorkoutPlan(plan)
                        showWatchAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "applewatch")
                        Text("Send to Watch")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(category.color)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .alert("Plan Sent", isPresented: $showWatchAlert) {
                    Button("OK") {}
                } message: {
                    Text("Your \(category.displayName) plan has been sent to your Apple Watch.")
                }
            }
        }
        .sheet(isPresented: $showAIAdjust) {
            AIAdjustSheet(
                coachVM: coachVM,
                program: programVM.currentProgram,
                category: category,
                feeling: $feeling,
                concerns: $concerns
            )
        }
        .sheet(isPresented: $showAddExercise) {
            AddExerciseToPlanSheet(category: category) { exercise in
                let newExercise = PlannedExercise(
                    name: exercise.name,
                    sets: 3,
                    targetReps: "8-12",
                    suggestedWeight: exercise.defaultWeight ?? 0,
                    repScheme: nil,
                    warmupSets: nil,
                    notes: nil,
                    intent: "isolation"
                )
                coachVM.editedExercises.append(newExercise)
            }
        }
    }

    private func exerciseRow(_ exercise: PlannedExercise) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(intentColor(exercise.intent))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.body.bold())

                HStack(spacing: 6) {
                    Text("\(exercise.sets) × \(exercise.targetReps)")
                        .font(.subheadline.monospacedDigit())
                    Text("@ \(Int(exercise.weight)) lbs")
                        .font(.subheadline)
                        .foregroundColor(.accentBlue)
                }
            }

            Spacer()

            if let warmups = exercise.warmupSets, !warmups.isEmpty {
                Text("\(warmups.count) warm-up")
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func submitIteration() {
        guard !iterateText.isEmpty, !coachVM.isGenerating else { return }
        coachVM.concerns = iterateText
        iterateText = ""
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            await coachVM.generatePlan(modelContext: modelContext, program: programVM.currentProgram)
        }
    }

    private func intentColor(_ intent: String?) -> Color {
        switch intent {
        case "primary compound": return .accentBlue
        case "secondary compound": return .pushBlue
        case "isolation": return .secondaryText
        case "finisher": return .legsOrange
        default: return .secondaryText
        }
    }
}

// MARK: - AI Adjust Sheet

struct AIAdjustSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var coachVM: CoachViewModel
    let program: TrainingProgram?
    let category: WorkoutCategory
    @Binding var feeling: Int
    @Binding var concerns: String

    @State private var healthContext: HealthContext?

    private let feelingLabels = ["Wrecked", "Rough", "Okay", "Good", "Great"]
    private let timeOptions = [30, 45, 60, 75]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Program-level context (read-only summary)
                    if let program {
                        programContextCard(program)
                    }

                    if let hc = healthContext {
                        healthCard(hc)
                    }

                    // Daily-level inputs
                    dailyHeader

                    // Feeling
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How do you feel?")
                            .font(.headline)

                        HStack(spacing: 6) {
                            ForEach(1...5, id: \.self) { value in
                                Button {
                                    feeling = value
                                    coachVM.feeling = value
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("\(value)")
                                            .font(.title3.bold())
                                        Text(feelingLabels[value - 1])
                                            .font(.caption2)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(feeling == value ? Color.accentBlue.opacity(0.3) : Color.cardSurface)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Time
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available time")
                            .font(.headline)

                        HStack(spacing: 6) {
                            ForEach(timeOptions, id: \.self) { minutes in
                                Button {
                                    coachVM.availableTime = minutes
                                } label: {
                                    Text(minutes == 75 ? "75+" : "\(minutes)")
                                        .font(.body.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(coachVM.availableTime == minutes ? Color.accentBlue.opacity(0.3) : Color.cardSurface)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("minutes")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }

                    // Today's concerns
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Today's adjustments")
                            .font(.headline)
                        TextField("e.g. shoulder sore, go heavy, skip isolation", text: $concerns, axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Generate
                    Button {
                        coachVM.concerns = concerns
                        dismiss()
                        Task {
                            await coachVM.generatePlan(modelContext: modelContext, program: program)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text(coachVM.isGenerating ? "Generating..." : "Generate AI Plan")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentBlue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(coachVM.isGenerating)
                }
                .padding()
            }
            .navigationTitle("AI Adjust — \(category.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { healthContext = await HealthKitService.shared.fetchHealthContext() }
    }

    private func healthCard(_ hc: HealthContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.failedRed)
                Text("Today's Recovery")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                    .textCase(.uppercase)
            }

            HStack(spacing: 16) {
                if let sleep = hc.sleepHours {
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", sleep))
                            .font(.title3.bold().monospacedDigit())
                        Text("hrs sleep")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }
                if let rhr = hc.restingHR {
                    VStack(spacing: 2) {
                        Text("\(Int(rhr))")
                            .font(.title3.bold().monospacedDigit())
                        Text("resting HR")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }
                if let hrv = hc.hrv {
                    VStack(spacing: 2) {
                        Text("\(Int(hrv))")
                            .font(.title3.bold().monospacedDigit())
                        Text("HRV ms")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }
                if let weight = hc.bodyWeight {
                    VStack(spacing: 2) {
                        Text("\(Int(weight))")
                            .font(.title3.bold().monospacedDigit())
                        Text("lbs")
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                    }
                }
            }

            if hc.sleepHours == nil && hc.restingHR == nil && hc.hrv == nil {
                Text("No health data available. Grant HealthKit access in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(10)
        .background(Color.cardSurface)
        .cornerRadius(8)
    }

    private var dailyHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundColor(.secondaryText)
            Text("Today's Parameters")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)
            Spacer()
        }
    }

    private func programContextCard(_ program: TrainingProgram) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.secondaryText)
                Text("AI Already Knows")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                    .textCase(.uppercase)
                Spacer()
                Text("Edit in Program tab")
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(program.goal) • \(program.daysPerWeek) days/week")
                    .font(.caption)
                if let activities = program.otherActivities, !activities.isEmpty {
                    Text(activities)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
                if let priorities = program.musclePriorities, !priorities.isEmpty {
                    Text("Priority: \(priorities)")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
                if let concerns = program.ongoingConcerns, !concerns.isEmpty {
                    Text(concerns)
                        .font(.caption)
                        .foregroundColor(.failedRed.opacity(0.8))
                }
            }
        }
        .padding(10)
        .background(Color.cardSurface)
        .cornerRadius(8)
    }
}

// MARK: - Post-Workout Sheet

struct PostWorkoutSheet: View {
    let result: WatchWorkoutResult
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

                        Text("\(result.sessionName ?? result.category?.displayName ?? "Workout") Complete")
                            .font(.title2.bold())

                        Text(result.date.shortFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondaryText)
                    }

                    // Stats
                    HStack(spacing: 20) {
                        statItem("\(result.entries.count)", label: "Exercises")
                        statItem("\(totalSets)", label: "Sets")
                        statItem("\(Int(totalVolume))", label: "Volume (lbs)")
                        statItem(TimeInterval(result.duration).formattedDuration, label: "Duration")
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

                        ForEach(result.entries, id: \.exerciseName) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.exerciseName)
                                    .font(.subheadline.bold())
                                ForEach(entry.sets.filter { !$0.isWarmup }, id: \.setNumber) { set in
                                    Text("  \(Int(set.weight)) × \(set.reps.formattedReps)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(set.reps.truncatingRemainder(dividingBy: 1) != 0 ? .failedRed : .primary)
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
        result.entries.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
    }

    private var totalVolume: Double {
        result.entries.reduce(0.0) { total, entry in
            total + entry.sets.filter { !$0.isWarmup }.reduce(0.0) { $0 + $1.weight * floor($1.reps) }
        }
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
    let category: WorkoutCategory
    let onSelect: (Exercise) -> Void

    @Query private var allExercises: [Exercise]
    @State private var searchText = ""

    private var filteredExercises: [Exercise] {
        let categoryExercises = allExercises.filter { category.muscleGroups.contains($0.muscleGroup) }
        if searchText.isEmpty { return categoryExercises }
        return categoryExercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
            }
        }
    }
}
