import Foundation

struct PromptBuilder {

    // MARK: - Shared System Prefix

    static func sharedSystemPrefix(program: TrainingProgram?, healthContext: HealthContext?) -> String {
        var prompt = """
        You are a strength training coach. You communicate concisely and directly.
        You respond ONLY in JSON (no markdown, no backticks, no explanation outside the JSON).

        """

        if let program {
            prompt += """
            User profile:
            - Goal: \(program.goal)
            - Experience: \(program.experienceLevel)
            - Training days/week: \(program.daysPerWeek)

            """

            // Coaching profile — persistent context about the user's lifestyle
            var profileLines: [String] = []
            if let activities = program.otherActivities, !activities.isEmpty {
                profileLines.append("Other activities: \(activities)")
            }
            if let schedule = program.activitySchedule, !schedule.isEmpty {
                profileLines.append("Activity schedule: \(schedule)")
            }
            if let priorities = program.musclePriorities, !priorities.isEmpty {
                profileLines.append("Muscle priorities: \(priorities)")
            }
            if let concerns = program.ongoingConcerns, !concerns.isEmpty {
                profileLines.append("Ongoing concerns: \(concerns)")
            }
            if let recovery = program.recoveryNotes, !recovery.isEmpty {
                profileLines.append("Recovery pattern: \(recovery)")
            }
            if let style = program.coachingStyle, !style.isEmpty {
                profileLines.append("Coaching preference: \(style)")
            }
            if let custom = program.customCoachNotes, !custom.isEmpty {
                profileLines.append("Additional context: \(custom)")
            }
            if !profileLines.isEmpty {
                prompt += "Lifestyle & coaching context:\n"
                for line in profileLines {
                    prompt += "- \(line)\n"
                }
                prompt += "\nIMPORTANT: Account for the user's other activities when programming. For example, if they boulder on certain days, reduce grip/forearm/pulling volume on adjacent training days. Adjust intensity and exercise selection to complement their full activity schedule.\n\n"
            }
        }

        if let health = healthContext {
            prompt += "Today's recovery data:\n"
            if let sleep = health.sleepHours { prompt += "- Sleep last night: \(String(format: "%.1f", sleep)) hours\n" }
            if let hr = health.restingHR { prompt += "- Resting HR: \(Int(hr)) bpm\n" }
            if let hrv = health.hrv { prompt += "- HRV (SDNN): \(Int(hrv)) ms\n" }
            if let weight = health.bodyWeight { prompt += "- Body weight: \(Int(weight)) lbs\n" }
            prompt += "\n"
        }

        prompt += """
        Coaching principles:
        - Focus on LAST WEEK's data. What did the user actually do? What's recovering? What needs more volume?
        - Progressive overload: small, consistent weight increases session to session. Compare to last time this exercise was done.
        - Volume drives hypertrophy. Aim for adequate weekly sets per muscle group but don't enforce rigid targets.
        - Recovery is non-negotiable. Adjust based on sleep, HR, subjective feel, and non-lifting activities.
        - Failed reps (logged as X.5) mean the weight was at the limit. Don't increase until all target reps are clean.
        - When in doubt, be conservative. A slightly easy session beats an injury.
        - DO NOT reference mesocycles, blocks, or periodization phases. Just program based on what happened last week and how the user feels today.
        - Always suggest specific weights based on the user's recent history. Never return 0 for exercises they've done before.
        """

        return prompt
    }

    // MARK: - Recommend Focus (Sonnet — "What should I train today?")

