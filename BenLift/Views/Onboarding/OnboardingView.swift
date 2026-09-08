import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var hasCompletedOnboarding: Bool

    @State private var step = 0
    @State private var apiKey = ""

    // MARK: - Bootstrap form state
    //
    // Mirrors `BootstrapInput` 1:1. Defaults match the prior onboarding
    // (hypertrophy, 5 days, intermediate, full gym) so the user can blow
    // through with a single tap if they want.
    @State private var goal: BootstrapGoal = .hypertrophy
    @State private var daysPerWeek: Int = 5
    @State private var experience: BootstrapExperience = .oneToThreeYears
    @State private var equipment: BootstrapEquipment = .fullGym
    @State private var focusAreas: Set<MuscleGroup> = []
    @State private var injuriesOrAvoid: String = ""
    @State private var crossTraining: String = ""
    @State private var preferences: String = ""

    // MARK: - Bootstrap call state

    @State private var bootstrappedProgramName: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress indicator
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle()
                            .fill(i <= step ? Color.accentBlue : Color.cardSurface)
                            .frame(height: 3)
                            .cornerRadius(1.5)
                    }
                }
                .padding()

                // Content — simple switch, no TabView
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: apiKeyStep
                    case 2: goalStep
                    default: completeStep
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: step)
            }
            .background(Color.appBackground)
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 72))
                .foregroundColor(.accentBlue)

            Text("BenLift")
                .font(.largeTitle.bold())

            Text("AI-driven strength training.\nThe right muscles, the right day.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondaryText)

            Spacer()

            primaryButton("Get Started") { step = 1 }
        }
        .padding()
    }

    // MARK: - Step 1: API Key

    private var apiKeyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentBlue)

            Text("Claude API Key")
                .font(.title2.bold())

            Text("Your API key is stored securely in Keychain and used to generate workout plans and analysis.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondaryText)
                .padding(.horizontal)

            SecureField("sk-ant-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Spacer()

            VStack(spacing: 12) {
                primaryButton(apiKey.isEmpty ? "Skip for Now" : "Save & Continue") {
                    if !apiKey.isEmpty {
                        do {
                            try KeychainService.save(key: KeychainService.apiKeyKey, value: apiKey)
                            print("[BenLift] API key saved to Keychain (\(apiKey.prefix(10))...)")
                        } catch {
                            print("[BenLift] Failed to save API key: \(error)")
                        }
                    } else {
                        print("[BenLift] Skipping API key setup")
                    }
                    step = 2
                }

                if apiKey.isEmpty {
                    Text("You can add it later in Settings. AI features won't work without it.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .padding()
    }

    // MARK: - Step 2: HealthKit + Bootstrap form
    //
    // Single Form that collects every `BootstrapInput` field. On "Design my
    // program" we call `CoachServiceProtocol.bootstrap(...)` and persist via
    // `BootstrapPersister`. On error we still let the user proceed — the
    // pattern engine + planner can run without bootstrap (just less seeded).

    private var goalStep: some View {
        Form {
            if !healthRequested {
                Section {
                    healthKitCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Primary Goal") {
                Picker("Goal", selection: $goal) {
                    ForEach(BootstrapGoal.allCases) { g in
                        Text(g.displayName).tag(g)
                    }
                }
                .pickerStyle(.menu)
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
                Picker("Lifting experience", selection: $experience) {
                    ForEach(BootstrapExperience.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Equipment") {
                Picker("What do you have access to?", selection: $equipment) {
                    ForEach(BootstrapEquipment.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Focus areas (optional)") {
                FocusAreaTagSelector(selected: $focusAreas)
                Text("Tap muscles you want to prioritize. Leave empty for balanced.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            Section("Injuries or things to avoid (optional)") {
                TextField("e.g. left shoulder impingement, no overhead press",
                          text: $injuriesOrAvoid, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Cross-training (optional)") {
                TextField("e.g. bouldering Wed/Sun, running 5k once a week",
                          text: $crossTraining, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Preferences (optional)") {
                TextField("e.g. love DB work, hate barbell squats",
                          text: $preferences, axis: .vertical)
                    .lineLimit(2...4)
            }

            // No spinner and no error path: this writes a row and moves on.
            // There is nothing to fail, because there is no longer a network
            // call standing between the user and their first plan.
            Section {
                Button {
                    finishOnboarding()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Save and continue")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Set up your program")
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var healthRequested = false

    private var healthKitCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundColor(.failedRed)
                Text("Connect Apple Health")
                    .font(.headline)
                Spacer()
            }
            Text("Sleep, heart rate, and HRV data help the AI adjust your training based on recovery.")
                .font(.caption)
                .foregroundColor(.secondaryText)

            Button {
                Task {
                    await HealthKitService.shared.requestAuthorization()
                    healthRequested = true
                }
            } label: {
                Text("Allow HealthKit Access")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.accentBlue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Finish onboarding
    //
    // This used to call Claude to design a starter program (split,
    // periodisation, per-muscle volume targets) and persist it via
    // BootstrapPersister. None of that is read any more: the plan comes from
    // rotating push/pull/legs and replaying the last session of that type,
    // and a cold start uses the default exercise library. So onboarding does
    // the one thing that still matters — write down what he's training for,
    // in his own words — and does it locally, instantly, with no API key
    // required to get through the door.

    @MainActor
    private func finishOnboarding() {
        let program = TrainingProgram(
            name: "Training",
            goal: goal.rawValue,
            experienceLevel: experience.rawValue,
            daysPerWeek: daysPerWeek
        )
        program.goalText = composedGoalText
        modelContext.insert(program)

        // Things to avoid become real rules, enforced by the resolver in
        // Swift rather than requested of a model.
        if let avoid = injuriesOrAvoid.trimmedOrNil {
            modelContext.insert(UserRule(
                kind: .programming,
                subject: avoid,
                reason: "From onboarding"
            ))
        }

        try? modelContext.save()
        bootstrappedProgramName = "Ready"
        step = 3
    }

    /// Fold the form into the single plain-text goal the coach reads. Prose,
    /// because that's the field's whole point — it stays editable in Settings
    /// and can say things no set of pickers could.
    private var composedGoalText: String {
        var parts: [String] = []
        parts.append("Training for \(goal.rawValue), \(daysPerWeek) days a week. I'm \(experience.rawValue).")
        if !focusAreas.isEmpty {
            parts.append("Prioritising \(focusAreas.map { $0.rawValue }.joined(separator: ", ")).")
        }
        parts.append("Equipment: \(equipment.rawValue).")
        if let cross = crossTraining.trimmedOrNil {
            parts.append("Other training: \(cross).")
        }
        if let avoid = injuriesOrAvoid.trimmedOrNil {
            parts.append("Avoid: \(avoid).")
        }
        if let prefs = preferences.trimmedOrNil {
            parts.append(prefs)
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Step 3: Done

    private var completeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.prGreen)

            Text("You're Ready")
                .font(.title.bold())

            if let bootstrappedProgramName {
                Text("Program: \(bootstrappedProgramName)")
                    .foregroundColor(.secondaryText)
            }

            Text("Start your first workout from the Today tab.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondaryText)

            Spacer()

            primaryButton("Let's Go") {
                hasCompletedOnboarding = true
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentBlue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
        .padding(.horizontal)
    }
}

// MARK: - Bootstrap-specific enums
//
// These mirror the literal strings the bootstrap prompt expects (per
// `BootstrapInput` doc comments). They're scoped to onboarding because the
// rest of the app uses `TrainingGoal` / `ExperienceLevel` / `EquipmentAccess`
// for legacy reasons — we don't want to graft new cases onto those enums or
// remap their rawValues.

private enum BootstrapGoal: String, CaseIterable, Identifiable {
    case hypertrophy
    case strength
    case generalFitness = "general_fitness"
    case sportSpecific = "sport_specific"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .hypertrophy: return "Hypertrophy"
        case .strength: return "Strength"
        case .generalFitness: return "General fitness"
        case .sportSpecific: return "Sport-specific"
        }
    }
}

private enum BootstrapExperience: String, CaseIterable, Identifiable {
    case never
    case lessThanOneYear = "<1yr"
    case oneToThreeYears = "1-3yr"
    case threePlusYears = "3+yr"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .never: return "Never lifted"
        case .lessThanOneYear: return "Less than 1 year"
        case .oneToThreeYears: return "1–3 years"
        case .threePlusYears: return "3+ years"
        }
    }
}

private enum BootstrapEquipment: String, CaseIterable, Identifiable {
    case fullGym = "full_gym"
    case homeDumbbells = "home_dumbbells"
    case bodyweight

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fullGym: return "Full gym"
        case .homeDumbbells: return "Home dumbbells"
        case .bodyweight: return "Bodyweight only"
        }
    }
}

// MARK: - Focus area tag selector

private struct FocusAreaTagSelector: View {
    @Binding var selected: Set<MuscleGroup>

    private let columns = [
        GridItem(.adaptive(minimum: 90), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(MuscleGroup.allCases) { mg in
                let isOn = selected.contains(mg)
                Button {
                    if isOn { selected.remove(mg) } else { selected.insert(mg) }
                } label: {
                    Text(mg.displayName)
                        .font(.caption.bold())
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? Color.accentBlue : Color.cardSurface)
                        .foregroundColor(isOn ? .white : .primary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - String helper

private extension String {
    /// Trim whitespace; nil out empty strings so we can pass clean optionals
    /// into BootstrapInput rather than empty strings the LLM would treat as
    /// "user said nothing applies here."
    var trimmedOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
