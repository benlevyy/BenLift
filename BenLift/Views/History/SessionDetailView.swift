import SwiftUI
import SwiftData
import Charts

struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let session: WorkoutSession
    @State private var isEditing = false
    @State private var showAddExercise = false
    @State private var editSnapshot = ""  // fingerprint of data when edit started
    @State private var showChat = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Sessions carry no AI summary any more — the post-workout
                // analysis call is gone. This is the replacement: nothing is
                // spent until there's actually a question.
                askButton

                // Exercises
                if isEditing {
                    editableExercisesSection
                } else {
                    exercisesSection
                }

                // Notes — editable in place. Nothing in the app wrote this
                // field before (the finish sheet passed nil), so a session
                // that needed a note had nowhere to put one.
                notesSection

                if let feeling = session.feeling {
                    feelingRow(feeling)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showChat) {
            SessionChatSheet(session: session)
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
                        beginEditing()
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
    }

    private var askButton: some View {
        Button {
            Haptics.selection()
            showChat = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .medium))
                Text("Ask about this session")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tertiaryText)
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
                        // The name opens that lift's history — every
                        // session it appeared in, and where the weight
                        // moved. "Where did I bump this" is answered from
                        // the place the question comes up.
                        NavigationLink {
                            ExerciseProgressView(exerciseName: entry.exerciseName)
                        } label: {
                            HStack(spacing: 4) {
                                Text(entry.exerciseName)
                                    .font(.body.bold())
                                    .strikethrough(entry.isSkipped, color: .secondaryText)
                                    .foregroundColor(entry.isSkipped ? .secondaryText : .primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.tertiaryText)
                            }
                        }
                        .buttonStyle(.plain)
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

                                Text("\(set.weight.formattedLoad) x \(set.reps.formattedReps)")
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

                    if let note = entry.note, !note.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "text.quote")
                                .font(.caption2)
                                .foregroundColor(.tertiaryText)
                            Text(note)
                                .font(.caption)
                                .italic()
                                .foregroundColor(.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
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

            TextField(
                "Note on this lift…",
                text: Binding(
                    get: { entry.note ?? "" },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.note = trimmed.isEmpty ? nil : newValue
                    }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.caption)
            .textFieldStyle(.roundedBorder)

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

    // MARK: - Notes

    /// Stored in `WorkoutSession.concerns` — the field predates the rename,
    /// and chat already reads it as "what they said at the time".
    private var noteBinding: Binding<String> {
        Binding(
            get: { session.concerns ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                session.concerns = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    private var hasNote: Bool {
        !(session.concerns ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            if isEditing {
                TextField(
                    "How it went, what to change next time…",
                    text: noteBinding,
                    axis: .vertical
                )
                .lineLimit(2...8)
                .font(.body)
                .padding(12)
                .background(Color.cardSurface)
                .cornerRadius(8)
            } else if hasNote {
                // Tapping the note is the fast way into editing it — the
                // toolbar Edit does the same thing from further away.
                Button {
                    beginEditing()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(session.concerns ?? "")
                            .font(.body)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.tertiaryText)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardSurface)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    beginEditing()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                        Text("Add a note")
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentBlue)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardSurface)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func feelingRow(_ feeling: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "face.smiling")
                .font(.caption)
            Text("Felt \(feeling)/5 going in")
                .font(.caption)
        }
        .foregroundColor(.secondaryText)
        .padding(.horizontal, 4)
    }

    private func beginEditing() {
        guard !isEditing else { return }
        editSnapshot = sessionFingerprint()
        isEditing = true
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
        let entries = session.sortedEntries.map { entry in
            let sets = entry.sortedSets.map { "\($0.weight)-\($0.reps)-\($0.isWarmup)" }.joined(separator: "|")
            return "\(entry.exerciseName):\(sets):\(entry.note ?? "")"
        }.joined(separator: ";")
        return entries + "#" + (session.concerns ?? "")
    }

}
