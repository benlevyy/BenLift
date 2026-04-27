# BenLift Planner Architecture — Calendar + LLM Hybrid

**Audience:** the engineer (or agent) building the Week Strip UI, and the engineer wiring the planner pipeline. Lock the contracts here before either side ships, so the two workstreams don't drift.

**Status:** prompts validated in `evals/`. Calendar UI + Swift engine to be built. Last updated 2026-04-27.

---

## TL;DR

The current production code path has Claude do everything in one shot — pick the muscle, justify it, plan the workout. We're splitting that into three layers:

1. **Calendar (Swift, deterministic)** — the Week Strip. Decides which muscle to train each day from a 3-week rolling pattern, plus user pins. Owns the `targetMuscle` decision. Renders instantly, no LLM.
2. **Deterministic baseline planner (Swift)** — given the muscle, builds the workout from `strength[]`, `rituals`, `rotation[]`. Renders the default plan for free.
3. **LLM prompts (3 of them)** — fire only when actually needed:
   - `daily_plan_v5`: when the deterministic plan isn't safe enough (active injury, low readiness)
   - `bootstrap`: once at signup, designs the starter program that seeds calendar + rotation
   - `iterate`: user-triggered swaps / explanations / load adjusts

This brings per-user inference cost from ~$1–4/month (current) to ~$0.05–0.20/month (target), while *expanding* what the LLM does well — conversational iteration and onboarding — instead of just doing arithmetic on every render.

---

## Component Map

```
                            ┌──────────────────────────────────┐
                            │       Onboarding (one-time)      │
                            │  goal/days/equipment/cross-train │
                            │              │                   │
                            │              ▼                   │
                            │       LLM: bootstrap             │
                            │   → seeds program + calendar +   │
                            │     rotationPerMuscle            │
                            └──────────────┬───────────────────┘
                                           │
                                           ▼
       ┌──────────────────────────────────────────────────────────────┐
       │         Calendar / Week Strip (Swift, deterministic)         │
       │  Last 3 wks of completed sessions → modal muscle per weekday │
       │  + user-pinned future days → today's targetMuscle            │
       └────────┬───────────────────────────────────────────┬─────────┘
                │                                           │
                ▼                                           ▼
   ┌────────────────────────────┐             ┌──────────────────────────┐
   │ Deterministic baseline     │             │  Escalation conditions   │
   │ planner (Swift)            │             │  detected? (see below)   │
   │  rotation + strength +     │             └──────────┬───────────────┘
   │  recovery → default plan   │                        │ yes
   │  Renders instantly.        │                        ▼
   └────────┬───────────────────┘             ┌──────────────────────────┐
            │ no escalation                   │ LLM: daily_plan_v5       │
            ▼                                 │ Adjudicates safety,      │
   ┌────────────────────────────┐             │ anchors weights, returns │
   │ Render plan to user        │◄────────────│ full plan JSON           │
   └────────┬───────────────────┘             └──────────────────────────┘
            │
            ▼  user interaction
   ┌────────────────────────────┐
   │ User taps swap / why /     │
   │ prioritize / lighten       │
   │  →  LLM: iterate           │
   └────────────────────────────┘
```

---

## Week Strip — Data Model & Behavior

### Visual layout

80pt-tall horizontal scroller above the recommendation card on Today. Cells:
- **Past 3 days** (left): solid color, derived from completed `WorkoutSession` records.
- **Today** (center): accent color, may be a prediction OR a user pin.
- **Next 3–4 days** (right): faint if predicted, solid if user pinned.

### Cell data shape

```swift
struct WeekStripCell {
    let date: Date                      // calendar date for this cell
    let muscleGroup: String?            // nil = rest day or no signal
    let source: CellSource              // see enum
    let predictionConfidence: Double?   // 0.0–1.0, only when source = .predicted
}

enum CellSource {
    case completed   // historical, from WorkoutSession.muscleGroups
    case planned     // user generated a plan but hasn't logged yet
    case pinned      // user explicitly tapped to pin a future day
    case predicted   // derived from rolling 3-wk pattern
    case fallback    // sparse history, even-rotation default
}
```

### User interactions

- Tap a future cell → bottom sheet of muscle options → sets `pinned` for that date.
- Long-press today's cell → muscle picker → overrides today's prediction.
- Tap a past cell → opens that workout's history view (read-only).

### Persistence

