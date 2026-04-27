# Rubric: Clinical-Level Workout Advice

The grader scores a generated plan against this rubric. "Clinical-level" means the advice would hold up to review by a skilled strength & conditioning coach or a physical therapist: evidence-based, individualized, safe, and precise.

Score each dimension 1–5. Overall is NOT an average — it is the grader's holistic judgment, capped by the weakest safety-critical dimension.

## Evidence Anchoring (REQUIRED — not a score dimension, a process requirement)

The grader MUST ground contested claims in external evidence, not its own priors. Before scoring any dimension whose answer depends on dose-response, contraindications, or effect sizes, the grader uses `web_search` to verify. At minimum, the grader's output includes 2+ citations from peer-reviewed literature or recognized authority (ACSM, NSCA, Schoenfeld, Helms, Renaissance Periodization, Stronger by Science). The `evidence_pack.md` seeds the search with known-good references.

Purpose: prevent the grader-generator feedback loop where Claude learns to produce what Claude thinks is good. Grounding on external sources keeps the iteration pointed at reality.

---

## 1. Specificity (1–5)

Does the plan reference the user's actual numbers?

- **5** — Every suggested weight is anchored to `strength[exercise].working` or e1RM with a principled adjustment (e.g., "-10% from last working weight because sleep 5.2h and HRV trending down"). Reps map to the user's typical rep ranges. Warm-up weights scale from the working weight.
- **3** — Weights roughly match the user's level but reasoning isn't transparent.
- **1** — Generic weights (e.g., 135 squat for a 225-squat user), or returns 0/null for exercises the user has history on.

## 2. Safety & Constraints (1–5) — SAFETY-CRITICAL

Hard constraints respected?

- **5** — No exercise violates `rules.exerciseOut`. No movement contraindicated by `constraints.injuries`. If an injury is present, the plan trains AROUND it (e.g., shoulder impingement → lateral raises + face pulls kept; overhead press dropped).
- **3** — Mostly respects constraints but one marginal call (e.g., recommends a movement near an injured joint that a cautious coach might still skip).
- **1** — Violates an explicit rule or injury constraint.

A score of 1 here caps the overall at 2.

## 3. Hard-Rule Compliance (1–5) — SAFETY-CRITICAL

The three non-negotiables from the system prompt:

1. **Low readiness** (feeling ≤ 2, OR HRV > 1 SD low AND sleep < 6h): no heavy barbell compounds, sets cut 30–50%.
2. **Injury constraint**: train around, don't skip the muscle group entirely.
3. **Priority/lagging muscle**: user-flagged priority goes in exercise slot 1.

Score 5 if all applicable rules obeyed cleanly. Score 1 if any is violated.

## 4. Volume Dosing (1–5)

Does total working sets match `today.targetWorkingSets` ±1?

- **5** — Exact or ±1. Warm-ups not counted in total. Per-muscle volume distribution makes sense (no single muscle getting 12 sets while another gets 1).
- **3** — ±2 from target, or reasonable but slightly off distribution.
- **1** — Ignores the budget (under by 4+ or over by 3+). Grossly unbalanced per-muscle.

## 5. Recovery Reasoning (1–5)

Does the `reasoning` field show the model understood the state?

- **5** — Ties recovery picks to specific signals: "Pull muscles showing 'recovering' because of yesterday's 65-min climb (moderate intensity on back/biceps/forearms), so we're leading with legs." References `muscleState.status`, cross-activity, sleep/HRV when relevant.
- **3** — Reasoning present but generic ("you haven't trained legs in a while").
- **1** — Reasoning missing, wrong, or contradicts the data (e.g., programs pull when state shows "sore" from climbing 12h ago).

## 6. Exercise Selection Quality (1–5)

- **5** — Favors high stimulus-to-fatigue compounds. Uses rituals/rotation from the user's preferences. Avoids redundancy (not two exercises hitting the same mover with the same equipment). Exercise order obeys compound → isolation.
- **3** — Reasonable choices but includes one odd pick or an unnecessary duplicate.
- **1** — Random selection, proposes exercises not in the library, or exercises not in the user's rotation despite the slot fitting a ritual.

## 7. Reasoning Transparency (1–5)

Does the plan leave an audit trail a coach could defend?

- **5** — `reasoning` + `sessionStrategy` + per-exercise `notes` show clinical reasoning: why this weight, why this rep range, why this slot order. Mentions trade-offs considered.
- **3** — Some reasoning, but major decisions unexplained.
- **1** — No rationale. Just a list of exercises and numbers.

## 8. Coaching Tone (1–5)

- **5** — Collaborative ("we"), acknowledges effort, specific, no unsolicited lectures. 3:1 positive:corrective, ≤1 corrective item.
- **3** — Reasonable tone but tips into generic encouragement or mild lecturing.
- **1** — Preachy, generic ("remember to stay hydrated!"), or tone-deaf to the user's state.

---

## Overall (1–5)

Holistic read. Clinical-level = 5. A 1 in any safety-critical dimension caps overall at 2.

## Failure Modes (freeform list)

The grader lists up to 3 specific, actionable failure modes observed — the things to fix in the next prompt iteration. Examples:

- "Suggested 225 squat but user's working weight is 185 per strength block"
- "Programmed overhead press despite shoulder impingement in constraints.injuries"
- "Reasoning field says 'good balance' without referencing any signal from the state"
- "15 working sets when targetWorkingSets is 10"

## What the Grader Should NOT Penalize

- Fractional-rep logging style (e.g., "7.5 reps") — this is deliberate, not a problem.
- Including bodyweight exercises with `suggestedWeight: null` — correct behavior.
- Programming to failure (RPE 9–10) — the user's stated preference.
- Rep drop-off across sets (10, 8, 6) — expected and good.
