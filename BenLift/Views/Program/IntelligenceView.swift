import SwiftUI
import SwiftData

struct IntelligenceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var intelligenceVM: IntelligenceViewModel
    var program: TrainingProgram?

    // Active durable decisions the AI must obey — user-initiated, shown
    // as a deletable list so the user can restore a previously removed
    // exercise without digging through plan UI.
    @Query(
        filter: #Predicate<UserRule> { $0.isActive == true },
        sort: \UserRule.lastReinforcedAt,
        order: .reverse
    ) private var activeRules: [UserRule]

    // AI-discovered patterns. Top-by-recency in the card; the supersede
    // logic in ObservationStore keeps this list deduped across refreshes.
    @Query(
        filter: #Predicate<UserObservation> { $0.isActive == true },
        sort: \UserObservation.lastReinforcedAt,
        order: .reverse
    ) private var activeObservations: [UserObservation]

    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    refreshSection
                    userInputSection
                    rulesSection
                    observationsSection
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Reset Intelligence", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Reset Intelligence?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    intelligenceVM.resetIntelligence(modelContext: modelContext)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Wipes the AI-generated observations. Your rules, injuries, and notes are kept. The next Refresh will rebuild observations from your remaining sessions.")
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
                        ProgressView().tint(.white)
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

    // MARK: - User Input

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

    // MARK: - Rules (durable user decisions)

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "YOUR RULES",
                subtitle: activeRules.isEmpty ? "None yet" : "\(activeRules.count) active"
            )

            if activeRules.isEmpty {
                Text("When you remove an exercise from a plan, it lands here. The AI will stop suggesting it until you add it back.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            } else {
                VStack(spacing: 8) {
                    ForEach(activeRules) { rule in
                        ruleRow(rule)
                    }
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func ruleRow(_ rule: UserRule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: rule.kind))
                .font(.caption)
                .foregroundColor(.accentBlue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.subject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    Text(label(for: rule.kind))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondaryText)
                    if let reason = rule.reason, !reason.isEmpty {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(.secondaryText)
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 6)

            Button {
                UserRuleStore.archiveRule(rule.id, modelContext: modelContext)
            } label: {
                Text("Archive")
                    .font(.caption.bold())
                    .foregroundColor(.failedRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.failedRed.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(UIColor.systemGroupedBackground))
        .cornerRadius(8)
    }

    private func icon(for kind: UserRuleKind) -> String {
        switch kind {
        case .exerciseOut: return "nosign"
        case .preferOver:  return "arrow.left.arrow.right"
        case .equipment:   return "wrench.and.screwdriver"
        case .programming: return "list.bullet.rectangle"
        case .unknown:     return "questionmark.circle"
        }
    }

    private func label(for kind: UserRuleKind) -> String {
        switch kind {
        case .exerciseOut: return "EXERCISE OUT"
        case .preferOver:  return "PREFERENCE"
        case .equipment:   return "EQUIPMENT"
        case .programming: return "PROGRAMMING"
        case .unknown:     return "RULE"
        }
    }

    // MARK: - Observations (AI-discovered)

    private var observationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "AI OBSERVATIONS",
                subtitle: activeObservations.isEmpty ? "Nothing yet" : "\(activeObservations.count) active"
            )

            if activeObservations.isEmpty {
                emptyObservationsBody
            } else {
                VStack(spacing: 8) {
                    ForEach(activeObservations) { obs in
                        observationRow(obs)
                    }
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private var emptyObservationsBody: some View {
        VStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.title3)
                .foregroundColor(.secondaryText)
            Text("Tap Refresh to analyze your training, HealthKit activities, and recovery signals.")
                .font(.caption)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func observationRow(_ obs: UserObservation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: obs.kind))
                .font(.caption)
                .foregroundColor(.accentBlue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(obs.subject.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondaryText)
                    confidenceBadge(obs.confidence)
                }
                Text(obs.text)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(UIColor.systemGroupedBackground))
        .cornerRadius(8)
    }

    private func icon(for kind: ObservationKind) -> String {
        switch kind {
        case .correlation: return "link"
        case .pattern:     return "chart.line.uptrend.xyaxis"
        case .programming: return "dumbbell"
        case .recovery:    return "bed.double"
        case .note:        return "lightbulb"
        case .unknown:     return "sparkles"
        }
    }

    private func confidenceBadge(_ confidence: ObservationConfidence) -> some View {
        let (label, color): (String, Color) = {
            switch confidence {
            case .high:   return ("HIGH",   .green)
            case .medium: return ("MEDIUM", .orange)
            case .low:    return ("LOW",    .secondaryText)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
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
