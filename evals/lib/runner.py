"""Load fixtures + prompts, render, call the coach, save outputs."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = ROOT / "fixtures"
PROMPTS_DIR = ROOT / "prompts"
RESULTS_DIR = ROOT / "results"


@dataclass
class Prompt:
    name: str
    system: str
    user_template: str
    assistant_prefill: str | None = None
    thinking_budget: int | None = None

    def render(self, *, user_state_json: str, exercise_library: str, today_date: str) -> tuple[str, str]:
        subs = {
            "{{USER_STATE_JSON}}": user_state_json,
            "{{EXERCISE_LIBRARY}}": exercise_library,
            "{{TODAY_DATE}}": today_date,
        }
        sys_text = self.system
        usr_text = self.user_template
        for k, v in subs.items():
            sys_text = sys_text.replace(k, v)
            usr_text = usr_text.replace(k, v)
        return sys_text, usr_text


def load_prompt(name: str) -> Prompt:
    """Parse a prompt file split by `## SYSTEM` / `## USER` / optional `## ASSISTANT_PREFILL` H2s."""
    path = PROMPTS_DIR / f"{name}.md"
    if not path.exists():
        raise FileNotFoundError(f"prompt not found: {path}")
    raw = path.read_text()
    sys_match = re.search(r"^## SYSTEM\s*\n(.*?)(?=^## USER\s*$)", raw, re.DOTALL | re.MULTILINE)
    usr_match = re.search(
        r"^## USER\s*\n(.*?)(?=^## ASSISTANT_PREFILL\s*$|^## THINKING_BUDGET\s*$|\Z)",
        raw, re.DOTALL | re.MULTILINE,
    )
    pre_match = re.search(
        r"^## ASSISTANT_PREFILL\s*\n(.*?)(?=^## THINKING_BUDGET\s*$|\Z)",
        raw, re.DOTALL | re.MULTILINE,
    )
    think_match = re.search(r"^## THINKING_BUDGET\s*\n\s*(\d+)", raw, re.MULTILINE)
    if not sys_match or not usr_match:
        raise ValueError(f"{path} must have `## SYSTEM` and `## USER` sections")
    return Prompt(
        name=name,
        system=sys_match.group(1).strip(),
        user_template=usr_match.group(1).strip(),
        assistant_prefill=pre_match.group(1).strip() if pre_match else None,
        thinking_budget=int(think_match.group(1)) if think_match else None,
    )


def load_fixture(fid: str) -> dict[str, Any]:
    path = FIXTURES_DIR / f"{fid}.json"
    if not path.exists():
        raise FileNotFoundError(f"fixture not found: {path}")
    return json.loads(path.read_text())


def list_fixtures() -> list[str]:
    return sorted(p.stem for p in FIXTURES_DIR.glob("*.json"))


def load_exercise_library() -> str:
    return (PROMPTS_DIR / "exercise_library.txt").read_text().strip()


def render_prompt_for_fixture(prompt: Prompt, fixture: dict[str, Any]) -> tuple[str, str]:
    """Turn a fixture + prompt into concrete system+user strings.

    Supports multiple fixture shapes:
    - v1-v4 daily-plan: {meta, userState}                   → {{USER_STATE_JSON}}
    - v5 daily-plan:    {meta, input}                       → {{INPUT_JSON}}
    - bootstrap:        {meta, input (onboarding)}          → {{ONBOARDING_JSON}}
    - iterate:          {meta, currentPlan, userRequest, input}
                        → {{CURRENT_PLAN_JSON}}, {{USER_REQUEST}}, {{INPUT_JSON}}
    """
    today_date = date.today().strftime("%A, %b %d %Y")
    library = load_exercise_library()

    subs = {
        "{{EXERCISE_LIBRARY}}": library,
        "{{TODAY_DATE}}": today_date,
    }
    if "userState" in fixture:
        subs["{{USER_STATE_JSON}}"] = json.dumps(fixture["userState"], indent=2, sort_keys=True)
    if "input" in fixture:
        subs["{{INPUT_JSON}}"] = json.dumps(fixture["input"], indent=2, sort_keys=True)
        # Bootstrap fixtures use {{ONBOARDING_JSON}} for the same content.
        subs["{{ONBOARDING_JSON}}"] = json.dumps(fixture["input"], indent=2, sort_keys=True)
    if "currentPlan" in fixture:
        subs["{{CURRENT_PLAN_JSON}}"] = json.dumps(fixture["currentPlan"], indent=2, sort_keys=True)
    if "userRequest" in fixture:
        subs["{{USER_REQUEST}}"] = fixture["userRequest"]

    sys_text = prompt.system
    usr_text = prompt.user_template
    for k, v in subs.items():
        sys_text = sys_text.replace(k, v)
        usr_text = usr_text.replace(k, v)
    return sys_text, usr_text


def results_path(prompt_name: str, fixture_id: str) -> Path:
    d = RESULTS_DIR / prompt_name
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{fixture_id}.json"


def parse_plan(text: str) -> dict[str, Any] | None:
    """Extract the first complete JSON object from the model's reply.

    The system prompt asks for JSON only, but smaller models sometimes wrap
    in ```json fences or add trailing prose. We tolerate both: locate the
    first '{', then scan forward tracking brace depth (with string awareness)
    to find its matching '}'. That window is the candidate JSON.
    """
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                snippet = text[start : i + 1]
                try:
                    return json.loads(snippet)
                except json.JSONDecodeError:
                    # Tolerate trailing commas — Haiku occasionally emits them
                    # in lists/objects. Cheaper to recover than to lose the
                    # whole eval over a comma.
                    fixed = re.sub(r",(\s*[}\]])", r"\1", snippet)
                    try:
                        return json.loads(fixed)
                    except json.JSONDecodeError:
                        return None
    return None
