import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var hasCompletedOnboarding: Bool

    @State private var step = 0
    @State private var apiKey = ""
    @State private var programVM = ProgramViewModel()

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

    // MARK: - Step 2: HealthKit + Goals

    private var goalStep: some View {
        VStack(spacing: 0) {
            if !healthRequested {
                healthKitCard
            }

            GoalSettingView(programVM: programVM, isOnboarding: true) {
                print("[BenLift] Program generated, advancing to completion step")
                step = 3
            }
        }
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

    // MARK: - Step 3: Done

    private var completeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.prGreen)

            Text("You're Ready")
                .font(.title.bold())

            if let program = programVM.currentProgram {
                Text("Program: \(program.name)")
                    .foregroundColor(.secondaryText)
            }

            Text("Start your first workout from the Today tab.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondaryText)

            Spacer()

            primaryButton("Let's Go") {
                hasCompletedOnboarding = true
            }

            // Skip button if no program generated
            if programVM.currentProgram == nil {
                Button("Skip — Set up later") {
                    hasCompletedOnboarding = true
                }
                .foregroundColor(.secondaryText)
                .padding(.bottom)
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
