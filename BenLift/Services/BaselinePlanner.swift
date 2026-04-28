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

        // Cut total budget on low-readiness days. Floor at 4.
        let workingSetBudget: Int = {
            guard lowReadiness else { return input.targetWorkingSets }
            let cut = Int((Double(input.targetWorkingSets) * 0.6).rounded(.down))
            return max(4, cut)
        }()

        // Resolve targets — at least one. If the contract somehow gives us
        // an empty list, return an empty plan and let the UI surface the
        // error path. PlannerInput.build guards against this case upstream.
        let targets: [MuscleGroup] = input.targetMuscles.compactMap { MuscleGroup(rawValue: $0) }
        guard let primaryTarget = targets.first else {
            return DailyPlanResponse(exercises: [], sessionStrategy: "No target muscle set.", estimatedDuration: 0, deloadNote: nil)
        }

        let libByName = Dictionary(uniqueKeysWithValues: library.map { ($0.name, $0) })
        let injuryBlockers = injuryKeywordBlockers(input.constraints.injuries)
        let outSet = Set(input.constraints.exerciseOut)

        func isAllowed(_ name: String) -> Bool {
            if outSet.contains(name) { return false }
            if injuryBlockers.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            if lowReadiness && barbellCompoundNames.contains(name) { return false }
            return true
        }

        // Per-muscle set budget via primary-weighted distribution. 1 muscle:
        // all the sets. 2 muscles: 60/40. 3 muscles: 50/30/20. 4+: roughly
        // even. The primary muscle (targets.first) always gets the largest
        // share — its compound is the day's headline.
        let perMuscleBudget = distributeBudget(workingSetBudget, across: targets.count)

        // Pick exercises per target muscle. Each muscle gets ≥1 exercise.
        // Primary additionally gets isolation + finisher slots when budget
        // allows; secondary muscles get one compound + isolation if their
        // budget supports it.
        var picks: [PickWithMuscle] = []
        var usedNames = Set<String>()

        for (index, muscle) in targets.enumerated() {
            let muscleBudget = perMuscleBudget[index]
            let isPrimary = (index == 0)
            let muscleLibrary = library.filter { $0.muscleGroup == muscle && isAllowed($0.name) }

            // 1) Compound (ritual preferred). Marked primaryCompound only
            // for the day's lead muscle; everything else is secondary.
            if let compound = pickCompound(
                forMuscle: muscle,
                rituals: input.rituals,
                libByName: libByName,
                muscleLibrary: muscleLibrary,
                isAllowed: isAllowed,
                usedNames: usedNames,
                lowReadiness: lowReadiness
            ) {
                picks.append(PickWithMuscle(
                    exercise: compound,
                    intent: isPrimary ? .primaryCompound : .secondaryCompound,
                    muscle: muscle
                ))
                usedNames.insert(compound.name)
            }

            // 2) Isolation slot — only worth it when the muscle has at
            // least 4 sets in its share, otherwise the compound carries
            // the volume on its own.
            let isolationEquipment: Set<Equipment> = [.cable, .dumbbell, .machine]
            if muscleBudget >= 4,
               let iso = muscleLibrary.first(where: { ex in
                   !usedNames.contains(ex.name) && isolationEquipment.contains(ex.equipment)
               }) {
                picks.append(PickWithMuscle(exercise: iso, intent: .isolation, muscle: muscle))
                usedNames.insert(iso.name)
            }

            // 3) Finisher — primary muscle only, and only if its share is
            // big enough for a third exercise.
            let finisherEquipment: Set<Equipment> = [.cable, .bodyweight, .machine]
            if isPrimary, muscleBudget >= 7,
               let finisher = muscleLibrary.first(where: { ex in
                   !usedNames.contains(ex.name) && finisherEquipment.contains(ex.equipment)
               }) {
                picks.append(PickWithMuscle(exercise: finisher, intent: .finisher, muscle: muscle))
                usedNames.insert(finisher.name)
            }
        }

        // Distribute set counts within each muscle's slice. Inside a slice:
        // compound gets the most, isolation less, finisher least. Then
        // balance across the whole plan to match the total budget exactly
        // (rounding from the per-muscle distribution can leave us off ±1).
        var setCounts: [Int] = picks.map { _ in 1 }
        for (index, _) in targets.enumerated() {
            let muscleBudget = perMuscleBudget[index]
            let muscle = targets[index]
            let indices = picks.indices.filter { picks[$0].muscle == muscle }
            distributeWithinMuscle(&setCounts, indices: indices, budget: muscleBudget, intents: indices.map { picks[$0].intent })
        }
        // Final reconciliation against total — handles rounding drift.
        balanceSets(&setCounts, target: workingSetBudget)

        let planned: [PlannedExercise] = zip(picks, setCounts).map { pick, sets in
            buildPlannedExercise(
                pick: Pick(exercise: pick.exercise, intent: pick.intent),
                sets: sets,
                input: input,
                libByName: libByName,
                lowReadiness: lowReadiness
            )
        }

        let totalSets = setCounts.reduce(0, +)
        let restSec = preferredRestSeconds()
        let duration = 5 + Int((Double(totalSets) * (1.0 + Double(restSec) / 60.0)).rounded())

        let displayName = sessionDisplayName(for: targets, primary: primaryTarget)
        let strategy = "Hypertrophy session targeting \(displayName) — \(totalSets) working sets, compound-led."

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