- **Past cells**: derived live from `WorkoutSession` queries (no separate storage).
- **Pins**: new SwiftData entity `MuscleGroupPin { date, muscleGroup, createdAt }`. Deleted automatically once the date is in the past (or when a `WorkoutSession` is logged for that date).
- **Predictions**: NOT persisted. Recomputed on view appear from the pattern engine.

---

## Pattern Engine

Pure function, runs in Swift. No persisted state.

### Algorithm

```
inputs:
  sessions: [WorkoutSession] from last 21 days
  futurePins: [MuscleGroupPin] for any date >= today

for each upcoming weekday in [today, today+1, ..., today+6]:
  candidates = sessions where weekday matches AND date >= today - 21 days
  
  if a futurePin exists for this date:
    yield (date, pin.muscleGroup, .pinned, confidence: 1.0)
    continue
  
  if candidates.count >= 2:
    modal_muscle = mode of candidates.map(\.primaryMuscleGroup)
    confidence = candidates.filter { $0.primaryMuscleGroup == modal_muscle }.count / candidates.count
    yield (date, modal_muscle, .predicted, confidence)
  else if sessions.count > 0:
    // Sparse history — fall back to even rotation that hasn't been hit recently
    yield (date, leastRecentlyTrained(sessions), .fallback, confidence: 0.4)
  else:
    yield (date, nil, .fallback, confidence: nil)
```

### Confidence threshold

If the strip wants to show a prediction "softly" (lower opacity, italics), do so when `confidence < 0.6`. The `daily_plan_v5` prompt also reads `targetMuscleSource` and softens its language to "planning chest based on typical pattern" when source is `fallback`.

### Edge cases

- **First-time user (no sessions yet)**: bootstrap LLM seeds a `weeklyPattern` that gets saved as a `SeedPattern` entity. Until 3 real sessions are logged for a given weekday, the strip shows the seed pattern as `predicted` with `confidence: 0.5`. Once 3 real sessions for a weekday exist, the seed is ignored for that weekday — real data wins.
- **Deload week / vacation**: if `sessions.count` for the last 7 days is 0, strip shows entirely fallback predictions. User likely deloading; planner should not insist.

---

## Escalation: when does Swift call the LLM?

Default path: deterministic baseline planner generates today's plan from calendar + strength + rotation + recovery. **No LLM call.** Renders instantly.

LLM `daily_plan_v5` fires when ANY of these is true:

```swift
func shouldEscalate(state: PlannerInput) -> Bool {
    state.constraints.injuries != nil                    // active injury
    || state.recovery.feeling <= 2                        // user reports fried
    || (state.recovery.hrv != nil
        && hrvBaseline != nil
        && state.recovery.hrv! < hrvBaseline! - 1*hrvSD
        && state.recovery.sleepHours != nil
        && state.recovery.sleepHours! < 6)                // low readiness combo
    || isFirstSessionForThisMuscle(state)                 // no rituals yet
    || state.userOverrides.requestedAILead == true        // user tapped "let AI plan"
}
```

LLM `iterate` fires on ANY user interaction with the rendered plan:
- Tapping the swap-exercise button on a row
- Typing into the freeform "ask coach" field
- Tapping the "why this exercise?" affordance

LLM `bootstrap` fires:
- On first onboarding submission
- When user changes goals, days/week, or equipment in settings

Background tasks (out of the planner critical path):
- Weekly intelligence refresh: `refreshIntelligencePrompt` runs once/week, off the user's path
- Pattern engine recomputation: runs after every `WorkoutSession` save, in-process (no LLM)

---

## Input Contracts — exact shapes for each LLM call

### `daily_plan_v5` input

