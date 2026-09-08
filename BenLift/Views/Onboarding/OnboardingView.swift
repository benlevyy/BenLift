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

    @State private var isBootstrapping = false
    @State private var bootstrapError: String? = nil
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

            Section {
                Button {
                    Task { await runBootstrap() }
                } label: {
                    HStack {
                        if isBootstrapping {
                            ProgressView().padding(.trailing, 4)
                            Text("Designing your program...")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Design my program")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isBootstrapping)
            }

            if let bootstrapError {
                Section {
                    Text(bootstrapError)
                        .font(.caption)
                        .foregroundColor(.failedRed)
                    Button("Continue anyway") {
                        // User opt-out of retry — finish onboarding so they
                        // aren't stuck. They can re-run from Settings later.
                        hasCompletedOnboarding = true
                    }
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

    // MARK: - Bootstrap call
    //
    // 1. Build BootstrapInput from form state.
    // 2. Call ClaudeCoachService.bootstrap (Haiku — cheap, no thinking).
    // 3. Persist via BootstrapPersister (TrainingProgram + SeedPattern rows).
    // 4. Advance to the completion step.
    //
    // Error path: surface a localized message inline + reveal a "Continue
    // anyway" button so the user isn't trapped in onboarding. The flag is
    // still set when they tap that button — pattern engine + planner can
    // run un-bootstrapped, just with no seeds.

    @MainActor
    private func runBootstrap() async {
        isBootstrapping = true
        bootstrapError = nil

        let input = BootstrapInput(
            goal: goal.rawValue,
            daysPerWeek: daysPerWeek,
            experience: experience.rawValue,
            equipment: equipment.rawValue,
            focusAreas: focusAreas.map { $0.rawValue },
            injuriesOrAvoid: injuriesOrAvoid.trimmedOrNil,
            crossTraining: crossTraining.trimmedOrNil,
            preferences: preferences.trimmedOrNil
        )

        let coachService: CoachServiceProtocol = ClaudeCoachService()
        let model = ClaudeModel.current

        do {
            print("[BenLift/Onboarding] → bootstrap (goal=\(input.goal), days=\(input.daysPerWeek))")
            let response = try await coachService.bootstrap(input: input, model: model)
            print("[BenLift/Onboarding] ✓ bootstrap response: \(response.programName)")

            BootstrapPersister.persist(
                response: response,
                input: input,
                modelContext: modelContext
            )

            bootstrappedProgramName = response.programName
            isBootstrapping = false
            step = 3
        } catch {
            print("[BenLift/Onboarding] ❌ bootstrap failed: \(error)")
            bootstrapError = "Couldn't design your program right now. You can complete onboarding and we'll generate it later."
            isBootstrapping = false
        }
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
