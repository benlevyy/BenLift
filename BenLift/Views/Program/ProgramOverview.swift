import SwiftUI
import SwiftData

struct ProgramOverview: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coachVM: CoachViewModel
    @Bindable var programVM: ProgramViewModel
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

                    // Coaching profile
                    coachingProfileSection

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

    private var muscleStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MUSCLE STATUS")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            if let rec = coachVM.recommendation {
                // Show from latest AI recommendation
                ForEach(rec.muscleGroupStatus) { mg in
                    muscleStatusRow(name: mg.muscleGroup, status: mg.status, level: mg.statusLevel, note: mg.note)
                }
            } else {
                // Compute from workout history
                ForEach(computedMuscleStatus(), id: \.name) { mg in
                    muscleStatusRow(name: mg.name, status: mg.status, level: mg.level, note: nil)
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func muscleStatusRow(name: String, status: String, level: Double, note: String?) -> some View {
        HStack(spacing: 8) {
            Text(name.capitalized)
                .font(.caption)
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.secondaryText)

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

        return VStack(alignment: .leading, spacing: 8) {
            Text("WEEKLY VOLUME")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)

            ForEach(volumeByGroup.sorted(by: { $0.value > $1.value }), id: \.key) { group, sets in
                HStack {
                    Text(group.capitalized)
                        .font(.caption)
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(.secondaryText)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentBlue)
                            .frame(width: geo.size.width * min(Double(sets) / 20.0, 1.0))
                    }
                    .frame(height: 10)

                    Text("\(sets) sets")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 45, alignment: .leading)
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

    // MARK: - Coaching Profile

    private var coachingProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("COACHING PROFILE")
                    .font(.caption.bold())
                    .foregroundColor(.secondaryText)
                Spacer()
                if let program = programVM.currentProgram {
                    NavigationLink {
                        CoachingProfileView(program: program)
                    } label: {
                        Text("Edit")
                            .font(.caption)
                            .foregroundColor(.accentBlue)
                    }
                }
            }

            if let program = programVM.currentProgram {
                HStack(spacing: 16) {
                    profileItem("Goal", program.goal)
                    profileItem("Experience", program.experienceLevel)
                    profileItem("Days/week", "\(program.daysPerWeek)")
                }
            } else {
                Text("No profile set up yet")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
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
