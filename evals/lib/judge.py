"""Grade generated plans against the rubric, grounded by web_search."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .client import call_judge
from .runner import FIXTURES_DIR, ROOT, load_fixture

RUBRIC_PATH = ROOT / "rubric.md"
EVIDENCE_PATH = ROOT / "evidence_pack.md"


JUDGE_SYSTEM = """You are an evidence-anchored grader for workout-advice quality. Your job is NOT to rubber-stamp the advice, and NOT to rely on your own opinions — your job is to audit the advice against the rubric, using external evidence for anything contested.

You have access to `web_search`. USE IT. Before scoring any dimension whose answer depends on effect sizes, dose-response, contraindications, or load prescription, run at least one search to verify — do not rely on recall. The `evidence_pack.md` below lists seed references; you are welcome to retrieve more.

Return strict JSON only — no markdown, no prose outside the JSON.

Output schema:
{
  "per_dimension": {
    "specificity":          {"score": 1-5, "justification": "...", "citations": ["source description + URL"]},
    "safety":               {"score": 1-5, "justification": "...", "citations": [...]},
    "hard_rules":           {"score": 1-5, "justification": "...", "citations": [...]},
    "volume_dosing":        {"score": 1-5, "justification": "...", "citations": [...]},
    "recovery_reasoning":   {"score": 1-5, "justification": "...", "citations": [...]},
    "exercise_selection":   {"score": 1-5, "justification": "...", "citations": [...]},
    "reasoning_transparency":{"score": 1-5, "justification": "...", "citations": [...]},
    "coaching_tone":        {"score": 1-5, "justification": "...", "citations": [...]}
  },
  "overall": 1-5,
  "overall_justification": "holistic read — capped at 2 if any safety-critical dim is 1",
  "failure_modes": ["specific actionable fixes, <=3"],
  "wins": ["things the plan did well, <=3"],
  "evidence_summary": "2-3 sentences tying your most important scoring calls to the citations"
}

Rules:
- `citations` may be empty for dimensions that are purely rule-matching against the fixture (e.g., hard_rules compliance is checked against the fixture meta.must_check). Include citations when the scoring call depends on outside knowledge.
- At least 2 citations TOTAL across the output. If you did not search, say so in `evidence_summary` and cap every evidence-dependent dimension at 3.
- Be ruthless. A 5 means clinical-grade. Most first-draft outputs should not score 5 on most dimensions.
"""


def load_rubric() -> str:
    return RUBRIC_PATH.read_text()


def load_evidence_pack() -> str:
    return EVIDENCE_PATH.read_text()


def judge_plan(
    *,
    fixture_id: str,
    plan: dict[str, Any] | None,
    plan_raw_text: str,
) -> dict[str, Any]:
    fixture = load_fixture(fixture_id)
    meta = fixture.get("meta", {})

    user = f"""Grade this workout plan against the rubric.

=== FIXTURE META ===
{json.dumps(meta, indent=2)}

=== USER STATE (input the coach saw) ===
{json.dumps(fixture['userState'], indent=2, sort_keys=True)}

=== RUBRIC ===
{load_rubric()}

=== EVIDENCE PACK (seed references — use web_search for more) ===
{load_evidence_pack()}

=== GENERATED PLAN (the thing you are grading) ===
"""
    if plan is not None:
        user += json.dumps(plan, indent=2)
    else:
        user += f"(Plan did not parse as JSON — raw model output below)\n\n{plan_raw_text}"

    user += "\n\nReturn the grading JSON now."

    result = call_judge(JUDGE_SYSTEM, user)
    text = result["text"]
    graded = _parse_json_loose(text)
    return {
        "fixture_id": fixture_id,
        "graded": graded,
        "raw_grader_text": text,
        "grader_citations": result.get("citations", []),
        "stop_reason": result.get("stop_reason"),
        "usage": result.get("usage"),
    }


def _parse_json_loose(text: str) -> dict[str, Any] | None:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Pull the first {...} block.
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
