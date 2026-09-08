import SwiftUI
import SwiftData
import Charts

struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let session: WorkoutSession
    @State private var isEditing = false
    @State private var showAddExercise = false
    @State private var editSnapshot = ""  // fingerprint of data when edit started

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Exercises
                if isEditing {
                    editableExercisesSection
                } else {
                    exercisesSection
                }

                // Pre-workout notes
                if session.feeling != nil || session.concerns != nil {
                    preWorkoutSection
                }
            }
            .padding()
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Done") {
                        saveEdits()
                    }
                    .bold()
                } else {
                    Button("Edit") {
                        editSnapshot = sessionFingerprint()
                        isEditing = true
                    }
                }
            }
        }
        .sheet(isPresented: $showAddExercise) {
            AllExercisePickerSheet { exercise in
                let order = session.entries.count
                let entry = ExerciseEntry(exerciseName: exercise.name, order: order)
                let set = SetLog(setNumber: 1, weight: exercise.defaultWeight ?? 0, reps: 0)
                entry.sets.append(set)
                session.entries.append(entry)
            }
        }
        .onAppear { loadAnalysis() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date.shortFormatted)
                    .font(.headline)
                HStack(spacing: 12) {
                    if let duration = session.duration {
                        Label(TimeInterval(duration).formattedDuration, systemImage: "clock")
                    }
                    Label("\(Int(session.totalVolume)) lbs", systemImage: "scalemass")
                }
                .font(.subheadline)
                .foregroundColor(.secondaryText)
            }

            Spacer()

        }
    }

    // MARK: - Read-Only Exercises

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exercises")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            ForEach(session.sortedEntries) { entry in
                // Skipped entries: ghosted card + strikethrough name +
                // "skipped" label. They're kept in the list (instead of
                // filtered out) so the user can see what they bailed on —
                // the data feeds the AI's patterns card.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(entry.exerciseName)
                            .font(.body.bold())
                            .strikethrough(entry.isSkipped, color: .secondaryText)
                            .foregroundColor(entry.isSkipped ? .secondaryText : .primary)
                        if entry.isSkipped {
                            Text("skipped")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondaryText.opacity(0.15))
                                .foregroundColor(.secondaryText)
                                .cornerRadius(4)
                        }
                    }

                    if !entry.isSkipped {
                        ForEach(entry.sortedSets) { set in
                            HStack {
                                Text("Set \(set.setNumber)")
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                                    .frame(width: 50, alignment: .leading)

                                Text("\(Int(set.weight)) x \(set.reps.formattedReps)")
                                    .font(.body.monospacedDigit())
                                    .foregroundColor(set.isFailed ? .failedRed : .primary)

                                if set.isWarmup {
                                    Text("warm-up")
                                        .font(.caption2)
                                        .foregroundColor(.secondaryText)
                                }

                                Spacer()
                            }
                        }

                        Text("Volume: \(Int(entry.totalVolume)) lbs")
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                    }
                }
                .padding()
                .background(Color.cardSurface.opacity(entry.isSkipped ? 0.4 : 1))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Editable Exercises

    private var editableExercisesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Exercises")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                    .textCase(.uppercase)
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

            ForEach(session.sortedEntries) { entry in
                editableExerciseCard(entry)
            }
        }
    }

    private func editableExerciseCard(_ entry: ExerciseEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.exerciseName)
                    .font(.body.bold())
                Spacer()
                Button(role: .destructive) {
                    deleteEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.failedRed)
                }
            }

            ForEach(entry.sortedSets) { set in
                editableSetRow(set, entry: entry)
            }

            // Add set button
            Button {
                addSet(to: entry)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Set")
                }
                .font(.caption)
                .foregroundColor(.accentBlue)
            }
            .padding(.top, 2)
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(8)
    }

    private func editableSetRow(_ set: SetLog, entry: ExerciseEntry) -> some View {
        HStack(spacing: 12) {
            Text("Set \(set.setNumber)")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .frame(width: 40)

            HStack(spacing: 4) {
                TextField("0", value: Binding(
                    get: { set.weight },
                    set: { set.weight = $0 }
                ), format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 65)
                    .multilineTextAlignment(.center)
                Text("lbs")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            HStack(spacing: 4) {
                TextField("0", value: Binding(
                    get: { set.reps },
                    set: { set.reps = $0 }
                ), format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                Text("reps")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            Spacer()

            if entry.sets.count > 1 {
                Button {
                    deleteSet(set, from: entry)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .foregroundColor(.failedRed)
                }
            }
        }
    }

    // MARK: - Pre-Workout

    private var preWorkoutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pre-Workout")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if let feeling = session.feeling {
                Text("Feeling: \(feeling)/5")
                    .font(.caption)
            }
            if let concerns = session.concerns, !concerns.isEmpty {
                Text("Concerns: \(concerns)")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(8)
    }

    // MARK: - Edit Actions

    private func addSet(to entry: ExerciseEntry) {
        let lastSet = entry.sortedSets.last
        let newSet = SetLog(
            setNumber: (lastSet?.setNumber ?? 0) + 1,
            weight: lastSet?.weight ?? 0,
            reps: lastSet?.reps ?? 0,
            timestamp: session.date
        )
        entry.sets.append(newSet)
    }

    private func deleteSet(_ set: SetLog, from entry: ExerciseEntry) {
        entry.sets.removeAll { $0.id == set.id }
        // Renumber
        for (i, s) in entry.sortedSets.enumerated() {
            s.setNumber = i + 1
        }
    }

    private func deleteEntry(_ entry: ExerciseEntry) {
        for set in entry.sets { modelContext.delete(set) }
        session.entries.removeAll { $0.id == entry.id }
        modelContext.delete(entry)
    }

    // MARK: - Save & Reanalyze

    private func saveEdits() {
        guard isEditing else { return }
        isEditing = false

        // Remove empty entries
        let emptyEntries = session.entries.filter { $0.sets.isEmpty }
        for entry in emptyEntries {
            session.entries.removeAll { $0.id == entry.id }
            modelContext.delete(entry)
        }

        // Check if anything actually changed
        let currentFingerprint = sessionFingerprint()
        let hasChanges = currentFingerprint != editSnapshot

        try? modelContext.save()

        guard hasChanges else { return }

        // Editing a past session used to trigger a fresh analysis call. It
        // no longer does anything except change the record — which is all
        // editing a past session should ever have done.
        print("[BenLift] Saved session edits: \(session.entries.count) exercises")
    }

    private func sessionFingerprint() -> String {
        session.sortedEntries.map { entry in
            let sets = entry.sortedSets.map { "\($0.weight)-\($0.reps)-\($0.isWarmup)" }.joined(separator: "|")
            return "\(entry.exerciseName):\(sets)"
        }.joined(separator: ";")
    }

}
