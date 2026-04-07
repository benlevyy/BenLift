import SwiftUI
import SwiftData

struct GoalSettingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var programVM: ProgramViewModel
    let isOnboarding: Bool
    var onComplete: (() -> Void)? = nil

    @State private var goal: TrainingGoal = .hypertrophy
    @State private var specificTargets: String = ""
    @State private var daysPerWeek: Int = 5
    @State private var experience: ExperienceLevel = .intermediate
    @State private var injuries: String = ""
    @State private var equipment: EquipmentAccess = .fullGym

    var body: some View {
        Form {
            Section("Primary Goal") {
                Picker("Goal", selection: $goal) {
                    ForEach(TrainingGoal.allCases) { g in
                        Text(g.displayName).tag(g)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Specific targets (optional)", text: $specificTargets)
                    .textInputAutocapitalization(.never)
            }

            Section("Schedule") {
                Picker("Days per week", selection: $daysPerWeek) {
                    ForEach([3, 4, 5, 6], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Experience") {
                Picker("Level", selection: $experience) {
                    ForEach(ExperienceLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Equipment") {
                Picker("Access", selection: $equipment) {
                    ForEach(EquipmentAccess.allCases) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Limitations") {
                TextField("Injuries or limitations (optional)", text: $injuries)
            }

            Section {
                Button {
                    Task {
                        await programVM.generateProgram(
                            goal: goal,
                            specificTargets: specificTargets.isEmpty ? nil : specificTargets,
                            daysPerWeek: daysPerWeek,
                            experience: experience,
                            injuries: injuries.isEmpty ? nil : injuries,
                            equipment: equipment,
                            modelContext: modelContext
                        )
                    }
                } label: {
                    HStack {
                        if programVM.isGenerating {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Designing your program...")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Generate Program")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(programVM.isGenerating)
            }

            if let error = programVM.error {
                Section("Error") {
                    Text(error)
                        .foregroundColor(.failedRed)
                        .font(.caption)
                }
            }

            if let program = programVM.currentProgram {
                Section("Generated Program") {
                    Text(program.name)
                        .font(.headline)
                    Text("\(program.daysPerWeek) days/week • \(program.periodization.capitalized)")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)

                    if isOnboarding {
                        Button("Continue") {
                            onComplete?()
                        }
                        .font(.headline)
                        .foregroundColor(.accentBlue)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }

            if isOnboarding && programVM.currentProgram == nil {
                Section {
                    Button("Skip for Now") {
                        onComplete?()
                    }
                    .foregroundColor(.secondaryText)
                }
            }
        }
        .navigationTitle("Set Goals")
    }
}
