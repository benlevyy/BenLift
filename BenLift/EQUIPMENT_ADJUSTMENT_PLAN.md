# Equipment Availability Adjustment — Plan

**Status:** Brainstormed, not yet implemented. Waiting on user confirmation of approach before writing code.

## Goal

Let the user tell the planner what equipment is actually available today ("only have dumbbells," "hotel gym, no barbell") and have both the deterministic baseline planner and the Opus (`daily_plan_v5`) path respect it — user-friendly and low-friction, not something that requires re-specifying from scratch every session.

## Why this is cheap to build — existing hooks

- **`Equipment` enum already exists** (`BenLift/Models/Enums.swift:32`): `barbell, dumbbell, machine, cable, bodyweight, kettlebell`. Every `Exercise` in the library is already tagged with one (`Models.swift:11`).
- **`BaselinePlanner.isAllowed(_:)`** (`BenLift/Services/BaselinePlanner.swift:38-45`) already gates exercise selection by exclusion rules — currently used for `exerciseOut` (hard rule-outs), injury keyword blockers, and low-readiness barbell exclusion. Adding an equipment filter is the same shape: one more condition in this existing function.
- **`PlannerInput.constraints.exerciseOut: [String]`** (`BenLift/Services/PlannerInput.swift`) is already wired end-to-end into the `daily_plan_v5` prompt as a hard rule-out list. Equipment availability can ride this same field — no prompt/schema/evals changes needed — by computing "every exercise whose equipment isn't available today" into `exerciseOut` client-side before `PlannerInput.build` runs.
- There's already a coarse, onboarding-time-only equipment tier: `EquipmentAccess` enum (`fullGym`/`homeGym`/`limited`, `Enums.swift:174`, used in `GoalSettingView.swift:16`) and a separate `BootstrapEquipment` enum (`OnboardingView.swift:19`, for the bootstrap LLM call: `"full_gym" | "home_dumbbells" | "bodyweight"`). Both are one-time/durable, not adjustable per-session — worth being aware these exist so a new mechanism doesn't collide with or duplicate them.

## UX options considered

1. **Free text into the existing check-in box** ("only have dumbbells today") — zero new UI, but the deterministic baseline planner can't act on free text without fragile parsing, and retyping the same thing every gym visit is more friction than a toggle.
2. **Named presets** ("Full Gym" / "Home" / "Hotel" / "Bodyweight Only") — one tap, each preset maps to a fixed equipment set defined once. Matches how equipment access actually varies for most people: a small number of recurring situations, not infinite combinations.
3. **Granular multi-select chips** — six toggles, one per `Equipment` case, same visual language as the existing Feeling/Time chips on Today. Most precise, but re-tapping six things every time is too much friction for the common case.

## Recommendation (combine 2 + 3)

- **Persistent default**, set once (Settings), defaults to "Full Gym" = everything available. Costs zero taps on a normal day.
- **Quick preset row on Today** for the days it's different from the default.
- **Granular 6-toggle grid** behind an "Edit"/"Custom" tap, for the rare case that doesn't match a preset (e.g. "dumbbells + pull-up bar, no machine").

This was presented to the user; they had not yet confirmed this direction (vs. one of the three simpler standalone options) when context was cleared. **Confirm the approach before implementing.**

## Implementation sketch (once approach is confirmed)

1. New durable setting: available `Set<Equipment>`, persisted (AppStorage or a small settings model), defaulting to all cases (Full Gym).
2. New preset concept: named `Set<Equipment>` mappings (Full Gym / Home / Hotel / Bodyweight Only, or user-defined) — decide storage (hardcoded presets vs. user-editable in Settings).
3. UI: preset row + edit affordance, likely living near/alongside the existing check-in card on `TodayView` (`checkInRow`), consistent with how Feeling/Time/concerns already work — but equipment should NOT auto-reset after each plan generation the way `concerns` does, since it's a durable-until-changed fact, not one-shot intent.
4. Wiring: compute `unavailableExerciseNames = library.filter { !availableEquipment.contains($0.equipment) }.map(\.name)`, fold into `PlannerInput.constraints.exerciseOut` alongside the existing `UserRule`-derived rule-outs, and add the same filter condition to `BaselinePlanner.isAllowed(_:)`.
5. Consider whether `MidWorkoutAdaptResponse`/`quickSwap`/`iterate` swap suggestions should also respect this constraint (likely yes, for consistency — check `PromptBuilder.quickSwapPrompt`'s `availableExercises` list, which should probably be pre-filtered too).

## Context for a fresh session picking this up

This app (BenLift) is a single-user iOS/watchOS lifting app. Recent architecture direction (already implemented, not part of this task): every plan generation always escalates to Opus (`claude-opus-5`, via `ClaudeModel.current` in `BenLift/Utilities/ClaudeModel.swift`) with adaptive thinking — no more cost/speed-driven shortcuts, precision is the explicit priority. `BaselinePlanner` is now only an offline/API-failure fallback, not the default path. The Today screen was recently reworked: one check-in card (feeling/time/concerns) with a single "Update Plan" button (the old separate Refresh pill and Customize sheet were merged/removed). Per-exercise "why this pick" text (`PlannedExercise.evidenceNote`, from `daily_plan_v5`) shows inline under each row — an earlier attempt to group exercises under muscle-group section headers was tried and reverted (too much overlap between muscle groups to be practical, per the user).