```typescript
{
  targetMuscle: "chest" | "back" | "shoulders" | "biceps" | "triceps"
              | "forearms" | "quads" | "hamstrings" | "glutes" | "calves" | "core",
  targetMuscleSource: "pinned" | "predicted" | "fallback",
  predictionConfidence: number | null,        // 0–1, null when source != "predicted"

  futurePins: { date: ISO8601Date, muscle: string }[],

  recentDays: {                                // last 3 completed sessions, oldest first
    date: ISO8601Date,
    muscle: string,                            // primary muscle group of that session
    totalVolume: number,                       // lbs
    topExercises: string[],                    // 3 most-set-count exercises
    effortScore: number,                       // 1–10, from session.feeling × 2 or RPE
    avgHR: number | null
  }[],

  recovery: {
    feeling: 1 | 2 | 3 | 4 | 5,                // user check-in
    sleepHours: number | null,                 // last night, HealthKit
    restingHR: number | null,                  // baseline, HealthKit
    hrv: number | null,                        // baseline, HealthKit (SDNN ms)
    daysSinceLastTraining: number,
    userNote: string | null                    // freeform "shoulder tight", etc.
  },

  availableTime: number,                       // minutes
  targetWorkingSets: number,                   // deterministic: (availableTime - 5) / (1 + restSec/60)

  strength: {
    [exerciseName: string]: {
      working: number,                         // most recent working-set top weight
      e1rm: number,                            // best estimated 1RM in last 60d
      lastTrained: string,                     // "3d", "1w" relative
      trend4wk: string,                        // "+5 lb / 4wk", "flat", "-2.5 lb / 4wk"
      bodyweight: boolean
    }
  },

  rituals: string[],                            // exercises in ≥60% of sessions, sorted by frequency
  rotation: {                                   // exercises appearing 2+ times below ritual threshold
    [muscle: string]: string[]                  // ordered by frequency desc
  },

  constraints: {
    injuries: string | null,                    // freeform — "right shoulder impingement, overhead painful"
    exerciseOut: string[]                       // hard rule-outs from UserRule entities
  },

  userProfile: {
    goal: "Hypertrophy" | "Strength" | "General Fitness" | "Sport-specific",
    experience: "Never" | "<1yr" | "1-3yr" | "3+yr",
    daysPerWeek: 3 | 4 | 5 | 6
  }
}
```

Output: see `evals/prompts/daily_plan_v5.md` schema. Top-level fields: `recommendation`, `strategy`, `exercises[]`, `estimatedDuration`, `deloadNote`, `selfCheck`.

### `bootstrap` input

```typescript
{
  goal: "hypertrophy" | "strength" | "general_fitness" | "sport_specific",
  daysPerWeek: 3 | 4 | 5 | 6,
  experience: "never" | "<1yr" | "1-3yr" | "3+yr",
  equipment: "full_gym" | "home_dumbbells" | "bodyweight",
  focusAreas: string[],                         // user-flagged lagging muscles
  injuriesOrAvoid: string | null,               // freeform
  crossTraining: string | null,                 // "climbing 2x/week", "running 5k Sat"
  preferences: string | null                    // freeform
}
```

Output: `programName`, `split`, `weeklyPattern` (mon–sun), `rotationPerMuscle`, `weeklyVolumeTargets`, `progressionScheme`, `ruleOuts`, `rationale`, `selfCheck`.

The `weeklyPattern` field is what seeds the Week Strip — Swift parses it into `SeedPattern { weekday: Int, muscleGroup: String }` rows. The `rotationPerMuscle` seeds the user's `preferences.rotation` until real session data takes over.

### `iterate` input

```typescript
{
  currentPlan: {                                // the plan currently rendered
    exercises: { name, sets, targetReps, suggestedWeight, intent }[]
  },
  userRequest: string,                          // freeform — "swap the bench, shoulder tight"
  input: {                                      // SUBSET of daily_plan_v5 input — only what's needed for anchoring
    strength: { ... },                          // same shape as above
    rituals: string[],
    constraints: { injuries, exerciseOut }
  }
}
```

Output: either `{responseType: "edit", editKind, edits[], rationale, watchOuts}` for plan changes, or `{responseType: "explain", answer}` for "why" questions.

---

## State Persistence — what Swift owns

New SwiftData entities:

```swift
@Model
final class MuscleGroupPin {
    var id: UUID
    var date: Date            // calendar day this pin applies to
    var muscleGroup: String   // canonical muscle name
    var createdAt: Date
}

@Model
final class SeedPattern {
    var id: UUID
    var weekday: Int          // 1=Sun, 2=Mon, ... 7=Sat (Calendar.component)
    var muscleGroup: String?  // nil = rest day
    var source: String        // "bootstrap" | "user_edit"
    var createdAt: Date
}
```

Existing entities used (unchanged):
- `WorkoutSession` — derives past cells, feeds pattern engine
- `Exercise` — exercise library
- `TrainingProgram` — goal, daysPerWeek, experience
- `UserIntelligence` — refreshed weekly background
- `UserRule` — the `exerciseOut` source
- `UserObservation` — soft AI-discovered patterns

