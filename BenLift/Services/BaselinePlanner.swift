import Foundation

// MARK: - BaselinePlanner
//
// Deterministic, LLM-free planner. Given a fully-built `PlannerInput` and the
// current `Exercise` library, returns a `DailyPlanResponse` shaped exactly
// like the LLM path so callers don't branch on which producer ran.
//
// This is the cheap baseline that handles the routine-day case for free.
// Anything weirder (injury phrasing the keyword filter doesn't catch, novel
// exercise the user has never done, etc.) is intentionally left to the LLM
// escalation — the rules here stay boring on purpose.

struct BaselinePlanner {

    static func plan(input: PlannerInput, library: [Exercise]) -> DailyPlanResponse {
        let lowReadiness = isLowReadiness(input.recovery)

        // Cut budget on low-readiness days. Floor at 4 sets so we never plan a
        // session that's not worth showing up for.
        let workingSetBudget: Int = {
            guard lowReadiness else { return input.targetWorkingSets }
            let cut = Int((Double(input.targetWorkingSets) * 0.6).rounded(.down))
            return max(4, cut)
        }()

        let targetMG = MuscleGroup(rawValue: input.targetMuscle)
        let libByName = Dictionary(uniqueKeysWithValues: library.map { ($0.name, $0) })

        // Hard rule-outs: explicit user rules + injury keyword inference.
        let injuryBlockers = injuryKeywordBlockers(input.constraints.injuries)
        let outSet = Set(input.constraints.exerciseOut)

        func isBarbellCompound(_ name: String) -> Bool {
            barbellCompoundNames.contains(name)
        }

        func isAllowed(_ name: String) -> Bool {
            if outSet.contains(name) { return false }
            if injuryBlockers.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            // Low-readiness days: drop barbell compounds; they get substituted
            // via library lookup further down.
            if lowReadiness && isBarbellCompound(name) { return false }
            return true
        }

        // Library entries scoped to the target muscle, used both for filling
        // gaps and for substituting blocked barbell compounds.
        let targetLibrary: [Exercise] = library.filter {
            guard let mg = targetMG else { return false }
            return $0.muscleGroup == mg && isAllowed($0.name)
        }

        // 1) Primary compound: prefer a ritual that hits the target muscle.
        var picks: [Pick] = []
        var usedNames = Set<String>()

        if let primary = pickPrimary(
            rituals: input.rituals,
            libByName: libByName,
            targetMG: targetMG,
            targetLibrary: targetLibrary,
            isAllowed: isAllowed,
            lowReadiness: lowReadiness
        ) {
            picks.append(Pick(exercise: primary, intent: .primaryCompound))
            usedNames.insert(primary.name)
        }

        // 2) Secondary: rotation entries for the target muscle (1–2).
        let rotationNames = input.rotation[input.targetMuscle] ?? []
        for name in rotationNames where picks.filter({ $0.intent == .secondaryCompound }).count < 2 {
            guard !usedNames.contains(name), isAllowed(name), let ex = libByName[name] else { continue }
            // Skip pure isolation-shaped rotation entries when we already have
            // a primary; they belong in the isolation slot.
            picks.append(Pick(exercise: ex, intent: .secondaryCompound))
            usedNames.insert(name)
        }

        // Fill secondary from library if rotation came up empty.
        if !picks.contains(where: { $0.intent == .secondaryCompound }) {
            if let secondary = targetLibrary.first(where: {
                !usedNames.contains($0.name) && $0.equipment != .bodyweight
            }) {
                picks.append(Pick(exercise: secondary, intent: .secondaryCompound))
                usedNames.insert(secondary.name)
            }
        }

        // 3) Isolation: prefer cable/dumbbell same-muscle work.
        if let iso = targetLibrary.first(where: {
            !usedNames.contains($0.name) && ($0.equipment == .cable || $0.equipment == .dumbbell || $0.equipment == .machine)
        }) {
            picks.append(Pick(exercise: iso, intent: .isolation))
            usedNames.insert(iso.name)
        }

        // 4) Finisher: another isolation, ideally cable/bodyweight high-rep.
        if let finisher = targetLibrary.first(where: {
            !usedNames.contains($0.name) && ($0.equipment == .cable || $0.equipment == .bodyweight || $0.equipment == .machine)
        }) {
            picks.append(Pick(exercise: finisher, intent: .finisher))
            usedNames.insert(finisher.name)
        }

        // Distribute set counts: 3/3/2/1 baseline → adjust to match budget.
        var setCounts = defaultSetCounts(for: picks)
        balanceSets(&setCounts, target: workingSetBudget)

        // Build PlannedExercise objects in canonical order.
        let planned: [PlannedExercise] = zip(picks, setCounts).map { pick, sets in
            buildPlannedExercise(
                pick: pick,
                sets: sets,
                input: input,
                libByName: libByName,
                lowReadiness: lowReadiness
            )
        }

        let totalSets = setCounts.reduce(0, +)
        let restSec = preferredRestSeconds()
        let duration = 5 + Int((Double(totalSets) * (1.0 + Double(restSec) / 60.0)).rounded())

        let muscleDisplay = targetMG?.displayName ?? input.targetMuscle.capitalized
        let strategy = "Hypertrophy session targeting \(muscleDisplay) — \(totalSets) working sets, compound-led."

        let deload: String? = lowReadiness
            ? "Low readiness detected — barbell compounds swapped for machine/cable variants and weights pulled back ~10%."
            : nil

        return DailyPlanResponse(
            exercises: planned,
            sessionStrategy: strategy,
            estimatedDuration: duration,
            deloadNote: deload
        )
    }
}