    static func recommendFocusPrompt(
        recentSessionsSummary: String,
        recentActivities: String,
        feeling: Int,
        soreness: String?,
        program: TrainingProgram?,
        healthContext: HealthContext?
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: healthContext)
        system += """

        TASK: Recommend which muscle groups the user should train today.

        Analyze their recovery status per muscle group based on:
        - When each muscle was last trained and with how much volume
        - Any non-lifting activities (climbing fatigues forearms, back, biceps, finger flexors)
        - Sleep, HR, HRV data
        - Their subjective feeling and soreness
        - How many training days remain this week

        Recovery guidelines:
        - Compounds (squats, bench, rows): 48-72h recovery
        - Isolation: 24-48h recovery
        - Climbing: fatigues forearms (48h), back/biceps (24-36h), shoulders (24h)
        - Cardio: minimal muscle fatigue unless high intensity
        - Poor sleep (<6h) or low HRV: add 12-24h to all recovery estimates

        Respond with this JSON:
        {
          "muscleGroupStatus": [
            {"muscleGroup": "chest", "status": "fresh|ready|recovering|sore", "daysSinceTraining": 3.5, "weeklySetsDone": 8, "note": "optional context"},
            ...for all: chest, back, shoulders, biceps, triceps, forearms, quads, hamstrings, glutes, calves, core
          ],
          "recommendedFocus": ["quads", "hamstrings", "shoulders"],
          "recommendedSessionName": "Heavy Legs + Rear Delts",
          "reasoning": "2-3 sentence explanation of why this focus makes sense today"
        }
        """

        var user = "What should I train today?\n\n"
        user += "How I feel: \(feeling)/5\n"
        if let soreness = soreness, !soreness.isEmpty {
            user += "Soreness/concerns: \(soreness)\n"
        }
        user += "\nRecent training (last 7 days):\n\(recentSessionsSummary)\n"
        if !recentActivities.isEmpty {
            user += "\nOther activities (from Apple Health):\n\(recentActivities)\n"
        }
        user += "\nToday is \(Date().weekdayName)."

