import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var coachVM = CoachViewModel()
    @State private var programVM = ProgramViewModel()
    @State private var analysisVM = AnalysisViewModel()
    @State private var selectedCategory: WorkoutCategory?
    @State private var workoutResult: WatchWorkoutResult?
    @State private var showPostWorkout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Workout in progress banner
                    if WatchSyncService.shared.isReachable {
                        workoutInProgressBanner
                    }

                    // Week status
                    weekStatusBar

                    // Category buttons
                    categoryButtons

                    // Active plan view
                    if let category = selectedCategory {
                        ActivePlanView(
                            coachVM: coachVM,
                            programVM: programVM,
                            category: category,
                            onDismiss: { selectedCategory = nil }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
                        programVM: programVM,
                        modelContext: modelContext
                    )
                }
            }
            .animation(.easeInOut(duration: 0.25), value: selectedCategory)
        }
    }

    // MARK: - Week Status

    // MARK: - Workout Result Handling

    private func handleWorkoutResult(_ result: WatchWorkoutResult) {
        workoutResult = result
        print("[BenLift] Received workout result: \(result.entries.count) exercises, \(result.category.displayName)")

        // Persist to SwiftData
        let session = WorkoutSession(
            date: result.date,
            category: result.category,
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

    private var weekStatusBar: some View {
        let status = programVM.currentWeekStatus(modelContext: modelContext)
        return HStack {
            if status.planned > 0 {
                Text("\(status.completed)/\(status.planned) sessions this week")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            if let suggested = programVM.todaysSuggestedCategory() {
                Text("Today: \(suggested.displayName)")
                    .font(.subheadline.bold())
                    .foregroundColor(suggested.color)
            }
        }
    }

    // MARK: - Category Buttons

    private var categoryButtons: some View {
        HStack(spacing: 12) {
            ForEach(WorkoutCategory.allCases) { category in
                categoryButton(category)
            }
        }
    }

    private func categoryButton(_ category: WorkoutCategory) -> some View {
        let suggested = programVM.todaysSuggestedCategory()
        let isSuggested = category == suggested
        let isSelected = selectedCategory == category
        let daysSince = coachVM.daysSinceLast[category]

        return Button {
            if selectedCategory == category {
                selectedCategory = nil
            } else {
                // Save current plan if switching categories
                coachVM.savePlanForCurrentCategory()

                selectedCategory = category
                coachVM.selectedCategory = category

                // Try to restore a saved plan, else load defaults
                if !coachVM.restorePlan(for: category) {
                    coachVM.loadLastWeights(for: category, modelContext: modelContext)
                    coachVM.loadDefaultTemplate(category: category, modelContext: modelContext)
                }
            }
        } label: {
            VStack(spacing: 6) {
                Text(category.displayName)
                    .font(.headline)
                    .foregroundColor(isSelected ? .white : category.color)

                if let days = daysSince {
                    Text("\(days)d ago")
                        .font(.caption)
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondaryText)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isSelected ? category.color : category.color.opacity(0.15))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSuggested && !isSelected ? category.color : Color.clear, lineWidth: 2)
            )
        }
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
    let modelContext: ModelContext
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

                        Text("\(result.category.displayName) Complete")
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
