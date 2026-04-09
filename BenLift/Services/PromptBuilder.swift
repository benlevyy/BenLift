import Foundation

struct PromptBuilder {

    // MARK: - Shared System Prefix

    static func sharedSystemPrefix(program: TrainingProgram?, healthContext: HealthContext?, intelligence: UserIntelligence? = nil) -> String {
        var prompt = """
        You are a knowledgeable strength training coach who is encouraging, direct, and data-driven.
        You respond ONLY in JSON (no markdown, no backticks, no explanation outside the JSON).

        TRAINING CONTEXT:
        The user trains for hypertrophy and intentionally pushes to failure (RPE 9-10). This is a deliberate strategy, not a problem. Bodyweight exercises are logged with weight = 0 or "BW" — this is normal for dips, pull-ups, push-ups, etc.

        """

        if let program {
            prompt += """
            User profile:
            - Goal: \(program.goal)
            - Experience: \(program.experienceLevel)
            - Training days/week: \(program.daysPerWeek)

            """
        }

        // Intelligence — data-driven user context (replaces manual coaching profile)
        if let intel = intelligence, intel.hasBeenRefreshed {
            prompt += "User intelligence (data-driven, auto-generated):\n"
            prompt += intel.formattedForPrompt
            prompt += "\n\n"
        } else if let intel = intelligence {
            // Before first refresh, still include user-provided safety info
            if !intel.injuries.isEmpty {
                prompt += "INJURIES/CONCERNS (user-reported): \(intel.injuries)\n"
            }
            if !intel.userNotes.isEmpty {
                prompt += "User notes: \(intel.userNotes)\n"
            }
            if !intel.pendingObservations.isEmpty {
                prompt += "Observations from recent workouts:\n\(intel.pendingObservations)\n"
            }
            prompt += "\n"
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
        COACHING TONE:
        - Lead with what the user did well. Acknowledge effort and intensity before any suggestions.
        - Use collaborative language: "we could try..." or "one option next time..." — not "you need to" or "you should have."
        - Aim for roughly 3:1 positive-to-corrective ratio. Limit corrective feedback to ONE item per session.
        - Be specific — reference exact weights, reps, and exercises from the data. Never give generic advice.

        DATA INTERPRETATION RULES:
        - "BW" or weight=0 means bodyweight exercise. This is normal (dips, pull-ups, etc.). Never flag it as missing data.
        - Failed reps (X.5, e.g. 7.5 = 7 full reps + 1 failed attempt) mean the user pushed to muscular failure ON PURPOSE. This is positive for hypertrophy. Only flag failure if set 1 regresses below previous session's set 1 at the same weight.
        - Rep drop-off across sets (e.g. 10, 8, 6) is expected and good — it means high effort per set. Do NOT treat this as fatigue, form breakdown, or a problem.
        - Only cite trends or patterns if you have 3+ comparable data points. Do not invent trends from 1-2 sessions.

        PROGRAMMING PRINCIPLES:
        - Focus on LAST WEEK's actual data. What did the user do? What's recovering? What needs volume?
        - Progressive overload: track reps at the same weight as progress, not just weight on the bar. Adding a rep at the same weight IS progressive overload.
        - Volume drives hypertrophy. Aim for adequate weekly sets per muscle group but don't enforce rigid targets.
        - Recovery is non-negotiable. Adjust based on sleep, HR, subjective feel, and full activity schedule.
        - Be conservative on weight increases. A slightly easy session beats an injury.
        - DO NOT reference mesocycles, blocks, or periodization phases. Program based on what happened last week and how the user feels today.
        - Always suggest specific weights based on recent history. Never return 0 for exercises they've done before.
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
        healthContext: HealthContext?,
        intelligence: UserIntelligence? = nil
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: healthContext, intelligence: intelligence)
        system += """

        TASK: Recommend which muscle groups the user should train today.

        Analyze their recovery status per muscle group based on:
        - When each muscle was last trained and with how much volume
        - Any non-lifting activities listed below (estimate recovery impact based on the specific activity type and timing)
        - Sleep, HR, HRV data
        - Their subjective feeling and soreness
        - How many training days remain this week
        - The user's known recovery profile (from intelligence data, if available)

        Recovery guidelines:
        - Use the user's actual recovery patterns from intelligence data when available
        - Default estimates if no intelligence: compounds 48-72h, isolation 24-48h
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
        user += "\nToday is \(Date().weekdayName), \(Date().shortFormatted). Use this date to calculate how many days ago each session and activity was."

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
        availableTime: Int?,
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
        """
        if let time = availableTime {
            user += "\n- Available time: \(time) minutes"
        }
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
        healthContext: HealthContext?,
        pendingObservations: String?
    ) -> (system: String, user: String) {
        var system = sharedSystemPrefix(program: program, healthContext: healthContext)
        system += """

        Analyze this workout. Structure your response as:
        1. summary: one-sentence headline of the session (lead with the positive)
        2. progressionEvents: only include if there's a genuine PR, plateau (3+ sessions same weight/reps), or regression (set 1 dropped below previous session). Do NOT flag normal rep drop-off across sets.
        3. overallRating: pr_day (any PR), good (solid effort/volume), average (maintenance), recovery (low intensity day)
        4. coachNote: 2-3 sentences. Start with what went well. End with ONE specific, actionable suggestion for next time. Use "we" language.
        5. observations: 0-3 items. Only NEW information worth tracking:
           - Working weight changes vs previous sessions
           - Recovery patterns with 3+ data points supporting them
           - Exercise preferences (consistently picked or avoided across multiple sessions)
           Do NOT note: rep drop-off across sets, training to failure, single-session patterns, or anything obvious from the numbers alone.

        Respond ONLY in JSON:
        {"summary":"string","progressionEvents":[{"exercise":"string","type":"rep_pr|weight_pr|plateau|regression","detail":"one line","recommendation":"one line"}],"overallRating":"pr_day|good|average|recovery","coachNote":"string","observations":["string"]}
        """

        var user = "Analyze this workout session:\n\n"
        if let plan = planSummary {
            user += "Planned:\n\(plan)\n\n"
        }
        user += "Actual:\n\(actualWorkout)\n\n"
        user += "Recent history:\n\(recentSessionsSummary)"

        if let pending = pendingObservations, !pending.isEmpty {
            user += "\n\nPending observations from recent workouts:\n\(pending)"
        }

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

    // MARK: - Intelligence Refresh (Sonnet — analyze all data into structured profile)

    static func refreshIntelligencePrompt(
        program: TrainingProgram?,
        activitiesText: String,
        healthAverages: String,
        sessionsSummary: String,
        pendingObservations: String
    ) -> (system: String, user: String) {
        let system = """
        You are analyzing a strength training user's data to build a comprehensive intelligence profile.
        You respond ONLY in JSON (no markdown, no backticks).

        Analyze all provided data and produce a structured profile with these sections:

        1. activityPatterns — What non-lifting activities do they do? When? How often? Be specific about days and frequency. If no non-lifting activities appear in the data, say "No non-lifting activities detected in recent data."

        2. trainingPatterns — How often do they lift? What structure (PPL, upper/lower, full body, etc.)? Average session duration? Typical number of exercises? Which days of the week? Any patterns in consistency?

        3. strengthProfile — Key compound lift numbers with e1RM estimates. Progression rates (lbs/month on main lifts). Note any lifts that are stalling or regressing. Keep to the 4-6 most important exercises.

        4. recoveryProfile — Average sleep duration and trend. HRV baseline and trend. Resting HR baseline and trend. How long they typically need between sessions for the same muscle group (based on actual performance data, not assumptions). Note any recovery red flags.

        5. exercisePreferences — Which exercises do they consistently pick? Which do they avoid or drop? Any equipment preferences? Do they tend toward compounds or isolation? Note exercise rotation patterns.

        6. notableObservations — Cross-cutting insights: performance correlations (e.g., better after rest days), problem patterns (e.g., grip gives out before back on heavy rows), or anything else that doesn't fit the above categories.

        Rules:
        - Base EVERYTHING on the data provided. Do not invent patterns that aren't supported by evidence.
        - Each section should be 2-4 concise sentences.
        - Use specific numbers (weights, dates, frequencies) not vague language.
        - If a section has insufficient data, write "Insufficient data" — do not fabricate.
        - Fold in any pending observations from previous workouts, keeping what's still relevant and discarding what's been superseded by newer data.

        Respond ONLY in JSON:
        {"activityPatterns":"string","trainingPatterns":"string","strengthProfile":"string","recoveryProfile":"string","exercisePreferences":"string","notableObservations":"string"}
        """

        var user = "Build an intelligence profile from this data.\n\n"

        if let program {
            user += """
            USER CONTEXT:
            - Goal: \(program.goal)
            - Experience: \(program.experienceLevel)
            - Training days/week target: \(program.daysPerWeek)

            """
        }

        if !activitiesText.isEmpty {
            user += "HEALTHKIT ACTIVITIES (last 30 days):\n\(activitiesText)\n\n"
        } else {
            user += "HEALTHKIT ACTIVITIES: None detected.\n\n"
        }

        if !healthAverages.isEmpty {
            user += "HEALTH METRICS (30-day averages):\n\(healthAverages)\n\n"
        }

        user += "TRAINING SESSIONS (recent):\n\(sessionsSummary)\n\n"

        if !pendingObservations.isEmpty {
            user += "PENDING OBSERVATIONS (from recent workouts, not yet synthesized):\n\(pendingObservations)\n\n"
        }

        user += "Synthesize all of this into the 6 intelligence sections."

        return (system: system, user: user)
    }
}
