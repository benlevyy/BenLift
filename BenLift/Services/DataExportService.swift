import Foundation
import SwiftData

/// Exports and imports all BenLift data as a single JSON file.
struct DataExportService {

    // MARK: - Export Structs

    struct BenLiftBackup: Codable {
        let version: Int = 1
        let exportDate: Date
        let sessions: [SessionBackup]
        let program: ProgramBackup?
        let analyses: [AnalysisBackup]
        let weeklyReviews: [WeeklyReviewBackup]
        let intelligence: IntelligenceBackup?
        let customExercises: [ExerciseBackup]
        // Optional (not `let ... = []`) so a pre-existing backup file that
        // predates these fields still decodes — missing keys become nil,
        // treated as empty on import. Added because the AI-learned rules/
        // observations and calendar pin state are the least reproducible
        // data in the app and were silently absent from every backup taken
        // before this fix.
        let userRules: [UserRuleBackup]?
        let observations: [UserObservationBackup]?
        let sessionEvents: [SessionEventBackup]?
        let muscleGroupPins: [MuscleGroupPinBackup]?
        let seedPatterns: [SeedPatternBackup]?
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
        let otherActivities: String?
        let activitySchedule: String?
        let musclePriorities: String?
        let ongoingConcerns: String?
        let recoveryNotes: String?
        let coachingStyle: String?
        let customCoachNotes: String?
    }

    struct AnalysisBackup: Codable {
        let sessionId: UUID
        let summary: String
        let overallRating: String
        let progressionEventsData: Data?
        let volumeAnalysisData: Data?
        let recoveryNotes: String?
        let coachNote: String
        let createdAt: Date
    }

    struct WeeklyReviewBackup: Codable {
        let weekStartDate: Date
        let sessionsCompleted: Int
        let sessionsPlanned: Int
        let totalVolume: Double
        let goalProgressData: Data?
        let volumeComplianceData: Data?
        let strengthTrendsData: Data?
        let programAdjustmentsData: Data?
        let recoveryReportData: Data?
        let coachNote: String
        let createdAt: Date
    }

    struct IntelligenceBackup: Codable {
        let lastRefreshed: Date
        let activityPatterns: String
        let trainingPatterns: String
        let strengthProfile: String
        let recoveryProfile: String
        let exercisePreferences: String
        let notableObservations: String
        let pendingObservations: String
        let injuries: String
        let userNotes: String
        let workoutsSinceRefresh: Int
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

    struct UserObservationBackup: Codable {
        let id: UUID
        let kindRaw: String
        let subject: String
        let text: String
        let confidenceRaw: String
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

    struct SeedPatternBackup: Codable {
        let id: UUID
        let weekday: Int
        let muscleGroups: [String]
        let sourceRaw: String
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
                otherActivities: p.otherActivities, activitySchedule: p.activitySchedule,
                musclePriorities: p.musclePriorities, ongoingConcerns: p.ongoingConcerns,
                recoveryNotes: p.recoveryNotes, coachingStyle: p.coachingStyle,
                customCoachNotes: p.customCoachNotes
            )
        }

        // Analyses
        let analyses = (try? modelContext.fetch(FetchDescriptor<PostWorkoutAnalysis>())) ?? []
        let analysisBackups = analyses.map { a in
            AnalysisBackup(
                sessionId: a.sessionId, summary: a.summary,
                overallRating: a.overallRating.rawValue,
                progressionEventsData: a.progressionEventsData,
                volumeAnalysisData: a.volumeAnalysisData,
                recoveryNotes: a.recoveryNotes, coachNote: a.coachNote,
                createdAt: a.createdAt
            )
        }

