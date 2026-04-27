# BenLift ML Advice Evals

A Python harness for iterating on the Claude prompts that generate workout advice. Goal: drive the daily plan + recovery recommendation toward **clinical-level** quality — evidence-based reasoning, precise dosing, contraindication awareness, individualized to the user's state.

## Workflow

```
fixture (UserState JSON) ──► prompt version ──► Claude ──► plan (JSON)
                                                              │
                                                              ▼
                                                           judge ──► rubric score + critique
                                                              │
                                                              ▼
                                                        your notes (optional)
```

Iterate: edit `prompts/vN.md`, re-run, compare scores, repeat until the judge says "clinical."

## Setup

```bash
cd evals
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # then fill in ANTHROPIC_API_KEY
```

## Layout

- `prompts/` — system prompt versions. `v1_baseline.md` is extracted verbatim from `PromptBuilder.recommendAndPlanPrompt`. Iterate by copying to `v2_*.md`.
- `prompts/exercise_library.txt` — library the model picks from, grouped by muscle.
- `fixtures/` — scenarios. Each is a `UserState`-shaped JSON blob plus a `meta` block describing what the fixture tests.
- `rubric.md` — human-readable rubric. The judge prompt references it.
- `lib/` — thin wrappers: Anthropic client, runner, judge.
- `results/` — run outputs, gitignored. `results/<prompt_version>/<fixture_id>.json` holds plan + judge score.

## Commands

```bash
# Run one prompt version against all fixtures, save plans
python run.py --prompt v1_baseline --fixtures all

# Run a single fixture (for focused iteration)
python run.py --prompt v2_custom --fixtures 02_ben_post_climbing

# Have Claude grade a run
python judge.py --run v1_baseline

# Compare two runs' scores
python judge.py --compare v1_baseline v2_custom

# Interactive: one fixture at a time, see plan + judge + add your own notes
python playground.py --prompt v1_baseline
```

## Adding a fixture

Copy `fixtures/01_ben_baseline_push.json`, edit the `userState` block to reflect the scenario you want to test, and set `meta.description` + `meta.must_check` (what a clinical-quality response MUST do — the judge reads this as part of the rubric).
