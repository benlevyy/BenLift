import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(\.modelContext) private var modelContext

    // AppStorage directly in the view — works reliably with SwiftUI bindings
    @AppStorage("restTimerDuration") private var restTimerDuration: Double = 150
    @AppStorage("weightIncrement") private var weightIncrement: Double = 5.0
    @AppStorage("dumbbellIncrement") private var dumbbellIncrement: Double = 2.5
    @AppStorage("warmUpGeneration") private var warmUpGeneration: Bool = true
    @AppStorage("weeklyReviewDay") private var weeklyReviewDay: Int = 1
    @AppStorage("weeklyReviewEnabled") private var weeklyReviewEnabled: Bool = true
    @AppStorage("weightUnit") private var weightUnitRaw: String = WeightUnit.lbs.rawValue
    @AppStorage("workoutNotificationsEnabled") private var workoutNotificationsEnabled: Bool = true
    @AppStorage("dailyReminderEnabled") private var dailyReminderEnabled: Bool = false
    @AppStorage("dailyReminderHour") private var dailyReminderHour: Int = 18
    @AppStorage("dailyReminderMinute") private var dailyReminderMinute: Int = 0

    private let modelOptions = [
        "claude-haiku-4-5",
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
                Text(TimeInterval(restTimerDuration).formattedMinSec)
                    .foregroundColor(.secondary)
                Stepper("", value: $restTimerDuration, in: 30...300, step: 15)
                    .labelsHidden()
            }

            HStack {
                Text("Barbell Increment")
                Spacer()
                Text("\(weightIncrement, specifier: "%.1f") lbs")
                    .foregroundColor(.secondary)
                Stepper("", value: $weightIncrement, in: 2.5...10, step: 2.5)
                    .labelsHidden()
            }

            HStack {
                Text("Dumbbell Increment")
                Spacer()
                Text("\(dumbbellIncrement, specifier: "%.1f") lbs")
                    .foregroundColor(.secondary)
                Stepper("", value: $dumbbellIncrement, in: 2.5...10, step: 2.5)
                    .labelsHidden()
            }

            Toggle("Generate Warm-up Sets", isOn: $warmUpGeneration)
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Weight Unit", selection: $weightUnitRaw) {
                Text("lbs").tag(WeightUnit.lbs.rawValue)
                Text("kg").tag(WeightUnit.kg.rawValue)
            }
            .pickerStyle(.segmented)
        }
    }

    private var dailyReminderTime: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = dailyReminderHour
                comps.minute = dailyReminderMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                dailyReminderHour = comps.hour ?? 18
                dailyReminderMinute = comps.minute ?? 0
                NotificationService.shared.rescheduleDailyFromSettings()
            }
        )
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Workout Alerts", isOn: $workoutNotificationsEnabled)
                .onChange(of: workoutNotificationsEnabled) { _, enabled in
                    if enabled {
                        Task { await NotificationService.shared.requestAuthorization() }
                    } else {
                        NotificationService.shared.cancelAbandonReminder()
                    }
                }

            Toggle("Daily Reminder", isOn: $dailyReminderEnabled)
                .onChange(of: dailyReminderEnabled) { _, enabled in
                    if enabled {
                        Task {
                            await NotificationService.shared.requestAuthorization()
                            NotificationService.shared.rescheduleDailyFromSettings()
                        }
                    } else {
                        NotificationService.shared.cancelDailyReminder()
                    }
                }

            if dailyReminderEnabled {
                DatePicker(
                    "Reminder Time",
                    selection: dailyReminderTime,
                    displayedComponents: .hourAndMinute
                )
            }

            Toggle("Weekly Review", isOn: $weeklyReviewEnabled)

            if weeklyReviewEnabled {
                Picker("Review Day", selection: $weeklyReviewDay) {
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

    @State private var showExportShare = false
    @State private var exportURL: URL?
    @State private var showImportPicker = false
    @State private var importMessage: String?
    @State private var showImportResult = false

    private var dataSection: some View {
        Section("Data") {
            Button {
                exportData()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export All Data")
                }
            }

            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Data")
                }
            }

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
        .sheet(isPresented: $showExportShare) {
            if let url = exportURL {
                ShareSheet(url: url)
            }
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importData(from: url)
            case .failure(let error):
                importMessage = "Failed to open file: \(error.localizedDescription)"
                showImportResult = true
            }
        }
        .alert("Import", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func exportData() {
        do {
            let data = try DataExportService.exportData(modelContext: modelContext)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "BenLift-backup-\(formatter.string(from: Date())).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url)
            exportURL = url
            showExportShare = true
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
            showImportResult = true
        }
    }

    private func importData(from url: URL) {
        do {
            guard url.startAccessingSecurityScopedResource() else {
                importMessage = "Cannot access file"
                showImportResult = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            try DataExportService.importData(data, modelContext: modelContext)
            importMessage = "Import successful"
            showImportResult = true
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
            showImportResult = true
        }
    }

    private func clearAllData() {
        try? modelContext.delete(model: PostWorkoutAnalysis.self)
        try? modelContext.delete(model: WeeklyReview.self)
        try? modelContext.delete(model: ExerciseEntry.self)
        try? modelContext.delete(model: SetLog.self)
        try? modelContext.delete(model: WorkoutSession.self)
        try? modelContext.delete(model: TrainingProgram.self)
        try? modelContext.save()
        print("[BenLift] Cleared ALL data")
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