No deletions of existing entities. Add the two above.

---

## What the deterministic baseline planner does (for the Swift engineer)

Given `PlannerInput` (same shape as `daily_plan_v5` input above), produce a plan WITHOUT calling the LLM:

```
1. Pick exercises:
   - For target muscle, take 1 ritual + 1 rotation + 1-2 isolation.
   - For incidental coverage of under-volume non-target muscles, pad with rotation entries.
   - Filter out anything in constraints.exerciseOut.
   - Slot order: compound → secondary compound → isolation → finisher.

2. Set counts per exercise:
   - Sum to targetWorkingSets ±0.
   - Compounds get 3, secondary 3, isolation 2, finisher 1-2.
   - On low-readiness path (feeling ≤ 2 OR low HRV+sleep): scale total by 0.6.

3. Weights:
   - Pull from strength[exercise].working with adjustment:
     - +2.5 lb if trend4wk is "+X lb / 4wk" and X >= 5
     - flat otherwise
     - −10% if low readiness path
   - If exercise not in strength[]: do not include — pick from rotation only.

4. Rep targets: standard ranges by intent:
   - Compound: "6-8"
   - Secondary compound: "8-10"
   - Isolation: "10-12"
   - Finisher: "12-15"

5. Output: same JSON shape as daily_plan_v5 but with no selfCheck deliberation.
   selfCheck.setCountMath is computed deterministically.
```

This is a single Swift file, ~300 lines, no LLM. It IS the product for 80%+ of sessions.

When the planner detects an escalation condition, it skips the deterministic path and calls `daily_plan_v5` with the same `PlannerInput`.

---

## Cost budget (for context)

Per-user-month at typical engagement (~5 trains/wk, 1 swap/session, 1 onboarding amortized over 12mo):

| Layer | Calls/mo | $/call | Total |
|---|---|---|---|
| Deterministic baseline | ~22 | $0 | $0 |
| `daily_plan_v5` escalations | ~3 | $0.03 | $0.09 |
| `iterate` swaps | ~22 | $0.002 | $0.04 |
| `bootstrap` (amortized) | 0.08 | $0.01 | $0.001 |
| Weekly intelligence refresh | 4 | $0.02 | $0.08 |
| **Total** | | | **~$0.21/user/mo** |

---

## Open decisions for the calendar UI agent

1. **Confidence visualization**: do we render `predictionConfidence` as opacity, italics, a small indicator, or hide it entirely? Recommendation: opacity 0.5 + italic "(predicted)" label when confidence < 0.6. Solid + no label otherwise.
2. **Pin conflict UX**: user pins chest tomorrow when chest was already today's predicted target. Do we suggest moving today's session, or just let the daily-plan prompt flag it? Recommendation: let the prompt flag it in `recommendation` text — don't add UI surface.
3. **Multi-muscle days**: weekly pattern can list "chest, shoulders, triceps" for one cell. Do we show a stacked indicator or just the primary muscle? Recommendation: pick the first muscle in the comma-list as the cell's primary, but underline-styled to hint there's more.
4. **Rest day rendering**: faint dashed cell, no fill. Tappable to override into a workout (creates a pin).

---

## Sequencing for the two workstreams

App-side (calendar UI agent):
1. Add `MuscleGroupPin` + `SeedPattern` entities. Migrate.
2. Build the pattern engine (`PatternEngine.computeUpcomingDays(...)`) as a pure func.
3. Build the Week Strip view + cell components.
4. Wire pin storage + tap interaction.
5. Build `PlannerInput` constructor that aggregates from existing services (`HealthKitService`, `UserState`, `MuscleGroupPin`, `SeedPattern`).
6. Build the deterministic baseline planner.
7. Wire escalation logic — call `daily_plan_v5` when conditions met.
8. Wire `iterate` to the Today view's swap/ask buttons.
9. Wire `bootstrap` to the onboarding flow.

Prompt-side (already done):
- ✅ `daily_plan_v5.md` — passing 5/5
- ✅ `bootstrap.md` — passing 4/5 → 5/5 after split-frequency patch
- ✅ `iterate.md` — passing 5/5

When the app side is ready to integrate, the prompt files in `evals/prompts/` are the ground truth. They consume the input contracts above verbatim — no further translation layer needed.