        return (system: system, user: user)
    }

    // MARK: - Touchpoint 1: Goal Setting

    static func goalSettingPrompt(
        goal: TrainingGoal,
        specificTargets: String?,
        daysPerWeek: Int,
        experience: ExperienceLevel,
        injuries: String?,
        equipment: EquipmentAccess
    ) -> (system: String, user: String) {
        let system = """
        You are a strength training coach designing a training program.
        You respond ONLY in JSON matching this schema:
        {"program":{"name":"string","split":["string"],"weeklySchedule":{"monday":"string",...},"periodization":"string","deloadFrequency":"string","focusAreas":["string"],"weeklyVolumeTargets":{"muscleGroup":{"sets":int,"repRange":"string"}},"compoundPriority":["string"],"progressionScheme":{"compounds":"string","isolation":"string"},"notes":"string"}}
        """

        var user = """
        Design a training program:
        - Primary goal: \(goal.displayName)
        - Days per week: \(daysPerWeek)
        - Experience level: \(experience.displayName)
        - Equipment: \(equipment.displayName)
        """
        if let targets = specificTargets, !targets.isEmpty {
            user += "\n- Specific targets: \(targets)"
        }
        if let injuries = injuries, !injuries.isEmpty {
            user += "\n- Injuries/limitations: \(injuries)"
        }
        user += "\n\nDesign a Push/Pull/Legs program with weekly volume targets per muscle group, compound priority order, and progression scheme."

        return (system, user)
    }

    // MARK: - Touchpoint 2: Daily Plan

    static func dailyPlanPrompt(
        category: WorkoutCategory,
        feeling: Int,
        availableTime: Int,
        concerns: String?,
        availableExercises: [String],
        recentSessionsSummary: String,
        program: TrainingProgram?,
        weeklyVolumeProgress: String
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: nil)
        system += """

        Respond with this JSON schema:
        {"exercises":[{"name":"string","sets":int,"targetReps":"string","suggestedWeight":double,"repScheme":"string?","warmupSets":[{"weight":double,"reps":int}]?,"notes":"string?","intent":"primary compound|secondary compound|isolation|finisher"}],"sessionStrategy":"string","estimatedDuration":int,"deloadNote":"string?"}
        """

        var user = """
        Generate today's \(category.displayName) workout plan.

        Pre-workout check-in:
        - Feeling: \(feeling)/5
        - Available time: \(availableTime) minutes
        """
        if let concerns = concerns, !concerns.isEmpty {
            user += "\n- Concerns: \(concerns)"
        }

        user += "\n\nAvailable exercises: \(availableExercises.joined(separator: ", "))"
        user += "\n\nRecent sessions:\n\(recentSessionsSummary)"
        user += "\n\nWeekly volume progress:\n\(weeklyVolumeProgress)"

        return (system, user)
    }

    // MARK: - Touchpoint 3: Mid-Workout Adapt

    static func midWorkoutAdaptPrompt(
        originalPlan: String,
        completedSoFar: String,
        remaining: String,
        reason: String,
        details: String?
    ) -> (system: String, user: String) {
        let system = """
        You are a coach adjusting a workout mid-session. Respond ONLY in JSON:
        {"exercises":[{"name":"string","sets":int,"targetReps":"string","suggestedWeight":double,"notes":"string?","intent":"string?"}],"rationale":"string"}
        """

        var user = """
        Adjust the remaining workout.

        Original plan: \(originalPlan)
        Completed so far: \(completedSoFar)
        Remaining: \(remaining)
        Reason for change: \(reason)
        """
        if let details = details {
            user += "\nDetails: \(details)"
        }

        return (system, user)
    }

    // MARK: - Touchpoint 4: Post-Workout Analysis

    static func postWorkoutAnalysisPrompt(
        planSummary: String?,
        actualWorkout: String,
        recentSessionsSummary: String,
        program: TrainingProgram?,
        healthContext: HealthContext?
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: healthContext)
        system += """

        Analyze this workout. Respond ONLY in JSON:
        {"summary":"string","performanceVsplan":{"adherence":double,"notes":"string"}?,"progressionEvents":[{"exercise":"string","type":"rep_pr|weight_pr|plateau|regression","detail":"string","recommendation":"string"}],"volumeAnalysis":{"muscleGroup":{"actual":int,"weeklyTarget":int,"weeklyActual":int,"status":"string"}}?,"recoveryNotes":"string?","overallRating":"pr_day|good|average|recovery","coachNote":"string"}
        """

        var user = "Analyze this workout session:\n\n"
        if let plan = planSummary {
            user += "Planned:\n\(plan)\n\n"
        }
        user += "Actual:\n\(actualWorkout)\n\n"
        user += "Recent history:\n\(recentSessionsSummary)"

        return (system, user)
    }

    // MARK: - Touchpoint 5: Weekly Review

    static func weeklyReviewPrompt(
        sessionsSummary: String,
        program: TrainingProgram?,
        previousWeeksSummary: String,
        healthContext: HealthContext?
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: healthContext)
        system += """

        Generate a weekly training review. Respond ONLY in JSON:
        {"weekSummary":{"sessionsCompleted":int,"sessionsPlanned":int,"totalVolume":double,"totalDuration":double,"avgFeeling":double},"goalProgress":[{"goal":"string","metric":"string","current":double,"previous":double,"trend":"string","projection":"string"}]?,"weeklyVolumeCompliance":{"muscleGroup":{"target":int,"actual":int,"status":"string"}}?,"strengthTrends":[{"exercise":"string","e1rm_4wk_ago":double,"e1rm_now":double,"trend":"string"}]?,"programAdjustments":[{"type":"string","detail":"string","priority":"string"}]?,"recoveryReport":{"avgSleep":double,"sleepTrend":"string","avgRestingHR":double,"restingHRTrend":"string","note":"string"}?,"coachNote":"string"}
        """

        var user = "Weekly review for this week's training:\n\n"
        user += "This week's sessions:\n\(sessionsSummary)\n\n"
        user += "Previous weeks:\n\(previousWeeksSummary)"

        return (system, user)
    }
}