// MARK: - Internal helpers

private extension BaselinePlanner {

    struct Pick {
        let exercise: Exercise
        let intent: ExerciseIntent
    }

    /// Names the low-readiness substitution rule is allowed to drop. Listed
    /// explicitly rather than guessed-from-equipment because the rule wants
    /// "spinal-loaded barbell movements", not just "anything with a barbell".
    static var barbellCompoundNames: Set<String> {
        ["Squat", "Front Squat", "Deadlift", "Romanian Deadlift",
         "Overhead Press", "Bench Press", "Incline Barbell Press"]
    }

    static func isLowReadiness(_ r: PlannerInput.Recovery) -> Bool {
        if r.feeling <= 2 { return true }
        if let hrv = r.hrv, let sleep = r.sleepHours, hrv < 40 && sleep < 6 {
            return true
        }
        return false
    }

    /// Map free-text injury notes to the small set of substring blockers we
    /// honor without an LLM. Conservative on purpose — anything more nuanced
    /// belongs in the escalation path.
    static func injuryKeywordBlockers(_ injuries: String?) -> [String] {
        guard let raw = injuries?.lowercased(), !raw.isEmpty else { return [] }
        var blockers: [String] = []
        if raw.contains("shoulder") {
            blockers.append(contentsOf: ["Overhead Press", "Shoulder Press"])
        }
        if raw.contains("knee") {
            blockers.append(contentsOf: ["Squat", "Lunge", "Split Squat"])
        }
        if raw.contains("back") {
            blockers.append(contentsOf: ["Deadlift", "Romanian Deadlift", "Good Morning"])
        }
        return blockers
    }

    static func pickPrimary(
        rituals: [String],
        libByName: [String: Exercise],
        targetMG: MuscleGroup?,
        targetLibrary: [Exercise],
        isAllowed: (String) -> Bool,
        lowReadiness: Bool
    ) -> Exercise? {
        // Ritual that hits the target muscle and isn't blocked.
        if let mg = targetMG {
            if let ritualHit = rituals.first(where: { name in
                guard let ex = libByName[name] else { return false }
                return ex.muscleGroup == mg && isAllowed(name)
            }), let ex = libByName[ritualHit] {
                return ex
            }
        }
        // Otherwise the strongest compound-shaped library entry — barbell or
        // dumbbell — that survives the readiness/injury filters.
        let preferred: [Equipment] = lowReadiness ? [.machine, .cable, .dumbbell] : [.barbell, .dumbbell, .machine]
        for eq in preferred {
            if let hit = targetLibrary.first(where: { $0.equipment == eq }) {
                return hit
            }
        }
        return targetLibrary.first
    }

