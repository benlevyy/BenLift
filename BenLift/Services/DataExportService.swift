import Foundation
import SwiftData

/// Exports and imports all BenLift data as a single JSON file.
struct DataExportService {

    // MARK: - Export Structs

    struct BenLiftBackup: Codable {
        let version: Int
        let exportDate: Date
        let sessions: [SessionBackup]
        let program: ProgramBackup?
        let customExercises: [ExerciseBackup]
        // Optional (not `let ... = []`) so a pre-existing backup file that
        // predates these fields still decodes — missing keys become nil,
        // treated as empty on import. Added because the AI-learned rules/
        // observations and calendar pin state are the least reproducible
        // data in the app and were silently absent from every backup taken
        // before this fix.
        let userRules: [UserRuleBackup]?
        let sessionEvents: [SessionEventBackup]?
        let muscleGroupPins: [MuscleGroupPinBackup]?
    }

    struct SessionBackup: Codable {
        let id: UUID
        let date: Date
        let category: String?
        let sessionName: String?
        let muscleGroups: [String]
        let duration: Double?
        let feeling: Int?
        let concerns: String?
        let aiPlanUsed: Bool
        let entries: [EntryBackup]
    }

    struct EntryBackup: Codable {
        let exerciseName: String
        let order: Int
        let sets: [SetBackup]
    }

    struct SetBackup: Codable {
        let setNumber: Int
        let weight: Double
        let reps: Double
        let timestamp: Date
        let isWarmup: Bool
    }

    struct ProgramBackup: Codable {
        let id: UUID
        let name: String
        let goal: String
        let specificTargets: String?
        let experienceLevel: String
        let daysPerWeek: Int
        let splitData: Data?
        let weeklyVolumeTargetsData: Data?
        let compoundPriorityData: Data?
        let progressionSchemeData: Data?
        let periodization: String
        let deloadFrequency: String
        let currentWeek: Int
        let isActive: Bool
        /// Optional so backups taken before the nine coaching-profile
        /// columns collapsed into one plain-text field still decode.
        let goalText: String?
    }

    struct ExerciseBackup: Codable {
        let name: String
        let muscleGroup: String
        let equipment: String
        let defaultWeight: Double?
    }

    struct UserRuleBackup: Codable {
        let id: UUID
        let kindRaw: String
        let subject: String
        let target: String?
        let reason: String?
        let createdAt: Date
        let lastReinforcedAt: Date
        let isActive: Bool
    }

    struct SessionEventBackup: Codable {
        let id: UUID
        let timestamp: Date
        let kindRaw: String
        let exerciseName: String?
        let replacementName: String?
        let exerciseIndex: Int?
        let contextJSON: String?
        let sessionDate: Date?
    }

    struct MuscleGroupPinBackup: Codable {
        let id: UUID
        let date: Date
        let muscleGroups: [String]
        let label: String?
        let note: String?
        let createdAt: Date
    }

    // MARK: - Export