// MARK: - Multi-target helpers

private extension BaselinePlanner {

    /// Like `Pick` but tagged with the target muscle that drove the slot,
    /// so we can distribute set budgets per muscle instead of per slot.
    struct PickWithMuscle {
        let exercise: Exercise
        let intent: ExerciseIntent
        let muscle: MuscleGroup
    }

    /// Primary-weighted set distribution.
    /// 1 muscle  → all sets to it.
    /// 2 muscles → 60/40 (primary heavier).
    /// 3 muscles → 50/30/20.
    /// 4+ muscles → roughly even split with leftover going to primary.
    static func distributeBudget(_ total: Int, across n: Int) -> [Int] {
        guard n > 0 else { return [] }
        switch n {
        case 1:
            return [total]
        case 2:
            let primary = Int((Double(total) * 0.6).rounded())
            return [primary, max(0, total - primary)]
        case 3:
            let primary = Int((Double(total) * 0.5).rounded())
            let second = Int((Double(total) * 0.3).rounded())
            return [primary, second, max(0, total - primary - second)]
        default:
            let base = total / n
            let rem = total - base * n
            // Leftover sets concentrate on the primary so it stays
            // recognisable as the day's lead.
            return (0..<n).map { i in i == 0 ? base + rem : base }
        }
    }

    /// Pick a compound for a specific muscle. Ritual hit > rotation hit >
    /// best library entry. Marked compound vs isolation by the caller's
    /// `intent`, not here.
    static func pickCompound(
        forMuscle muscle: MuscleGroup,
        rituals: [String],
        libByName: [String: Exercise],
        muscleLibrary: [Exercise],
        isAllowed: (String) -> Bool,
        usedNames: Set<String>,
        lowReadiness: Bool
    ) -> Exercise? {
        // Ritual that targets this muscle.
        if let ritualHit = rituals.first(where: { name in
            guard !usedNames.contains(name), isAllowed(name), let ex = libByName[name] else { return false }
            return ex.muscleGroup == muscle
        }), let ex = libByName[ritualHit] {
            return ex
        }
        // Library compound — barbell/dumbbell preferred normally; machine/
        // cable preferred on low-readiness days.
        let preferred: [Equipment] = lowReadiness ? [.machine, .cable, .dumbbell] : [.barbell, .dumbbell, .machine]
        for eq in preferred {
            if let hit = muscleLibrary.first(where: { $0.equipment == eq && !usedNames.contains($0.name) }) {
                return hit
            }
        }
        return muscleLibrary.first(where: { !usedNames.contains($0.name) })
    }

    /// Within one muscle's slice, distribute its budget across its picks.
    /// Compound gets the lion's share; isolation half of that; finisher the
    /// remainder. Mutates `setCounts` in place by index.
    static func distributeWithinMuscle(
        _ setCounts: inout [Int],
        indices: [Int],
        budget: Int,
        intents: [ExerciseIntent]
    ) {
        guard !indices.isEmpty, budget > 0 else { return }
        // Initial allocation by intent weight.
        let weights: [Double] = intents.map { intent in
            switch intent {
            case .primaryCompound:   return 1.0
            case .secondaryCompound: return 0.85
            case .isolation:         return 0.55
            case .finisher:          return 0.35
            }
        }
        let weightSum = weights.reduce(0, +)
        var allocated = 0
        for (slot, idx) in indices.enumerated() {
            let share = Int((Double(budget) * weights[slot] / weightSum).rounded())
            setCounts[idx] = max(1, share)
            allocated += setCounts[idx]
        }
        // Reconcile against the muscle's budget — push remainder onto the
        // first slot (the compound).
        if allocated != budget, let first = indices.first {
            setCounts[first] += (budget - allocated)
            if setCounts[first] < 1 { setCounts[first] = 1 }
        }
    }

    /// Best-fit name for the session header.
    /// Matches canonical presets first ("Push" / "Pull" / "Legs" / "Upper"
    /// / "Lower"), then "Chest + Shoulders" for two-muscle days, falls back
    /// to the primary muscle's name.
    static func sessionDisplayName(for targets: [MuscleGroup], primary: MuscleGroup) -> String {
        let s = Set(targets)
        if s == Set([.chest, .shoulders, .triceps]) { return "Push" }
        if s == Set([.back, .biceps]) { return "Pull" }
        if s == Set([.quads, .hamstrings, .glutes, .calves]) { return "Legs" }
        if s == Set([.chest, .back, .shoulders, .biceps, .triceps]) { return "Upper" }
        if targets.count == 2 {
            return "\(targets[0].displayName) + \(targets[1].displayName)"
        }
        return primary.displayName
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
