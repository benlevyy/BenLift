import SwiftUI
import SwiftData

struct CoachingProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var program: TrainingProgram

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This info is sent to the AI with every workout. It helps Claude plan around your full life, not just your gym sessions.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }

                Section("Other Activities") {
                    TextField("e.g. Bouldering, running, sports", text: binding(for: \.otherActivities))
                        .textInputAutocapitalization(.sentences)

                    TextField("Schedule: e.g. Boulder Wed evening, Sun morning", text: binding(for: \.activitySchedule))
                        .textInputAutocapitalization(.sentences)
                }

                Section("Training Priorities") {
                    TextField("e.g. Focus chest/shoulders, maintain legs", text: binding(for: \.musclePriorities))
                        .textInputAutocapitalization(.sentences)

                    TextField("e.g. Bench 225, look better shirtless", text: Binding(
                        get: { program.specificTargets ?? "" },
                        set: { program.specificTargets = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.sentences)
                }

                Section("Health & Recovery") {
                    TextField("Ongoing injuries or limitations", text: binding(for: \.ongoingConcerns))
                        .textInputAutocapitalization(.sentences)

                    TextField("Recovery notes: e.g. Sleep usually 6-7hrs", text: binding(for: \.recoveryNotes))
                        .textInputAutocapitalization(.sentences)
                }

                Section("Coaching Style") {
                    TextField("e.g. Push me hard, be conservative on shoulders", text: binding(for: \.coachingStyle))
                        .textInputAutocapitalization(.sentences)

                    TextField("Anything else the AI should know", text: binding(for: \.customCoachNotes))
                        .textInputAutocapitalization(.sentences)
                }

                Section("Program") {
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text(program.goal)
                            .foregroundColor(.secondaryText)
                    }
                    HStack {
                        Text("Days/week")
                        Spacer()
                        Text("\(program.daysPerWeek)")
                            .foregroundColor(.secondaryText)
                    }
                    HStack {
                        Text("Experience")
                        Spacer()
                        Text(program.experienceLevel.capitalized)
                            .foregroundColor(.secondaryText)
                    }
                    HStack {
                        Text("Periodization")
                        Spacer()
                        Text(program.periodization.capitalized)
                            .foregroundColor(.secondaryText)
                    }
                }
            }
            .navigationTitle("Coaching Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        print("[BenLift] Coaching profile saved")
                        dismiss()
                    }
                }
            }
        }
    }

    /// Helper to bind optional String fields
    private func binding(for keyPath: ReferenceWritableKeyPath<TrainingProgram, String?>) -> Binding<String> {
        Binding(
            get: { program[keyPath: keyPath] ?? "" },
            set: { program[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
