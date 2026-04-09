import SwiftUI
import SwiftData

struct IntelligenceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var intelligenceVM: IntelligenceViewModel
    var program: TrainingProgram?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    refreshSection
                    userInputSection
                    if let intel = intelligenceVM.intelligence, intel.hasBeenRefreshed {
                        intelligenceSections(intel)
                    } else {
                        emptyState
                    }
                    if let intel = intelligenceVM.intelligence, !intel.pendingObservations.isEmpty {
                        pendingSection(intel)
                    }
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Intelligence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Refresh

    private var refreshSection: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await intelligenceVM.refreshIntelligence(
                        modelContext: modelContext,
                        program: program
                    )
                }
            } label: {
                HStack {
                    if intelligenceVM.isRefreshing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(intelligenceVM.isRefreshing ? "Analyzing..." : "Refresh Intelligence")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentBlue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(intelligenceVM.isRefreshing)

            if let intel = intelligenceVM.intelligence, intel.hasBeenRefreshed {
                HStack {
                    Text("Last refreshed \(intel.lastRefreshed.shortFormatted)")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                    if intel.isStale {
                        Text("Refresh recommended")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
            }

            if let error = intelligenceVM.refreshError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.failedRed)
            }
        }
    }

    // MARK: - User Input (injuries + notes)

    private var userInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("YOUR INPUT", subtitle: "Only you can provide this")

            VStack(alignment: .leading, spacing: 4) {
                Text("Injuries / Concerns")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                TextField("e.g. Left shoulder impingement", text: injuriesBinding)
                    .textInputAutocapitalization(.sentences)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes for Coach")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                TextField("Anything else the AI should know", text: userNotesBinding)
                    .textInputAutocapitalization(.sentences)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Intelligence Sections

    private func intelligenceSections(_ intel: UserIntelligence) -> some View {
        VStack(spacing: 12) {
            sectionHeader("AI INTELLIGENCE", subtitle: "Auto-generated from your data")

            if !intel.activityPatterns.isEmpty && intel.activityPatterns != "Insufficient data" {
                intelligenceCard("Activity Patterns", icon: "figure.run", text: intel.activityPatterns)
            }
            if !intel.trainingPatterns.isEmpty && intel.trainingPatterns != "Insufficient data" {
                intelligenceCard("Training Patterns", icon: "dumbbell", text: intel.trainingPatterns)
            }
            if !intel.strengthProfile.isEmpty && intel.strengthProfile != "Insufficient data" {
                intelligenceCard("Strength Profile", icon: "chart.line.uptrend.xyaxis", text: intel.strengthProfile)
            }
            if !intel.recoveryProfile.isEmpty && intel.recoveryProfile != "Insufficient data" {
                intelligenceCard("Recovery Profile", icon: "bed.double", text: intel.recoveryProfile)
            }
            if !intel.exercisePreferences.isEmpty && intel.exercisePreferences != "Insufficient data" {
                intelligenceCard("Exercise Preferences", icon: "star", text: intel.exercisePreferences)
            }
            if !intel.notableObservations.isEmpty && intel.notableObservations != "Insufficient data" {
                intelligenceCard("Notable Observations", icon: "lightbulb", text: intel.notableObservations)
            }
        }
    }

    private func intelligenceCard(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.accentBlue)
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.primary)
            }
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.title)
                .foregroundColor(.secondaryText)
            Text("No intelligence yet")
                .font(.headline)
                .foregroundColor(.primary)
            Text("Tap Refresh to analyze your training data, HealthKit activities, and health metrics.")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Pending Observations

    private func pendingSection(_ intel: UserIntelligence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let count = intel.pendingObservations.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            HStack {
                sectionHeader("PENDING OBSERVATIONS", subtitle: "\(count) items waiting for next refresh")
                Button {
                    intel.pendingObservations = ""
                    try? modelContext.save()
                } label: {
                    Text("Clear")
                        .font(.caption)
                        .foregroundColor(.failedRed)
                }
            }

            Text(intel.pendingObservations)
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
            Spacer()
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondaryText)
        }
    }

    private var injuriesBinding: Binding<String> {
        Binding(
            get: { intelligenceVM.intelligence?.injuries ?? "" },
            set: {
                let intel = intelligenceVM.ensureIntelligenceExists(modelContext: modelContext)
                intel.injuries = $0
            }
        )
    }

    private var userNotesBinding: Binding<String> {
        Binding(
            get: { intelligenceVM.intelligence?.userNotes ?? "" },
            set: {
                let intel = intelligenceVM.ensureIntelligenceExists(modelContext: modelContext)
                intel.userNotes = $0
            }
        )
    }
}