    static func exportData(modelContext: ModelContext) throws -> Data {
        // Sessions + entries + sets
        let sessions = (try? modelContext.fetch(FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []

        let sessionBackups = sessions.map { session in
            SessionBackup(
                id: session.id,
                date: session.date,
                category: session.category?.rawValue,
                sessionName: session.sessionName,
                muscleGroups: session.muscleGroups.map(\.rawValue),
                duration: session.duration,
                feeling: session.feeling,
                concerns: session.concerns,
                aiPlanUsed: session.aiPlanUsed,
                entries: session.sortedEntries.map { entry in
                    EntryBackup(
                        exerciseName: entry.exerciseName,
                        order: entry.order,
                        sets: entry.sortedSets.map { set in
                            SetBackup(
                                setNumber: set.setNumber,
                                weight: set.weight,
                                reps: set.reps,
                                timestamp: set.timestamp,
                                isWarmup: set.isWarmup
                            )
                        }
                    )
                }
            )
        }

        // Program
        let programs = (try? modelContext.fetch(FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true }
        ))) ?? []
        let programBackup = programs.first.map { p in
            ProgramBackup(
                id: p.id, name: p.name, goal: p.goal, specificTargets: p.specificTargets,
                experienceLevel: p.experienceLevel, daysPerWeek: p.daysPerWeek,
                splitData: p.splitData, weeklyVolumeTargetsData: p.weeklyVolumeTargetsData,
                compoundPriorityData: p.compoundPriorityData, progressionSchemeData: p.progressionSchemeData,
                periodization: p.periodization, deloadFrequency: p.deloadFrequency,
                currentWeek: p.currentWeek, isActive: p.isActive,
                goalText: p.goalText
            )
        }

        // Custom exercises only
        let exercises = (try? modelContext.fetch(FetchDescriptor<Exercise>(
            predicate: #Predicate { $0.isCustom == true }
        ))) ?? []
        let exerciseBackups = exercises.map { e in
            ExerciseBackup(
                name: e.name, muscleGroup: e.muscleGroup.rawValue,
                equipment: e.equipment.rawValue, defaultWeight: e.defaultWeight
            )
        }

        // User rules — durable constraints the resolver enforces in Swift.
        let rules = (try? modelContext.fetch(FetchDescriptor<UserRule>())) ?? []
        let ruleBackups = rules.map { r in
            UserRuleBackup(
                id: r.id, kindRaw: r.kindRaw, subject: r.subject, target: r.target,
                reason: r.reason, createdAt: r.createdAt,
                lastReinforcedAt: r.lastReinforcedAt, isActive: r.isActive
            )
        }

        // Session events — the behaviour signal from inside a workout.
        let events = (try? modelContext.fetch(FetchDescriptor<SessionEvent>())) ?? []
        let eventBackups = events.map { ev in
            SessionEventBackup(
                id: ev.id, timestamp: ev.timestamp, kindRaw: ev.kindRaw,
                exerciseName: ev.exerciseName, replacementName: ev.replacementName,
                exerciseIndex: ev.exerciseIndex, contextJSON: ev.contextJSON,
                sessionDate: ev.sessionDate
            )
        }

        // Calendar pins — user-set future-day muscle targets.
        let pins = (try? modelContext.fetch(FetchDescriptor<MuscleGroupPin>())) ?? []
        let pinBackups = pins.map { p in
            MuscleGroupPinBackup(
                id: p.id, date: p.date, muscleGroups: p.muscleGroups.map(\.rawValue),
                label: p.label, note: p.note, createdAt: p.createdAt
            )
        }

        let backup = BenLiftBackup(
            version: 1,
            exportDate: Date(),
            sessions: sessionBackups,
            program: programBackup,
            customExercises: exerciseBackups,
            userRules: ruleBackups,
            sessionEvents: eventBackups,
            muscleGroupPins: pinBackups
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    // MARK: - Import

    static func importData(_ data: Data, modelContext: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BenLiftBackup.self, from: data)

        print("[BenLift/Import] Importing: \(backup.sessions.count) sessions, program: \(backup.program?.name ?? "none")")

        // Import sessions
        for sb in backup.sessions {
            // Skip if session with same date already exists
            let checkDate = sb.date
            let existing = try? modelContext.fetch(FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.date == checkDate }
            ))
            if let existing, !existing.isEmpty { continue }

            let muscleGroups = sb.muscleGroups.compactMap { MuscleGroup(rawValue: $0) }
            let session = WorkoutSession(
                id: sb.id,
                date: sb.date,
                category: sb.category.flatMap { WorkoutCategory(rawValue: $0) },
                sessionName: sb.sessionName,
                muscleGroups: muscleGroups,
                duration: sb.duration,
                feeling: sb.feeling,
                concerns: sb.concerns,
                aiPlanUsed: sb.aiPlanUsed
            )

            for eb in sb.entries {
                let entry = ExerciseEntry(exerciseName: eb.exerciseName, order: eb.order)
                for setB in eb.sets {
                    let setLog = SetLog(
                        setNumber: setB.setNumber, weight: setB.weight,
                        reps: setB.reps, timestamp: setB.timestamp, isWarmup: setB.isWarmup
                    )
                    entry.sets.append(setLog)
                }
                session.entries.append(entry)
            }
            modelContext.insert(session)
        }

        // Import program (replace active)
        if let pb = backup.program {
            // Deactivate existing
            let existingPrograms = (try? modelContext.fetch(FetchDescriptor<TrainingProgram>())) ?? []
            for p in existingPrograms { p.isActive = false }

            let program = TrainingProgram(
                id: pb.id, name: pb.name, goal: pb.goal,
                specificTargets: pb.specificTargets,
                experienceLevel: pb.experienceLevel, daysPerWeek: pb.daysPerWeek,
                periodization: pb.periodization, deloadFrequency: pb.deloadFrequency,
                currentWeek: pb.currentWeek, isActive: pb.isActive
            )
            program.splitData = pb.splitData
            program.weeklyVolumeTargetsData = pb.weeklyVolumeTargetsData
            program.compoundPriorityData = pb.compoundPriorityData
            program.progressionSchemeData = pb.progressionSchemeData
            program.goalText = pb.goalText ?? ""
            modelContext.insert(program)
        }


        // Import session events
        for evb in backup.sessionEvents ?? [] {
            let checkId = evb.id
            let existing = try? modelContext.fetch(FetchDescriptor<SessionEvent>(
                predicate: #Predicate { $0.id == checkId }
            ))
            if let existing, !existing.isEmpty { continue }
            let event = SessionEvent(
                id: evb.id, timestamp: evb.timestamp,
                kind: SessionEventKind(rawValue: evb.kindRaw) ?? .unknown,
                exerciseName: evb.exerciseName, replacementName: evb.replacementName,
                exerciseIndex: evb.exerciseIndex, contextJSON: evb.contextJSON,
                sessionDate: evb.sessionDate
            )
            modelContext.insert(event)
        }

        // Import calendar pins
        for pb in backup.muscleGroupPins ?? [] {
            let checkId = pb.id
            let existing = try? modelContext.fetch(FetchDescriptor<MuscleGroupPin>(
                predicate: #Predicate { $0.id == checkId }
            ))
            if let existing, !existing.isEmpty { continue }
            let pin = MuscleGroupPin(
                id: pb.id, date: pb.date,
                muscleGroups: pb.muscleGroups.compactMap(MuscleGroup.init(rawValue:)),
                label: pb.label, note: pb.note, createdAt: pb.createdAt
            )
            modelContext.insert(pin)
        }


        try modelContext.save()
        print("[BenLift/Import] Import complete")
    }
}
