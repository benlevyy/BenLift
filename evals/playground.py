#!/usr/bin/env python3
"""Interactive loop: pick a fixture, generate a plan, grade it, log your own notes.

This is where iteration happens. You read the plan, read the judge's critique
(which cites external evidence), add your own human note on what's still wrong,
then tweak the prompt and rerun the same fixture.

Notes are appended to results/<prompt>/<fixture>.notes.jsonl — each line is a
dated entry, so you have a history of your reactions as the prompt evolves.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.prompt import Prompt

from lib.client import call_coach
from lib.judge import judge_plan
from lib.runner import (
    list_fixtures,
    load_fixture,
    load_prompt,
    parse_plan,
    render_prompt_for_fixture,
    results_path,
)

console = Console()


def show_plan(plan: dict | None, raw_text: str) -> None:
    if plan is None:
        console.print(Panel(raw_text, title="Plan (UNPARSEABLE)", border_style="red"))
        return
    summary_lines = []
    summary_lines.append(f"**Focus:** {plan.get('recommendedFocus')}")
    summary_lines.append(f"**Session:** {plan.get('recommendedSessionName')}")
    summary_lines.append(f"**Reasoning:** {plan.get('reasoning')}")
    summary_lines.append("")
    summary_lines.append("**Exercises:**")
    for i, ex in enumerate(plan.get("exercises") or [], 1):
        weight = ex.get("suggestedWeight")
        w_str = "BW" if weight in (None, 0) else f"{weight} lb"
        summary_lines.append(
            f"{i}. {ex.get('name')} — {ex.get('sets')}×{ex.get('targetReps')} @ {w_str} "
            f"_{ex.get('intent','')}_"
        )
        if ex.get("notes"):
            summary_lines.append(f"   > {ex['notes']}")
    summary_lines.append("")
    summary_lines.append(f"**Strategy:** {plan.get('sessionStrategy')}")
    summary_lines.append(f"**Est duration:** {plan.get('estimatedDuration')} min")
    total_sets = sum((ex.get("sets") or 0) for ex in plan.get("exercises") or [])
    summary_lines.append(f"**Total working sets (sum):** {total_sets}")
    console.print(Panel(Markdown("\n".join(summary_lines)), title="Generated Plan", border_style="cyan"))


def show_judge(g: dict) -> None:
    parsed = g.get("graded") or {}
    if not parsed:
        console.print(Panel(g.get("raw_grader_text", ""), title="Judge (UNPARSEABLE)", border_style="red"))
        return

    lines = [f"**Overall: {parsed.get('overall')}/5**", ""]
    lines.append(f"_{parsed.get('overall_justification','')}_")
    lines.append("")
    lines.append("| dim | score | justification |")
    lines.append("|---|---|---|")
    for dim, val in (parsed.get("per_dimension") or {}).items():
        j = (val.get("justification") or "").replace("\n", " ")
        lines.append(f"| {dim} | {val.get('score')} | {j[:100]}{'…' if len(j)>100 else ''} |")
    lines.append("")
    if parsed.get("wins"):
        lines.append("**Wins:**")
        for w in parsed["wins"]:
            lines.append(f"- {w}")
        lines.append("")
    if parsed.get("failure_modes"):
        lines.append("**Failure modes:**")
        for fm in parsed["failure_modes"]:
            lines.append(f"- {fm}")
        lines.append("")
    lines.append(f"**Evidence:** {parsed.get('evidence_summary','')}")
    console.print(Panel(Markdown("\n".join(lines)), title="Judge", border_style="magenta"))

    cits = g.get("grader_citations") or []
    if cits:
        console.print(f"[dim]grader web_search citations: {len(cits)}[/dim]")


def interactive_fixture_picker() -> str:
    fixtures = list_fixtures()
    console.print("[bold]Fixtures:[/bold]")
    for i, f in enumerate(fixtures, 1):
        meta = load_fixture(f).get("meta", {})
        console.print(f"  {i}. {f} — [dim]{meta.get('description','')}[/dim]")
    choice = Prompt.ask("Pick a number (or fixture id)", default="1")
    if choice.isdigit():
        return fixtures[int(choice) - 1]
    return choice


def append_note(prompt_name: str, fixture_id: str, note: str, overall: float | int | None) -> Path:
    path = (results_path(prompt_name, fixture_id).parent / f"{fixture_id}.notes.jsonl")
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "prompt": prompt_name,
        "overall": overall,
        "note": note,
    }
    with path.open("a") as f:
        f.write(json.dumps(entry) + "\n")
    return path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--fixture", help="fixture id; omit for interactive picker")
    ap.add_argument("--skip-judge", action="store_true", help="skip grading (faster; just see the plan)")
    args = ap.parse_args()

    prompt = load_prompt(args.prompt)
    fid = args.fixture or interactive_fixture_picker()
    fixture = load_fixture(fid)

    console.print(Panel(
        f"[bold]{fixture.get('meta',{}).get('description','')}[/bold]\n\n"
        + "Must check:\n- " + "\n- ".join(fixture.get("meta",{}).get("must_check", [])),
        title=f"Fixture: {fid}", border_style="yellow",
    ))

    system, user = render_prompt_for_fixture(prompt, fixture)
    console.print(f"[dim]calling coach ({args.prompt})…[/dim]")
    resp = call_coach(system, user, assistant_prefill=prompt.assistant_prefill)
    plan = parse_plan(resp.text)

    record = {
        "prompt_name": args.prompt,
        "fixture_id": fid,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "plan": plan,
        "raw_text": resp.text if plan is None else None,
        "usage": {
            "input_tokens": resp.input_tokens,
            "output_tokens": resp.output_tokens,
            "cache_read_tokens": resp.cache_read_tokens,
            "cache_creation_tokens": resp.cache_creation_tokens,
        },
    }
    results_path(args.prompt, fid).write_text(json.dumps(record, indent=2))

    show_plan(plan, resp.text)

    overall = None
    if not args.skip_judge:
        console.print("[dim]judging with web_search…[/dim]")
        g = judge_plan(fixture_id=fid, plan=plan, plan_raw_text=resp.text)
        judge_path = results_path(args.prompt, fid).parent / f"{fid}.judge.json"
        judge_path.write_text(json.dumps(g, indent=2))
        show_judge(g)
        overall = (g.get("graded") or {}).get("overall")

    console.print()
    note = Prompt.ask("[yellow]Your take[/yellow] (what's missing to hit clinical?)", default="")
    if note:
        p = append_note(args.prompt, fid, note, overall)
        console.print(f"[dim]logged to {p.relative_to(p.parent.parent.parent)}[/dim]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
