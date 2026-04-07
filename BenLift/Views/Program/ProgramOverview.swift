import SwiftUI
import SwiftData

struct ProgramOverview: View {
    @Environment(\.modelContext) private var modelContext
    @State private var programVM = ProgramViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let program = programVM.currentProgram {
                        coachingProfileCard(program)
                        programCard(program)
                        weeklySchedule(program)
                        volumeTargets(program)
                        navigationLinks
                    } else {
                        noProgramView
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Program")
            .onAppear {
                programVM.loadCurrentProgram(modelContext: modelContext)
            }
        }
    }

    @State private var showCoachingProfile = false

    private func coachingProfileCard(_ program: TrainingProgram) -> some View {
        let hasProfile = [program.otherActivities, program.musclePriorities, program.ongoingConcerns, program.activitySchedule].contains(where: { $0 != nil && !($0?.isEmpty ?? true) })

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Coaching Profile", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Button {
                    showCoachingProfile = true
                } label: {
                    Text(hasProfile ? "Edit" : "Set Up")
                        .font(.subheadline.bold())
                        .foregroundColor(.accentBlue)
                }
            }

            if hasProfile {
                VStack(alignment: .leading, spacing: 4) {
                    if let activities = program.otherActivities, !activities.isEmpty {
                        profileRow(icon: "figure.climbing", text: activities)
                    }
                    if let schedule = program.activitySchedule, !schedule.isEmpty {
                        profileRow(icon: "calendar.badge.clock", text: schedule)
                    }
                    if let priorities = program.musclePriorities, !priorities.isEmpty {
                        profileRow(icon: "star.fill", text: priorities)
                    }
                    if let concerns = program.ongoingConcerns, !concerns.isEmpty {
                        profileRow(icon: "bandage", text: concerns)
                    }
                }
            } else {
                Text("Tell the AI about your lifestyle — other sports, schedule, priorities — so every plan accounts for your full week.")
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
        .sheet(isPresented: $showCoachingProfile) {
            CoachingProfileView(program: program)
        }
    }

    private func profileRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondaryText)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func programCard(_ program: TrainingProgram) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(program.name)
                .font(.title2.bold())

            HStack(spacing: 16) {
                Label(program.goal, systemImage: "target")
                Label("\(program.daysPerWeek) days/week", systemImage: "calendar")
            }
            .font(.subheadline)
            .foregroundColor(.secondaryText)

            HStack(spacing: 16) {
                Label(program.periodization.capitalized, systemImage: "chart.line.uptrend.xyaxis")
                Label("Week \(program.currentWeek)", systemImage: "number")
            }
            .font(.caption)
            .foregroundColor(.secondaryText)

            let status = programVM.currentWeekStatus(modelContext: modelContext)
            Text("\(status.completed)/\(status.planned) sessions this week")
                .font(.subheadline.bold())
                .foregroundColor(.accentBlue)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func weeklySchedule(_ program: TrainingProgram) -> some View {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let split = program.split

        return VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Split")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            HStack(spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let category = index < split.count ? WorkoutCategory(rawValue: split[index]) : nil
                    VStack(spacing: 4) {
                        Text(day)
                            .font(.caption2)
                            .foregroundColor(.secondaryText)
                        Circle()
                            .fill(category?.color ?? Color.secondaryText.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(category?.displayName.prefix(1) ?? "R")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private func volumeTargets(_ program: TrainingProgram) -> some View {
        let targets = program.weeklyVolumeTargets

        return VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Volume Targets")
                .font(.caption.bold())
                .foregroundColor(.secondaryText)
                .textCase(.uppercase)

            ForEach(targets.sorted(by: { $0.key < $1.key }), id: \.key) { group, target in
                HStack {
                    Text(group.capitalized)
                        .font(.subheadline)
                    Spacer()
                    Text("\(target.sets) sets (\(target.repRange))")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
            }
        }
        .padding()
        .background(Color.cardSurface)
        .cornerRadius(12)
    }

    private var navigationLinks: some View {
        VStack(spacing: 8) {
            NavigationLink {
                WeeklyReviewView()
            } label: {
                Label("Weekly Reviews", systemImage: "chart.bar.doc.horizontal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(8)
            }

            NavigationLink {
                ExerciseListView()
            } label: {
                Label("Exercise Library", systemImage: "dumbbell")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(8)
            }

            NavigationLink {
                ProgressionView()
            } label: {
                Label("Progression Charts", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.cardSurface)
                    .cornerRadius(8)
            }
        }
    }

    private var noProgramView: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 48))
                .foregroundColor(.secondaryText)

            Text("No Program Yet")
                .font(.title2.bold())

            Text("Set your goals and generate an AI training program.")
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)

            NavigationLink {
                GoalSettingView(programVM: programVM, isOnboarding: false)
            } label: {
                Text("Create Program")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentBlue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(40)
    }
}
