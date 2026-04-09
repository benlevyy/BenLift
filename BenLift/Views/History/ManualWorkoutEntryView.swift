import SwiftUI
import SwiftData

struct ManualWorkoutEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var sessionName = ""
    @State private var workoutDate = Date()
    @State private var durationMinutes = ""
    @State private var exercises: [ManualExercise] = []
    @State private var showAddExercise = false
    @State private var expandedExerciseId: String?
    @State private var savedSession: WorkoutSession?
    @State private var analysisVM = AnalysisViewModel()

    struct ManualExercise: Identifiable {
        let id = UUID().uuidString
        let name: String
        let muscleGroup: MuscleGroup
        var sets: [ManualSet] = []
    }

    struct ManualSet: Identifiable {
        let id = UUID().uuidString
        var weight: Double = 0
        var reps: Double = 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Session info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Info")
                            .font(.caption.bold())
                            .foregroundColor(.secondaryText)

                        TextField("Session name (optional)", text: $sessionName)
                            .textFieldStyle(.roundedBorder)

                        DatePicker("Date", selection: $workoutDate, displayedComponents: [.date, .hourAndMinute])
                            .font(.subheadline)

                        HStack {
                            Text("Duration (min)")
                                .font(.subheadline)
                            Spacer()
                            TextField("--", text: $durationMinutes)
                                .keyboardType(.numberPad)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(12)

                    // Exercises
                    if exercises.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "dumbbell")
                                .font(.title)
                                .foregroundColor(.secondaryText)
                            Text("No exercises added yet")
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                                exerciseCard(exercise, at: index)
                            }
                        }
                    }

                    // Add exercise button
                    Button {
                        showAddExercise = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Exercise")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentBlue.opacity(0.1))
                        .foregroundColor(.accentBlue)
                        .cornerRadius(12)
                    }

                    // Summary + Save
                    if !exercises.isEmpty {
                        summarySection

                        Button {
                            saveWorkout()
                        } label: {
                            Text("Save Workout")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(canSave ? Color.accentBlue : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        .disabled(!canSave)
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Log Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddExercise) {
                AllExercisePickerSheet { exercise in
                    let manual = ManualExercise(
                        name: exercise.name,
                        muscleGroup: exercise.muscleGroup,
                        sets: [ManualSet()]
                    )
                    exercises.append(manual)
                    expandedExerciseId = manual.id
                }
            }
            .sheet(item: $savedSession) { session in
                PostWorkoutSheet(
                    session: session,
                    analysisVM: analysisVM,
                    programVM: ProgramViewModel()
                )
                .onDisappear { dismiss() }
            }
        }
    }

    // MARK: - Exercise Card

    private func exerciseCard(_ exercise: ManualExercise, at index: Int) -> some View {
        let isExpanded = expandedExerciseId == exercise.id

        return VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedExerciseId = isExpanded ? nil : exercise.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(exercise.muscleGroup.displayName.prefix(1))
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentBlue)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            if !exercise.sets.isEmpty {
                                Text("\(exercise.sets.count) set\(exercise.sets.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }

                Button(role: .destructive) {
                    withAnimation { _ = exercises.remove(at: index) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.secondaryText.opacity(0.5))
                }
            }

            if isExpanded {
                // Set rows
                ForEach(Array(exercises[index].sets.enumerated()), id: \.element.id) { setIndex, set in
                    setRow(exerciseIndex: index, setIndex: setIndex, set: set)
                }

                // Add set button
                Button {
                    let lastSet = exercises[index].sets.last
                    exercises[index].sets.append(ManualSet(
                        weight: lastSet?.weight ?? 0,
                        reps: lastSet?.reps ?? 0
                    ))
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add Set")
                    }
                    .font(.caption)
                    .foregroundColor(.accentBlue)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Set Row

    private func setRow(exerciseIndex: Int, setIndex: Int, set: ManualSet) -> some View {
        HStack(spacing: 12) {
            Text("Set \(setIndex + 1)")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .frame(width: 40)

            HStack(spacing: 4) {
                TextField("0", value: $exercises[exerciseIndex].sets[setIndex].weight, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 65)
                    .multilineTextAlignment(.center)
                Text("lbs")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            HStack(spacing: 4) {
                TextField("0", value: $exercises[exerciseIndex].sets[setIndex].reps, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                Text("reps")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            Spacer()

            if exercises[exerciseIndex].sets.count > 1 {
                Button {
                    exercises[exerciseIndex].sets.remove(at: setIndex)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .foregroundColor(.failedRed)
                }
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        let setCount = exercises.reduce(0) { $0 + $1.sets.count }
        let volume = exercises.reduce(0.0) { total, ex in
            total + ex.sets.reduce(0.0) { $0 + $1.weight * floor($1.reps) }
        }

        return HStack(spacing: 20) {
            VStack(spacing: 2) {
                Text("\(exercises.count)")
                    .font(.headline.monospacedDigit())
                Text("Exercises")
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }
            VStack(spacing: 2) {
                Text("\(setCount)")
                    .font(.headline.monospacedDigit())
                Text("Sets")
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }
            VStack(spacing: 2) {
                Text("\(Int(volume))")
                    .font(.headline.monospacedDigit())
                Text("Volume")
                    .font(.caption2)
                    .foregroundColor(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Validation

    private var canSave: Bool {
        exercises.contains { ex in
            ex.sets.contains { $0.reps > 0 }
        }
    }

    // MARK: - Save

    private func saveWorkout() {
        // Determine muscle groups from exercises
        let muscleGroups = Array(Set(exercises.map(\.muscleGroup)))

        let duration: Double? = if let mins = Double(durationMinutes), mins > 0 {
            mins * 60
        } else {
            nil
        }

        let session = WorkoutSession(
            date: workoutDate,
            sessionName: sessionName.isEmpty ? nil : sessionName,
            muscleGroups: muscleGroups,
            duration: duration,
            aiPlanUsed: false
        )

        for (order, exercise) in exercises.enumerated() {
            let setsWithData = exercise.sets.filter { $0.reps > 0 }
            guard !setsWithData.isEmpty else { continue }

            let entry = ExerciseEntry(
                exerciseName: exercise.name,
                order: order
            )

            for (setNum, set) in setsWithData.enumerated() {
                let setLog = SetLog(
                    setNumber: setNum + 1,
                    weight: set.weight,
                    reps: set.reps,
                    timestamp: workoutDate
                )
                entry.sets.append(setLog)
            }
            session.entries.append(entry)
        }

        modelContext.insert(session)
        try? modelContext.save()
        print("[BenLift] Manually saved workout: \(session.entries.count) exercises")

        // Show post-workout sheet with AI analysis
        savedSession = session
        Task {
            await analysisVM.analyzeWorkout(
                session: session,
                planSummary: nil,
                modelContext: modelContext,
                program: nil,
                healthContext: nil
            )
        }
    }
}

// MARK: - All Exercise Picker (not filtered by category)

struct AllExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Exercise) -> Void

    @Query private var allExercises: [Exercise]
    @State private var searchText = ""

    private var filteredExercises: [Exercise] {
        if searchText.isEmpty { return allExercises }
        return allExercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var groupedExercises: [(MuscleGroup, [Exercise])] {
        let grouped = Dictionary(grouping: filteredExercises) { $0.muscleGroup }
        return MuscleGroup.allCases.compactMap { group in
            guard let exercises = grouped[group], !exercises.isEmpty else { return nil }
            return (group, exercises.sorted { $0.name < $1.name })
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
