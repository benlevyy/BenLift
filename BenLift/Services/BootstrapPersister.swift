import Foundation
import SwiftData

// MARK: - BootstrapPersister
//
// Writes a `BootstrapResponse` (one-time onboarding LLM output) to SwiftData.
// Two effects:
//
//   1. Active `TrainingProgram` row — find or create, update name/goal/
//      experience/daysPerWeek + carry-over fields from the bootstrap response
//      (split / progression scheme / weekly volume targets, when present).
//      Marks any other programs `isActive = false` so the active-program
//      query stays unique.
//
//   2. `SeedPattern` rows — one per weekday, derived from
//      `response.weeklyPattern` (a [String: String] keyed by lowercase
//      weekday names). Previous SeedPatterns are wiped first so re-running
//      onboarding refreshes rather than duplicating.
//
// Fields like `rotationPerMuscle`, `weeklyVolumeTargets`, `progressionScheme`,
// `ruleOuts`, and `rationale` are partially used today (volume + progression
// land on TrainingProgram); the rotation map will be wired into the planner
// later. See TODO below.

@MainActor
struct BootstrapPersister {

    // MARK: - Public entry point

    static func persist(
        response: BootstrapResponse,
        input: BootstrapInput,
        modelContext: ModelContext
    ) {
        upsertProgram(response: response, input: input, modelContext: modelContext)
        replaceSeedPatterns(weeklyPattern: response.weeklyPattern, modelContext: modelContext)

        // TODO: wire response.rotationPerMuscle into the planner (per-muscle
        // exercise rotation seeds), and surface response.ruleOuts / rationale
        // in the program detail UI. Not strictly needed at onboarding time —
        // pattern engine + LLM planner can run without them.

        do {
            try modelContext.save()
            print("[BenLift/Bootstrap] ✅ Persisted program + \(response.weeklyPattern.count) weekday seeds")
        } catch {
            print("[BenLift/Bootstrap] ❌ Save failed: \(error)")
        }
    }

    // MARK: - TrainingProgram (find or create active row)

    private static func upsertProgram(
        response: BootstrapResponse,
        input: BootstrapInput,
        modelContext: ModelContext
    ) {
        // Mark any currently-active programs inactive — bootstrap always wins.
        let activeDescriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive == true }
        )
        let active = (try? modelContext.fetch(activeDescriptor)) ?? []

        // Reuse the first active row as our target (avoids leaving an empty
        // shell in the DB when the user re-runs onboarding). Mark the rest
        // inactive to keep the active-program invariant.
        let target: TrainingProgram
        if let existing = active.first {
            target = existing
            for other in active.dropFirst() {
                other.isActive = false
            }
        } else {
            target = TrainingProgram(
                name: response.programName,
                goal: input.goal,
                daysPerWeek: input.daysPerWeek
            )
            modelContext.insert(target)
        }

        // Apply the bootstrap response + onboarding inputs.
        target.name = response.programName
        target.goal = input.goal
        target.experienceLevel = input.experience
        target.daysPerWeek = input.daysPerWeek
        target.isActive = true

        // Bootstrap split lives on the response as a single token
        // ("upper_lower", "ppl", …). The legacy `TrainingProgram.split` is a
        // weekday-ordered [String] used by `todayCategory()` — we don't
        // overwrite it from the bootstrap split token (different shape),
        // since the SeedPattern rows are the new source of truth for daily
        // muscle targeting. Leave existing `split` alone.

        // Carry over fields that DO map cleanly so the program detail UI has
        // something to show. BootstrapVolumeTarget has `sets` + `rationale`,
        // so synthesize a VolumeTarget with the rationale stuffed into
        // repRange (best-effort — the planner doesn't read this field
        // directly today, it's display-only).
        var legacyVolume: [String: VolumeTarget] = [:]
        for (muscle, bvt) in response.weeklyVolumeTargets {
            legacyVolume[muscle] = VolumeTarget(sets: bvt.sets, repRange: bvt.rationale)
        }
        target.weeklyVolumeTargets = legacyVolume

        target.progressionScheme = [
            "compounds": response.progressionScheme.compounds,
            "isolation": response.progressionScheme.isolation,
        ]
    }

    // MARK: - SeedPattern rows

    /// Wipe existing SeedPattern rows and write fresh ones from the bootstrap
    /// weeklyPattern map. Each weekday gets a row even when the value is
    /// "rest" or unparseable — a row with `muscleGroup = nil` tells the strip
    /// the day is intentionally rest (vs. unknown / not-yet-bootstrapped).
    private static func replaceSeedPatterns(
        weeklyPattern: [String: String],
        modelContext: ModelContext
    ) {
        // Delete previous bootstrap-source seeds. Keep `userEdit` rows alive
        // so manual weekday overrides survive a re-bootstrap. (Per the model
        // doc, userEdit comes from settings, not onboarding.)
        let existing = (try? modelContext.fetch(FetchDescriptor<SeedPattern>())) ?? []
        for row in existing where row.source == .bootstrap {
            modelContext.delete(row)
        }

        for (rawWeekday, rawValue) in weeklyPattern {
            guard let weekday = Self.calendarWeekday(from: rawWeekday) else {
                print("[BenLift/Bootstrap] Unknown weekday in pattern: \(rawWeekday)")
                continue
            }

            // Multi-muscle: parse the full comma list so push days seed
            // [chest, shoulders, triceps] rather than dropping all but the
            // first. Empty list = rest day.
            let muscles = Self.parseMuscleList(from: rawValue)
            let row = SeedPattern(
                weekday: weekday,
                muscleGroups: muscles,
                source: .bootstrap
            )
            modelContext.insert(row)
        }
    }

    // MARK: - Parsing helpers

    /// Lowercase weekday string → Calendar.component(.weekday) integer
    /// (1=Sun … 7=Sat). Returns nil for unrecognized strings so the caller
    /// can skip rather than write a row at the wrong index.
    private static func calendarWeekday(from raw: String) -> Int? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "sunday", "sun": return 1
        case "monday", "mon": return 2
        case "tuesday", "tue", "tues": return 3
        case "wednesday", "wed": return 4
        case "thursday", "thu", "thurs": return 5
        case "friday", "fri": return 6
        case "saturday", "sat": return 7
        default: return nil
        }
    }

    /// Parse the full muscle list from a comma string like
    /// "chest, shoulders, triceps". Returns [] for "rest" / empty / no
    /// match so the caller writes a rest-day row.
    static func parseMuscleList(from raw: String) -> [MuscleGroup] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "rest", trimmed != "off" else { return [] }

        var out: [MuscleGroup] = []
        var seen: Set<MuscleGroup> = []
        for token in trimmed.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != "rest", t != "off" else { continue }
            if let m = matchMuscle(token: t), !seen.contains(m) {
                out.append(m)
                seen.insert(m)
            }
        }
        return out
    }

    /// Map a single muscle token to a MuscleGroup. Exact rawValue match
    /// first, then case-insensitive substring.
    private static func matchMuscle(token: String) -> MuscleGroup? {
        if let direct = MuscleGroup(rawValue: token) { return direct }
        for mg in MuscleGroup.allCases {
            let rv = mg.rawValue.lowercased()
            if token.contains(rv) || rv.contains(token) {
                return mg
            }
        }
        return nil
    }
}
