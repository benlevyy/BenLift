import SwiftUI
import SwiftData

struct ProgramOverview: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
    var intelligenceVM: IntelligenceViewModel
    @Query(sort: \WorkoutSession.date, order: .reverse) private var allSessions: [WorkoutSession]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Muscle status section
                    muscleStatusSection

                    // This week summary
                    thisWeekSection

                    // Weekly volume by muscle group
                    weeklyVolumeSection

                    // Recent activities (climbing, cardio)
                    recentActivitiesSection

                    // Intelligence (AI-generated from data)
                    intelligenceSection

                    // Exercise library link
                    NavigationLink {
                        ExerciseListView()
                    } label: {
                        HStack {
                            Image(systemName: "dumbbell.fill")
                            Text("Exercise Library")
                            Spacer()
                            Text("\(exerciseCount)")
                                .foregroundColor(.secondaryText)
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondaryText)
                        }
                        .padding()
                        .background(Color.cardSurface)
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Recovery")
            .onAppear {
                programVM.loadCurrentProgram(modelContext: modelContext)
                loadActivities()
            }
        }
    }

    // MARK: - Exercise count

    @Query private var exercises: [Exercise]
    private var exerciseCount: Int { exercises.count }

    // MARK: - Muscle Status

    @State private var overrides: [String: String] = [:]  // muscleGroup -> overridden status

    private var muscleStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MUSCLE STATUS")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                Spacer()
                if !overrides.isEmpty {
                    Button {
                        overrides = [:]
                    } label: {
                        Text("Reset")
                            .font(.caption2)
                            .foregroundColor(.accentBlue)
                    }
                }
            }

            if let rec = coachVM.recommendation {
                ForEach(rec.muscleGroupStatus) { mg in
                    let effectiveStatus = overrides[mg.muscleGroup] ?? mg.status
                    let effectiveLevel = statusLevel(effectiveStatus)
                    tappableStatusRow(
                        name: mg.muscleGroup,
                        status: effectiveStatus,
                        level: effectiveLevel,
                        isOverridden: overrides[mg.muscleGroup] != nil
                    )
                }
            } else {
                ForEach(computedMuscleStatus(), id: \.name) { mg in
                    let effectiveStatus = overrides[mg.name] ?? mg.status
                    let effectiveLevel = statusLevel(effectiveStatus)
                    tappableStatusRow(
                        name: mg.name,
                        status: effectiveStatus,
                        level: effectiveLevel,
                        isOverridden: overrides[mg.name] != nil
                    )
                }
            }

            Text("Tap a muscle group to adjust")
                .font(.system(size: 9))
                .foregroundColor(.secondaryText)
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
        .onChange(of: overrides) { _, newOverrides in
            // Feed overrides into coach concerns for next recommendation
            if !newOverrides.isEmpty {
                let soreGroups = newOverrides.filter { $0.value == "sore" }.map { $0.key.capitalized }
                let recoveringGroups = newOverrides.filter { $0.value == "recovering" }.map { $0.key.capitalized }
                var parts: [String] = []
                if !soreGroups.isEmpty { parts.append("\(soreGroups.joined(separator: ", ")) sore") }
                if !recoveringGroups.isEmpty { parts.append("\(recoveringGroups.joined(separator: ", ")) recovering") }
                coachVM.concerns = parts.joined(separator: ". ")
            }
        }
    }

    private let statusCycle = ["fresh", "ready", "recovering", "sore"]

    private func tappableStatusRow(name: String, status: String, level: Double, isOverridden: Bool) -> some View {
        Button {
            let currentIndex = statusCycle.firstIndex(of: status) ?? 0
            let nextIndex = (currentIndex + 1) % statusCycle.count
            overrides[name] = statusCycle[nextIndex]
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    if isOverridden {
                        Circle()
                            .fill(Color.accentBlue)
                            .frame(width: 4, height: 4)
                    }
                    Text(name.capitalized)
                        .font(.caption)
                        .foregroundColor(isOverridden ? .primary : .secondaryText)
                }
                .frame(width: 75, alignment: .trailing)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(statusColor(status))
                            .frame(width: geo.size.width * level)
                    }
                }
                .frame(height: 10)

                Text(status)
                    .font(.caption2)
                    .foregroundColor(statusColor(status))
                    .frame(width: 60, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func statusLevel(_ status: String) -> Double {
        switch status {
        case "fresh": return 1.0
        case "ready": return 0.75
        case "recovering": return 0.4
        case "sore": return 0.15
        default: return 0.5
        }
    }

    // MARK: - This Week

    private var thisWeekSection: some View {
        let weekSessions = sessionsThisWeek
        let liftingSessions = weekSessions.count
        let totalVolume = weekSessions.reduce(0.0) { $0 + $1.totalVolume }

        return VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            HStack(spacing: 16) {
                statPill("\(liftingSessions)", "sessions")
                statPill("\(Int(totalVolume))", "lbs volume")
                if !recentActivityData.isEmpty {
                    statPill("\(recentActivityData.count)", "activities")
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func statPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondaryText)
        }
    }

    // MARK: - Weekly Volume

    private var weeklyVolumeSection: some View {
        let volumeByGroup = computeWeeklyVolume()

        // Show ALL muscle groups, not just ones with data
        let allGroups: [(String, Int)] = MuscleGroup.allCases.map { mg in
            (mg.rawValue, volumeByGroup[mg.rawValue] ?? 0)
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text("WEEKLY VOLUME")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            ForEach(allGroups.sorted(by: { $0.1 > $1.1 }), id: \.0) { group, sets in
                HStack {
                    Text(group.capitalized)
                        .font(.caption)
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(sets > 0 ? .primary : .secondaryText.opacity(0.5))

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.15))
                            if sets > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentBlue)
                                    .frame(width: geo.size.width * min(Double(sets) / 20.0, 1.0))
                            }
                        }
                    }
                    .frame(height: 10)

                    Text(sets > 0 ? "\(sets)" : "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(sets > 0 ? .primary : .secondaryText.opacity(0.4))
                        .frame(width: 30, alignment: .leading)
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    // MARK: - Recent Activities

    @State private var recentActivityData: [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)] = []

    private var recentActivitiesSection: some View {
        Group {
            if !recentActivityData.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT ACTIVITIES")
                        .font(.caption.bold())
                        .foregroundColor(.secondaryText)

                    ForEach(Array(recentActivityData.prefix(5).enumerated()), id: \.offset) { _, activity in
                        HStack {
                            Image(systemName: activityIcon(activity.type))
                                .foregroundColor(.accentBlue)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(activity.type.capitalized)
                                    .font(.subheadline)
                                Text("\(activity.date.shortFormatted) • \(TimeInterval(activity.duration).formattedDuration) • \(activity.source)")
                                    .font(.caption2)
                                    .foregroundColor(.secondaryText)
                            }
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color.cardSurface)
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Intelligence

    private var intelligenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INTELLIGENCE")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                Spacer()
                NavigationLink {
                    IntelligenceView(
                        intelligenceVM: intelligenceVM,
                        program: programVM.currentProgram
                    )
                } label: {
                    Text("View / Refresh")
                        .font(.caption)
                        .foregroundColor(.accentBlue)
                }
            }

            if let intel = intelligenceVM.intelligence, intel.hasBeenRefreshed {
                // Show compact summary
                if !intel.trainingPatterns.isEmpty && intel.trainingPatterns != "Insufficient data" {
                    Text(intel.trainingPatterns)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                if !intel.strengthProfile.isEmpty && intel.strengthProfile != "Insufficient data" {
                    Text(intel.strengthProfile)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                HStack {
                    Text("Refreshed \(intel.lastRefreshed.shortFormatted)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondaryText)
                    if intel.isStale {
                        Text("Stale")
                            .font(.system(size: 9).bold())
                            .foregroundColor(.orange)
                    }
                    if intel.workoutsSinceRefresh > 0 {
                        Text("\(intel.workoutsSinceRefresh) new workouts")
                            .font(.system(size: 9))
                            .foregroundColor(.secondaryText)
                    }
                    Spacer()
                }
            } else {
                Text("Tap View / Refresh to analyze your training data.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }

            if let program = programVM.currentProgram {
                Divider()
                HStack(spacing: 16) {
                    profileItem("Goal", program.goal)
                    profileItem("Experience", program.experienceLevel)
                    profileItem("Days/week", "\(program.daysPerWeek)")
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func profileItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondaryText)
            Text(value.capitalized)
                .font(.subheadline.bold())
        }
    }

    // MARK: - Helpers

    private var sessionsThisWeek: [WorkoutSession] {
        let startOfWeek = Date().startOfWeek
        return allSessions.filter { $0.date >= startOfWeek }
    }

    private func computeWeeklyVolume() -> [String: Int] {
        let lookup = DefaultExercises.buildMuscleGroupLookup(from: modelContext)
        var result: [String: Int] = [:]

        for session in sessionsThisWeek {
            for entry in session.entries {
                let group = lookup[entry.exerciseName]?.rawValue ?? "other"
                let workingSets = entry.sets.filter { !$0.isWarmup }.count
                result[group, default: 0] += workingSets
            }
        }
        return result
    }

    private struct ComputedStatus: Identifiable {
        var id: String { name }
        let name: String
        let status: String
        let level: Double
    }

    private func computedMuscleStatus() -> [ComputedStatus] {
        let lookup = DefaultExercises.buildMuscleGroupLookup(from: modelContext)
        var lastTrained: [String: Date] = [:]

        for session in allSessions.prefix(20) {
            for entry in session.entries {
                let group = lookup[entry.exerciseName]?.rawValue ?? "other"
                if lastTrained[group] == nil {
                    lastTrained[group] = session.date
                }
            }
        }

        return MuscleGroup.allCases.map { mg in
            let name = mg.rawValue
            let daysSince = lastTrained[name].map { Date().daysSince($0) } ?? 99

            let status: String
            let level: Double
            if daysSince >= 4 {
                status = "fresh"; level = 1.0
            } else if daysSince >= 3 {
                status = "ready"; level = 0.75
            } else if daysSince >= 2 {
                status = "recovering"; level = 0.4
            } else {
                status = "sore"; level = 0.15
            }

            return ComputedStatus(name: name, status: status, level: level)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "fresh": return .prGreen
        case "ready": return .pushBlue
        case "recovering": return .legsOrange
        case "sore": return .failedRed
        default: return .secondaryText
        }
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "climbing": return "figure.climbing"
        case "running": return "figure.run"
        case "cycling": return "figure.outdoor.cycle"
        case "swimming": return "figure.pool.swim"
        case "yoga": return "figure.yoga"
        case "hiking": return "figure.hiking"
        default: return "figure.mixed.cardio"
        }
    }

    private func loadActivities() {
        Task {
            recentActivityData = await HealthKitService.shared.fetchRecentActivities(days: 7)
        }
    }
}
