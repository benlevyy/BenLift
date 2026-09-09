import SwiftUI

/// Editor for the days of a custom split — shown in Settings when the
/// structure picker is on Custom.
///
/// A day is a name and the muscle groups it trains; that's the whole
/// contract the resolver needs. Core is added automatically (it belongs to
/// every day and counting it taught us three separate bugs), so the editor
/// doesn't offer it.
struct CustomSplitDaysSection: View {
    @State private var days: [CustomSplitDay] = CustomSplitDay.load()
    @State private var editing: CustomSplitDay?

    var body: some View {
        Section {
            ForEach(days) { day in
                Button {
                    editing = day
                } label: {
                    HStack {
                        Text(day.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(day.muscleGroups.map(\.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)
            }
            .onDelete { offsets in
                days.remove(atOffsets: offsets)
                CustomSplitDay.save(days)
            }
            .onMove { source, destination in
                days.move(fromOffsets: source, toOffset: destination)
                CustomSplitDay.save(days)
            }

            Button {
                let new = CustomSplitDay(name: "Day \(days.count + 1)", muscleGroupsRaw: [])
                days.append(new)
                CustomSplitDay.save(days)
                editing = new
            } label: {
                Label("Add day", systemImage: "plus")
            }
        } header: {
            Text("Custom days")
        } footer: {
            Text(days.isEmpty
                 ? "No days yet — until you add one, the rotation falls back to push/pull/legs."
                 : "The rotation cycles these in order. Drag to reorder, swipe to delete.")
        }
        .sheet(item: $editing) { day in
            CustomSplitDayEditor(day: day) { updated in
                if let index = days.firstIndex(where: { $0.id == updated.id }) {
                    days[index] = updated
                    CustomSplitDay.save(days)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Name + muscle-group toggles for one day. Saves on dismiss; a day with no
/// groups is kept in the list (so work isn't lost) but the resolver filters
/// it out until it has at least one.
struct CustomSplitDayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: Set<MuscleGroup>
    private let dayID: UUID
    private let onSave: (CustomSplitDay) -> Void

    init(day: CustomSplitDay, onSave: @escaping (CustomSplitDay) -> Void) {
        self.dayID = day.id
        self.onSave = onSave
        _name = State(initialValue: day.name)
        _selected = State(initialValue: Set(day.muscleGroups))
    }

    /// Everything except core — every day gets core implicitly.
    private let choices = MuscleGroup.allCases.filter { $0 != .core }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Day name", text: $name)
                }
                Section {
                    ForEach(choices) { group in
                        Button {
                            if selected.contains(group) {
                                selected.remove(group)
                            } else {
                                selected.insert(group)
                            }
                        } label: {
                            HStack {
                                Text(group.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(group) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accent)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("Trains")
                } footer: {
                    Text("Core is included on every day automatically.")
                }
            }
            .navigationTitle("Edit day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(CustomSplitDay(
                            id: dayID,
                            name: name.trimmingCharacters(in: .whitespaces),
                            muscleGroupsRaw: choices.filter(selected.contains).map(\.rawValue)
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
