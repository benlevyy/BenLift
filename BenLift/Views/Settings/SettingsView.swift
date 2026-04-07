import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(\.modelContext) private var modelContext

    private let modelOptions = [
        "claude-haiku-4-5-20251001",
        "claude-3-haiku-20240307",
    ]

    var body: some View {
        NavigationStack {
            Form {
                apiConfigSection
                healthKitSection
                workoutPreferencesSection
                unitsSection
                notificationsSection
                dataSection
            }
            .navigationTitle("Settings")
            .onAppear { viewModel.loadAPIKey() }
        }
    }

    // MARK: - Sections

    private var apiConfigSection: some View {
        Section("API Configuration") {
            SecureField("Claude API Key", text: $viewModel.apiKey)
                .textContentType(.password)
                .onSubmit { viewModel.saveAPIKey() }

            Button {
                viewModel.saveAPIKey()
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if viewModel.isTestingConnection {
                        ProgressView()
                    } else if let result = viewModel.connectionTestResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result ? .prGreen : .failedRed)
                    }
                }
            }

            Picker("Daily Plan Model", selection: $viewModel.modelDailyPlan) {
                ForEach(modelOptions, id: \.self) { Text($0) }
            }

            Picker("Analysis Model", selection: $viewModel.modelPostAnalysis) {
                ForEach(modelOptions, id: \.self) { Text($0) }
            }

            Picker("Weekly Review Model", selection: $viewModel.modelWeeklyReview) {
                ForEach(modelOptions, id: \.self) { Text($0) }
            }
        }
    }

    private var healthKitSection: some View {
        Section("Apple Health") {
            HStack {
                Text("HealthKit")
                Spacer()
                if HealthKitService.isAvailable {
                    Text(HealthKitService.shared.isAuthorized ? "Connected" : "Not Connected")
                        .foregroundColor(HealthKitService.shared.isAuthorized ? .prGreen : .secondaryText)
                } else {
                    Text("Not Available")
                        .foregroundColor(.secondaryText)
                }
            }

            if HealthKitService.isAvailable {
                Button("Request HealthKit Access") {
                    Task { await HealthKitService.shared.requestAuthorization() }
                }

                Button("Test Health Data") {
                    Task {
                        let ctx = await HealthKitService.shared.fetchHealthContext()
                        print("[BenLift/HK] Test: \(ctx)")
                    }
                }
            }

            Text("Sleep, heart rate, and HRV are sent to the AI to adjust workout intensity based on your recovery.")
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
    }

    private var workoutPreferencesSection: some View {
        Section("Workout Preferences") {
            HStack {
                Text("Rest Timer")
                Spacer()
                Text(TimeInterval(viewModel.restTimerDuration).formattedMinSec)
                    .foregroundColor(.secondary)
                Stepper("", value: $viewModel.restTimerDuration, in: 30...300, step: 15)
                    .labelsHidden()
            }

            HStack {
                Text("Barbell Increment")
                Spacer()
                Text("\(viewModel.weightIncrement, specifier: "%.1f") lbs")
                    .foregroundColor(.secondary)
                Stepper("", value: $viewModel.weightIncrement, in: 2.5...10, step: 2.5)
                    .labelsHidden()
            }

            Toggle("Generate Warm-up Sets", isOn: $viewModel.warmUpGeneration)
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Weight Unit", selection: Binding(
                get: { viewModel.weightUnit },
                set: { viewModel.weightUnit = $0 }
            )) {
                Text("lbs").tag(WeightUnit.lbs)
                Text("kg").tag(WeightUnit.kg)
            }
            .pickerStyle(.segmented)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Weekly Review", isOn: $viewModel.weeklyReviewEnabled)

            if viewModel.weeklyReviewEnabled {
                Picker("Review Day", selection: $viewModel.weeklyReviewDay) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                    Text("Tuesday").tag(3)
                    Text("Wednesday").tag(4)
                    Text("Thursday").tag(5)
                    Text("Friday").tag(6)
                    Text("Saturday").tag(7)
                }
            }
        }
    }

    @State private var showClearAll = false

    private var dataSection: some View {
        Section("Data") {
            Button("Reseed Exercise Library") {
                DefaultExercises.reseed(in: modelContext)
            }

            Button("Clear Workout History", role: .destructive) {
                showClearAll = true
            }
            .alert("Clear Everything?", isPresented: $showClearAll) {
                Button("Delete All", role: .destructive) { clearAllData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all workout sessions, analyses, weekly reviews, and your training program. Exercise library is kept.")
            }
        }
    }

    private func clearAllData() {
        // Delete in dependency order: analyses first, then sessions (cascade deletes entries/sets)
        try? modelContext.delete(model: PostWorkoutAnalysis.self)
        try? modelContext.delete(model: WeeklyReview.self)
        try? modelContext.delete(model: ExerciseEntry.self)
        try? modelContext.delete(model: SetLog.self)
        try? modelContext.delete(model: WorkoutSession.self)
        try? modelContext.delete(model: TrainingProgram.self)
        try? modelContext.save()
        print("[BenLift] Cleared ALL data (sessions, analyses, reviews, program)")
    }
}