    /// Default 3/3/2/1 layout, trimmed to the picks we actually have.
    static func defaultSetCounts(for picks: [Pick]) -> [Int] {
        picks.map { pick in
            switch pick.intent {
            case .primaryCompound: return 3
            case .secondaryCompound: return 3
            case .isolation: return 2
            case .finisher: return 1
            }
        }
    }

    /// Push or pull set counts until the total matches budget exactly. We add
    /// to the primary first (per spec) and trim the finisher first.
    static func balanceSets(_ counts: inout [Int], target: Int) {
        guard !counts.isEmpty else { return }
        var total = counts.reduce(0, +)
        // Add to primary (index 0) when under budget.
        while total < target {
            counts[0] += 1
            total += 1
        }
        // Remove from the tail when over budget, never dropping below 1.
        while total > target {
            var trimmed = false
            for i in stride(from: counts.count - 1, through: 0, by: -1) where counts[i] > 1 {
                counts[i] -= 1
                total -= 1
                trimmed = true
                break
            }
            if !trimmed { break }
        }
    }

    static func buildPlannedExercise(
        pick: Pick,
        sets: Int,
        input: PlannerInput,
        libByName: [String: Exercise],
        lowReadiness: Bool
    ) -> PlannedExercise {
        let ex = pick.exercise
        let strengthEntry = input.strength[ex.name]
        let isBodyweight = ex.equipment == .bodyweight || (strengthEntry?.bodyweight ?? false)

        var note: String? = nil
        var weight: Double? = nil

        if isBodyweight {
            weight = nil
        } else if let s = strengthEntry, s.working > 0 {
            // +5 lb bump if trend is clearly positive — cheap progression nudge.
            let bump = s.trend4wk.hasPrefix("+") ? 5.0 : 0.0
            weight = s.working + bump
        } else if let def = ex.defaultWeight {
            weight = def
            note = "starting estimate — log RPE 8"
        }

        if lowReadiness, let w = weight {
            weight = (w * 0.9 / 5.0).rounded() * 5.0
        }

        let warmups: [WarmupSet]? = (pick.intent == .primaryCompound && !isBodyweight)
            ? buildWarmups(working: weight)
            : nil

        return PlannedExercise(
            name: ex.name,
            sets: sets,
            targetReps: repTarget(for: pick.intent),
            suggestedWeight: weight,
            repScheme: "straight",
            warmupSets: warmups,
            notes: note,
            intent: pick.intent.rawValue
        )
    }

    static func repTarget(for intent: ExerciseIntent) -> String {
        switch intent {
        case .primaryCompound: return "6-8"
        case .secondaryCompound: return "8-10"
        case .isolation: return "10-12"
        case .finisher: return "12-15"
        }
    }

    /// Two ramp sets at 40% and 70% of working weight, rounded to nearest 5.
    /// Skip entirely if working weight is missing or trivial (<= 45 lb bar).
    static func buildWarmups(working: Double?) -> [WarmupSet]? {
        guard let w = working, w > 45 else { return nil }
        func roundTo5(_ x: Double) -> Double { (x / 5.0).rounded() * 5.0 }
        return [
            WarmupSet(weight: roundTo5(w * 0.4), reps: 5),
            WarmupSet(weight: roundTo5(w * 0.7), reps: 5)
        ]
    }

    static func preferredRestSeconds() -> Int {
        let stored = UserDefaults.standard.double(forKey: "restTimerDuration")
        return stored > 0 ? Int(stored) : 150
    }
}
