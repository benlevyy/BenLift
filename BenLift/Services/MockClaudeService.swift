import Foundation

/// Mock service for UI development without burning API calls.
actor MockClaudeCoachService: CoachServiceProtocol {
    private let delay: UInt64 = 1_500_000_000 // 1.5 seconds

    func recommendFocus(systemPrompt: String, userPrompt: String, model: String) async throws -> RecoveryRecommendation {
        try await Task.sleep(nanoseconds: delay)
        return RecoveryRecommendation(
            muscleGroupStatus: [
                MuscleGroupStatus(muscleGroup: "chest", status: "ready", daysSinceTraining: 3, weeklySetsDone: 8, note: nil),
                MuscleGroupStatus(muscleGroup: "back", status: "sore", daysSinceTraining: 1, weeklySetsDone: 12, note: "climbed yesterday"),
                MuscleGroupStatus(muscleGroup: "shoulders", status: "ready", daysSinceTraining: 3, weeklySetsDone: 6, note: nil),
                MuscleGroupStatus(muscleGroup: "biceps", status: "recovering", daysSinceTraining: 1, weeklySetsDone: 4, note: "climbing fatigue"),
                MuscleGroupStatus(muscleGroup: "triceps", status: "ready", daysSinceTraining: 3, weeklySetsDone: 4, note: nil),
                MuscleGroupStatus(muscleGroup: "quads", status: "fresh", daysSinceTraining: 5, weeklySetsDone: 0, note: nil),
                MuscleGroupStatus(muscleGroup: "hamstrings", status: "fresh", daysSinceTraining: 5, weeklySetsDone: 0, note: nil),
                MuscleGroupStatus(muscleGroup: "glutes", status: "fresh", daysSinceTraining: 5, weeklySetsDone: 0, note: nil),
                MuscleGroupStatus(muscleGroup: "calves", status: "fresh", daysSinceTraining: 7, weeklySetsDone: 0, note: nil),
                MuscleGroupStatus(muscleGroup: "core", status: "ready", daysSinceTraining: 3, weeklySetsDone: 3, note: nil),
                MuscleGroupStatus(muscleGroup: "forearms", status: "sore", daysSinceTraining: 1, weeklySetsDone: 0, note: "climbing grip fatigue"),
            ],
            recommendedFocus: ["quads", "hamstrings", "shoulders"],
            recommendedSessionName: "Heavy Legs + Rear Delts",
            reasoning: "Climbed yesterday — grip, back, and biceps need recovery. Quads and hamstrings haven't been trained in 5 days. Adding rear delts since they're ready and complement leg day."
        )
    }

    func generateProgram(systemPrompt: String, userPrompt: String, model: String) async throws -> ProgramResponse {
        try await Task.sleep(nanoseconds: delay)
        return ProgramResponse(program: ProgramData(
            name: "Hypertrophy PPL - Bench Focus",
            split: ["push", "pull", "legs", "push", "pull", "rest", "rest"],
            weeklySchedule: ["monday": "push", "tuesday": "pull", "wednesday": "legs", "thursday": "push", "friday": "pull", "saturday": "rest", "sunday": "rest"],
            periodization: "linear",
            deloadFrequency: "every 4 weeks",
            focusAreas: ["chest", "shoulders"],
            weeklyVolumeTargets: [
                "chest": VolumeTarget(sets: 16, repRange: "8-12"),
                "back": VolumeTarget(sets: 16, repRange: "8-12"),
                "shoulders": VolumeTarget(sets: 12, repRange: "10-15"),
                "triceps": VolumeTarget(sets: 8, repRange: "10-15"),
                "biceps": VolumeTarget(sets: 8, repRange: "10-15"),
                "quads": VolumeTarget(sets: 12, repRange: "8-12"),
                "hamstrings": VolumeTarget(sets: 8, repRange: "10-12"),
                "glutes": VolumeTarget(sets: 6, repRange: "8-12"),
                "calves": VolumeTarget(sets: 6, repRange: "12-15"),
            ],
            compoundPriority: ["Bench Press", "Squat", "Deadlift", "Overhead Press"],
            progressionScheme: [
                "compounds": "add 5lbs when all target reps hit across all sets",
                "isolation": "add 2.5-5lbs when top of rep range hit for 2 consecutive sessions",
            ],
            notes: "Running a bench focus block for 8 weeks."
        ))
    }

    func generateDailyPlan(systemPrompt: String, userPrompt: String, model: String) async throws -> DailyPlanResponse {
        try await Task.sleep(nanoseconds: delay)
        return DailyPlanResponse(
            exercises: [
                PlannedExercise(name: "Bench Press", sets: 4, targetReps: "6-8", suggestedWeight: 175, repScheme: "straight", warmupSets: [WarmupSet(weight: 95, reps: 10), WarmupSet(weight: 135, reps: 5)], notes: "Focus on bar path. Try 175 for 4x6-8.", intent: "primary compound"),
                PlannedExercise(name: "Incline DB Press", sets: 3, targetReps: "8-10", suggestedWeight: 60, repScheme: "straight", warmupSets: nil, notes: "Slow eccentric, 2-3 seconds down.", intent: "secondary compound"),
                PlannedExercise(name: "Cable Flyes", sets: 3, targetReps: "12-15", suggestedWeight: 25, repScheme: nil, warmupSets: nil, notes: "Squeeze at peak contraction.", intent: "isolation"),
                PlannedExercise(name: "Lateral Raises", sets: 3, targetReps: "12-15", suggestedWeight: 15, repScheme: nil, warmupSets: nil, notes: "Controlled reps, no momentum.", intent: "isolation"),
                PlannedExercise(name: "Tricep Pushdowns", sets: 3, targetReps: "10-12", suggestedWeight: 40, repScheme: nil, warmupSets: nil, notes: nil, intent: "isolation"),
                PlannedExercise(name: "Overhead Tricep Extension", sets: 3, targetReps: "10-12", suggestedWeight: 30, repScheme: nil, warmupSets: nil, notes: nil, intent: "finisher"),
            ],
            sessionStrategy: "Second push day this week. Bench is the lead, accessories shift to higher-rep hypertrophy work.",
            estimatedDuration: 52,
            deloadNote: nil
        )
    }

    func adaptMidWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> MidWorkoutAdaptResponse {
        try await Task.sleep(nanoseconds: delay)
        return MidWorkoutAdaptResponse(
            exercises: [
                PlannedExercise(name: "Tricep Pushdowns", sets: 4, targetReps: "10-12", suggestedWeight: 40, repScheme: nil, warmupSets: nil, notes: "Added an extra set since we dropped lateral raises.", intent: "isolation"),
            ],
            rationale: "Dropped lateral raises due to shoulder concern. Added extra pushdown set."
        )
    }

    func analyzePostWorkout(systemPrompt: String, userPrompt: String, model: String) async throws -> PostWorkoutAnalysisResponse {
        try await Task.sleep(nanoseconds: delay)
        return PostWorkoutAnalysisResponse(
            summary: "Solid push session. Hit a rep PR on bench press.",
            performanceVsplan: PerformanceVsPlan(adherence: 0.85, notes: "Completed 5 of 6 planned exercises."),
            progressionEvents: [
                ProgressionEvent(exercise: "Bench Press", type: "rep_pr", detail: "185 lbs x 5 reps (previous best: 185 x 4.5)", recommendation: "Try 185 for 3x6 next session."),
            ],
            volumeAnalysis: [
                "chest": VolumeAnalysisEntry(actual: 10, weeklyTarget: 16, weeklyActual: 10, status: "on track"),
                "triceps": VolumeAnalysisEntry(actual: 6, weeklyTarget: 8, weeklyActual: 6, status: "on track"),
            ],
            recoveryNotes: "Sleep was 6.1 hours. Prioritize rest tonight.",
            overallRating: "good",
            coachNote: "The failed rep on bench last session became a clean 5 today. Real progress. Nail 185x3x6 before moving up.",
            observations: ["Bench working weight ~185", "Responds well to progressive overload on compounds"]
        )
    }

    func refreshIntelligence(systemPrompt: String, userPrompt: String, model: String) async throws -> IntelligenceRefreshResponse {
        try await Task.sleep(nanoseconds: delay)
        return IntelligenceRefreshResponse(
            activityPatterns: "Climbs 2-3x/week, typically Wed evenings and weekend mornings. Occasional runs on Saturdays.",
            trainingPatterns: "Lifts 4x/week on a push/pull/legs rotation. Average session ~50 minutes, 5-6 exercises. Most consistent Mon-Thu.",
            strengthProfile: "Bench 185x6 (e1RM ~222), progressing ~5 lbs/month. Squat 225x5 (e1RM ~253). OHP 115x8 (e1RM ~145). Pull-ups BW+25x6.",
            recoveryProfile: "Avg sleep 7.2h (stable). RHR 64 bpm (stable). HRV 52ms (stable). Needs 48h+ between heavy push sessions. Back recovers slower after climbing days.",
            exercisePreferences: "Favors incline DB press over flat barbell. Consistently picks cable work for delts. Skips leg extensions. Prefers hammer curls over barbell curls.",
            notableObservations: "Performance dips on sessions immediately after climbing. PRs tend to happen on Monday/Tuesday when well-rested. Grip sometimes limits heavy pulling after climb days."
        )
    }

    func generateWeeklyReview(systemPrompt: String, userPrompt: String, model: String) async throws -> WeeklyReviewResponse {
        try await Task.sleep(nanoseconds: delay)
        return WeeklyReviewResponse(
            weekSummary: WeekSummaryData(sessionsCompleted: 5, sessionsPlanned: 5, totalVolume: 47820, totalDuration: 4.2, avgFeeling: 3.8),
            goalProgress: [
                GoalProgressEntry(goal: "Bench 225", metric: "Estimated 1RM (Epley)", current: 208, previous: 204, trend: "up", projection: "~6-8 weeks to 225 e1RM."),
            ],
            weeklyVolumeCompliance: [
                "chest": VolumeComplianceEntry(target: 16, actual: 18, status: "hit"),
                "back": VolumeComplianceEntry(target: 16, actual: 14, status: "slightly under"),
            ],
            strengthTrends: [
                StrengthTrend(exercise: "Bench Press", e1rm4wkAgo: 195, e1rmNow: 208, trend: "strong upward"),
            ],
            programAdjustments: [
                ProgramAdjustment(type: "volume_adjustment", detail: "Reduce overhead pressing volume by 2 sets/week.", priority: "high"),
            ],
            recoveryReport: RecoveryReport(avgSleep: 6.8, sleepTrend: "declining", avgRestingHR: 59, restingHRTrend: "stable", note: "Sleep trending down."),
            coachNote: "Strong week. Bench is moving well. Fix sleep first, then reassess deadlift in 2 weeks."
        )
    }
}