        // Weekly reviews
        let reviews = (try? modelContext.fetch(FetchDescriptor<WeeklyReview>())) ?? []
        let reviewBackups = reviews.map { r in
            WeeklyReviewBackup(
                weekStartDate: r.weekStartDate,
                sessionsCompleted: r.sessionsCompleted, sessionsPlanned: r.sessionsPlanned,
                totalVolume: r.totalVolume,
                goalProgressData: r.goalProgressData, volumeComplianceData: r.volumeComplianceData,
                strengthTrendsData: r.strengthTrendsData, programAdjustmentsData: r.programAdjustmentsData,
                recoveryReportData: r.recoveryReportData,
                coachNote: r.coachNote, createdAt: r.createdAt
            )
        }

        // Intelligence
        let intels = (try? modelContext.fetch(FetchDescriptor<UserIntelligence>())) ?? []
        let intelBackup = intels.first.map { i in
            IntelligenceBackup(
                lastRefreshed: i.lastRefreshed,
                activityPatterns: i.activityPatterns, trainingPatterns: i.trainingPatterns,
                strengthProfile: i.strengthProfile, recoveryProfile: i.recoveryProfile,
                exercisePreferences: i.exercisePreferences, notableObservations: i.notableObservations,
                pendingObservations: i.pendingObservations,
                injuries: i.injuries, userNotes: i.userNotes,
                workoutsSinceRefresh: i.workoutsSinceRefresh
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

        // User rules — durable hard constraints the AI must respect.
        let rules = (try? modelContext.fetch(FetchDescriptor<UserRule>())) ?? []
        let ruleBackups = rules.map { r in
            UserRuleBackup(
                id: r.id, kindRaw: r.kindRaw, subject: r.subject, target: r.target,
                reason: r.reason, createdAt: r.createdAt,
                lastReinforcedAt: r.lastReinforcedAt, isActive: r.isActive
            )
        }

        // AI-discovered observations.
        let observations = (try? modelContext.fetch(FetchDescriptor<UserObservation>())) ?? []
        let observationBackups = observations.map { o in
            UserObservationBackup(
                id: o.id, kindRaw: o.kindRaw, subject: o.subject, text: o.text,
                confidenceRaw: o.confidenceRaw, createdAt: o.createdAt,
                lastReinforcedAt: o.lastReinforcedAt, isActive: o.isActive
            )
        }

        // Session events — the behavior signal that feeds future plan prompts.
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

        // Seed patterns — bootstrap-seeded weekday defaults.
        let seeds = (try? modelContext.fetch(FetchDescriptor<SeedPattern>())) ?? []
        let seedBackups = seeds.map { s in
            SeedPatternBackup(
                id: s.id, weekday: s.weekday, muscleGroups: s.muscleGroups.map(\.rawValue),
                sourceRaw: s.sourceRaw, createdAt: s.createdAt
            )
        }

        let backup = BenLiftBackup(
            exportDate: Date(),
            sessions: sessionBackups,
            program: programBackup,
            analyses: analysisBackups,
            weeklyReviews: reviewBackups,
            intelligence: intelBackup,
            customExercises: exerciseBackups,
            userRules: ruleBackups,
            observations: observationBackups,
            sessionEvents: eventBackups,
            muscleGroupPins: pinBackups,
            seedPatterns: seedBackups
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
            program.otherActivities = pb.otherActivities
            program.activitySchedule = pb.activitySchedule
            program.musclePriorities = pb.musclePriorities
            program.ongoingConcerns = pb.ongoingConcerns
            program.recoveryNotes = pb.recoveryNotes
            program.coachingStyle = pb.coachingStyle
            program.customCoachNotes = pb.customCoachNotes
            modelContext.insert(program)
        }

        // Import analyses
        for ab in backup.analyses {
            let analysis = PostWorkoutAnalysis(
                sessionId: ab.sessionId, summary: ab.summary,
                overallRating: OverallRating(rawValue: ab.overallRating) ?? .average,
                recoveryNotes: ab.recoveryNotes, coachNote: ab.coachNote
            )
            analysis.progressionEventsData = ab.progressionEventsData
            analysis.volumeAnalysisData = ab.volumeAnalysisData
            modelContext.insert(analysis)
        }

        // Import weekly reviews
        for rb in backup.weeklyReviews {
            let review = WeeklyReview(
                weekStartDate: rb.weekStartDate,
                sessionsCompleted: rb.sessionsCompleted, sessionsPlanned: rb.sessionsPlanned,
                totalVolume: rb.totalVolume, coachNote: rb.coachNote
            )
            review.goalProgressData = rb.goalProgressData
            review.volumeComplianceData = rb.volumeComplianceData
            review.strengthTrendsData = rb.strengthTrendsData
            review.programAdjustmentsData = rb.programAdjustmentsData
            review.recoveryReportData = rb.recoveryReportData
            modelContext.insert(review)
        }

        // Import intelligence
        if let ib = backup.intelligence {
            // Remove existing
            try? modelContext.delete(model: UserIntelligence.self)
            let intel = UserIntelligence(
                lastRefreshed: ib.lastRefreshed,
                activityPatterns: ib.activityPatterns, trainingPatterns: ib.trainingPatterns,
                strengthProfile: ib.strengthProfile, recoveryProfile: ib.recoveryProfile,
                exercisePreferences: ib.exercisePreferences, notableObservations: ib.notableObservations,
                pendingObservations: ib.pendingObservations,
                injuries: ib.injuries, userNotes: ib.userNotes,
                workoutsSinceRefresh: ib.workoutsSinceRefresh
            )
            modelContext.insert(intel)
        }

        // Import custom exercises
        for eb in backup.customExercises {
            guard let mg = MuscleGroup(rawValue: eb.muscleGroup),
                  let eq = Equipment(rawValue: eb.equipment) else { continue }
            let exercise = Exercise(
                name: eb.name, muscleGroup: mg, equipment: eq,
                defaultWeight: eb.defaultWeight, isCustom: true
            )
            modelContext.insert(exercise)
        }

        // Import user rules — skip any id already present.
        for rb in backup.userRules ?? [] {
            let checkId = rb.id
            let existing = try? modelContext.fetch(FetchDescriptor<UserRule>(
                predicate: #Predicate { $0.id == checkId }
            ))
            if let existing, !existing.isEmpty { continue }
            let rule = UserRule(
                id: rb.id, kind: UserRuleKind(rawValue: rb.kindRaw) ?? .unknown,
                subject: rb.subject, target: rb.target, reason: rb.reason,
                createdAt: rb.createdAt, lastReinforcedAt: rb.lastReinforcedAt,
                isActive: rb.isActive
            )
            modelContext.insert(rule)
        }

        // Import observations
        for ob in backup.observations ?? [] {
            let checkId = ob.id
            let existing = try? modelContext.fetch(FetchDescriptor<UserObservation>(
                predicate: #Predicate { $0.id == checkId }
            ))
            if let existing, !existing.isEmpty { continue }
            let observation = UserObservation(
                id: ob.id, kind: ObservationKind(rawValue: ob.kindRaw) ?? .unknown,
                subject: ob.subject, text: ob.text,
                confidence: ObservationConfidence(rawValue: ob.confidenceRaw) ?? .medium,
                createdAt: ob.createdAt, lastReinforcedAt: ob.lastReinforcedAt,
                isActive: ob.isActive
            )
            modelContext.insert(observation)
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

        // Import seed patterns
        for sb in backup.seedPatterns ?? [] {
            let checkId = sb.id
            let existing = try? modelContext.fetch(FetchDescriptor<SeedPattern>(
                predicate: #Predicate { $0.id == checkId }
            ))
            if let existing, !existing.isEmpty { continue }
            let seed = SeedPattern(
                id: sb.id, weekday: sb.weekday,
                muscleGroups: sb.muscleGroups.compactMap(MuscleGroup.init(rawValue:)),
                source: SeedSource(rawValue: sb.sourceRaw) ?? .bootstrap,
                createdAt: sb.createdAt
            )
            modelContext.insert(seed)
        }

        try modelContext.save()
        print("[BenLift/Import] Import complete")
    }
}
