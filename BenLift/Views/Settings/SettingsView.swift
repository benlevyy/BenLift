import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showKeyGuide = false
    @Environment(\.modelContext) private var modelContext

    // AppStorage directly in the view — works reliably with SwiftUI bindings
    @AppStorage("restTimerDuration") private var restTimerDuration: Double = 150
    @AppStorage("weightIncrement") private var weightIncrement: Double = 5.0
    @AppStorage("dumbbellIncrement") private var dumbbellIncrement: Double = 2.5
    @AppStorage("weightUnit") private var weightUnitRaw: String = WeightUnit.lbs.rawValue
    @AppStorage("workoutNotificationsEnabled") private var workoutNotificationsEnabled: Bool = true
    @AppStorage("dailyReminderEnabled") private var dailyReminderEnabled: Bool = false
    @AppStorage("dailyReminderHour") private var dailyReminderHour: Int = 18
    @AppStorage("dailyReminderMinute") private var dailyReminderMinute: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                structureSection
                if trainingSplitRaw == TrainingSplit.custom.rawValue {
                    CustomSplitDaysSection()
                }
                goalSection
                usageSection
                rulesSection
                apiConfigSection
                healthKitSection
                workoutPreferencesSection
                unitsSection
                notificationsSection
                librarySection
                dataSection
            }
            .scrollDismissesKeyboard(.interactively)
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
                showKeyGuide = true
            } label: {
                Label("How do I get a key?", systemImage: "questionmark.circle")
            }
            .sheet(isPresented: $showKeyGuide) {
                APIKeyGuideView()
                    .presentationDetents([.large])
            }

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

    /// The "Generate Warm-up Sets" toggle lived here until the resolver stopped
    /// emitting warm-up sets at all, leaving it wired to nothing. Warm-ups are
    /// now flagged by hand during the set, which is the only thing that ever
    /// actually happened anyway.
    private var workoutPreferencesSection: some View {
        Section {
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

        } header: {
            Text("Workout Preferences")
        } footer: {
            Text("Rest is scaled from here by what the exercise is: a primary compound rests longer than a finisher. Mark a warm-up with [W] beside Log Set — nothing generates them for you.")
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

        }
    }

    @State private var showClearAll = false

    @State private var showExportShare = false
    @State private var exportURL: URL?
    @State private var showImportPicker = false
    @State private var importMessage: String?
    @State private var showImportResult = false

    /// Exercise library browse / add / delete. Lives here now — was on
    /// the old Recovery tab as a bottom link. It's a browse/edit surface,
    /// not daily training info, so Settings is the right home.
    private var librarySection: some View {
        Section("Library") {
            NavigationLink {
                ExerciseListView()
            } label: {
                HStack {
                    Image(systemName: "dumbbell.fill")
                    Text("Exercise Library")
                }
            }
        }
    }

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
                Text("Deletes all workout sessions, plans, chat threads, rules, and your training program. Your exercise library and AI usage log are kept.")
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
        try? modelContext.delete(model: ExerciseEntry.self)
        try? modelContext.delete(model: SetLog.self)
        try? modelContext.delete(model: WorkoutSession.self)
        try? modelContext.delete(model: TrainingProgram.self)
        // These five were left behind by the original implementation —
        // "Clear All Data" looked complete but silently kept every
        // AI-learned rule, observation, and calendar pin around.
        try? modelContext.delete(model: UserRule.self)
        try? modelContext.delete(model: SessionEvent.self)
        try? modelContext.delete(model: MuscleGroupPin.self)
        try? modelContext.delete(model: PlannedActivity.self)
        try? modelContext.delete(model: ActivityLog.self)
        // The rebuild's own tables — a plan and thread for a day whose
        // sessions no longer exist would be stale nonsense.
        try? modelContext.delete(model: PlannedLift.self)
        try? modelContext.delete(model: DailyPlan.self)
        try? modelContext.delete(model: ChatMessage.self)
        try? modelContext.delete(model: ChatThread.self)
        try? modelContext.save()
        print("[BenLift] Cleared ALL data")
    }

    // MARK: - Goal

    /// One plain-text field, replacing nine structured ones. Read by chat on
    /// every turn; deliberately never read by the resolver.
    @Query private var programs: [TrainingProgram]

    private var activeProgram: TrainingProgram? {
        programs.first { $0.isActive }
    }

    @AppStorage(TrainingSplit.storageKey) private var trainingSplitRaw: String = TrainingSplit.pushPullLegs.rawValue

    private var structureSection: some View {
        Section {
            Picker("Split", selection: $trainingSplitRaw) {
                ForEach(TrainingSplit.allCases) { split in
                    Text(split.displayName).tag(split.rawValue)
                }
            }
        } header: {
            Text("Training structure")
        } footer: {
            Text("The rotation your days cycle through. Takes effect on the next plan — today's rebuilds automatically unless you've edited it in chat.")
        }
    }

    /// A vertical TextEditor has no submit action — Return inserts a newline,
    /// which is correct for prose and leaves no way to put the keyboard away.
    /// Hence the toolbar Done.
    @FocusState private var goalFocused: Bool

    private var goalSection: some View {
        Section {
            TextEditor(text: Binding(
                get: { activeProgram?.goalText ?? "" },
                set: { newValue in
                    if let program = activeProgram {
                        program.goalText = newValue
                    } else {
                        let program = TrainingProgram(name: "Training", goal: "")
                        program.goalText = newValue
                        modelContext.insert(program)
                    }
                    try? modelContext.save()
                }
            ))
            .frame(minHeight: 110)
            .font(.system(size: 14.5))
            .focused($goalFocused)
            .toolbar {
                if goalFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { goalFocused = false }
                            .font(.subheadline.bold())
                    }
                }
            }
        } header: {
            Text("Your goal")
        } footer: {
            Text("Plain text. The coach reads this on every message — lifting or not. Mention the other things you do and it can talk about those too.")
        }
    }

    // MARK: - AI usage

    @Query(sort: \AIUsageLog.timestamp, order: .reverse) private var usageLog: [AIUsageLog]

    private var usageSection: some View {
        Section {
            usageRow("Today", entries: usage(sinceDaysAgo: 0))
            usageRow("This week", entries: usage(sinceDaysAgo: 7))
            usageRow(monthName, entries: usage(sinceDaysAgo: 30))
            if !usageLog.isEmpty {
                levelBreakdown
            }
        } header: {
            Text("AI usage")
        } footer: {
            Text("One call per message you send. Nothing fires on open, on save, or on a timer.")
        }
    }

    private func usage(sinceDaysAgo days: Int) -> [AIUsageLog] {
        let cutoff = days == 0
            ? Calendar.current.startOfDay(for: Date())
            : Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return usageLog.filter { $0.timestamp >= cutoff }
    }

    private func usageRow(_ label: String, entries: [AIUsageLog]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(entries.count) message\(entries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(String(format: "$%.2f", entries.reduce(0) { $0 + $1.costUSD }))
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: Date())
    }

    private var levelBreakdown: some View {
        let month = usage(sinceDaysAgo: 30)
        let counts = Intelligence.allCases.map { level in
            (level, month.filter { $0.intelligence == level }.count)
        }
        let total = max(1, counts.reduce(0) { $0 + $1.1 })

        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(counts, id: \.0) { level, count in
                        if count > 0 {
                            Capsule()
                                .fill(color(for: level))
                                .frame(width: max(3, geo.size.width * CGFloat(count) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 16) {
                ForEach(counts, id: \.0) { level, count in
                    HStack(spacing: 5) {
                        Circle().fill(color(for: level)).frame(width: 7, height: 7)
                        Text("\(level.displayName) \(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for level: Intelligence) -> Color {
        switch level {
        case .quick: return .accent
        case .balanced: return .intentSecondary
        case .deep: return .intentIsolation
        }
    }

    // MARK: - Rules

    @Query private var allRules: [UserRule]

    private var activeRules: [UserRule] {
        allRules.filter { $0.isActive }.sorted { $0.createdAt > $1.createdAt }
    }

    @ViewBuilder
    private var rulesSection: some View {
        if !activeRules.isEmpty {
            Section {
                ForEach(activeRules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.subject)
                            if let reason = rule.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(rule.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            rule.isActive = false
                            try? modelContext.save()
                        }
                    }
                }
            } header: {
                Text("Rules the coach follows")
            } footer: {
                Text("Enforced in the app before the coach is involved — an excluded lift simply never appears.")
            }
        }
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

