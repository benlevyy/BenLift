#!/usr/bin/env python3
"""Grade a run (or compare two runs) using the evidence-anchored judge."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from rich.console import Console
from rich.table import Table

from lib.judge import judge_plan
from lib.runner import RESULTS_DIR

console = Console()


def grade_run(run_name: str) -> list[dict]:
    run_dir = RESULTS_DIR / run_name
    if not run_dir.exists():
        raise SystemExit(f"No run at {run_dir} — did you `python run.py --prompt {run_name}` first?")

    # Skip .judge.json files so re-grading doesn't re-grade grades.
    record_files = sorted(p for p in run_dir.glob("*.json") if not p.name.endswith(".judge.json"))
    graded = []
    for path in record_files:
        rec = json.loads(path.read_text())
        console.print(f"[cyan]judging {run_name}/{rec['fixture_id']}[/cyan] (web_search enabled)…")
        g = judge_plan(
            fixture_id=rec["fixture_id"],
            plan=rec.get("plan"),
            plan_raw_text=rec.get("raw_text") or "",
        )
        out_path = run_dir / f"{rec['fixture_id']}.judge.json"
        out_path.write_text(json.dumps(g, indent=2))
        graded.append(g)

        parsed = g.get("graded") or {}
        overall = parsed.get("overall", "?")
        console.print(f"  overall={overall}  citations={len(g.get('grader_citations', []))}")
    return graded


def summarize(run_name: str, graded: list[dict]) -> None:
    dims = [
        "specificity", "safety", "hard_rules", "volume_dosing",
        "recovery_reasoning", "exercise_selection",
        "reasoning_transparency", "coaching_tone",
    ]
    table = Table(title=f"scores: {run_name}")
    table.add_column("fixture")
    for d in dims:
        table.add_column(d[:6], justify="center")
    table.add_column("overall", justify="center")

    for g in graded:
        parsed = g.get("graded") or {}
        per = parsed.get("per_dimension") or {}
        row = [g["fixture_id"]]
        for d in dims:
            row.append(str((per.get(d) or {}).get("score", "?")))
        row.append(str(parsed.get("overall", "?")))
        table.add_row(*row)
    console.print(table)


def compare(run_a: str, run_b: str) -> None:
    def load(name: str) -> dict[str, dict]:
        out = {}
        for path in (RESULTS_DIR / name).glob("*.judge.json"):
            data = json.loads(path.read_text())
            out[data["fixture_id"]] = data
        return out

    a = load(run_a)
    b = load(run_b)
    keys = sorted(set(a) & set(b))

    table = Table(title=f"compare: {run_a} → {run_b}")
    table.add_column("fixture")
    table.add_column(run_a, justify="center")
    table.add_column(run_b, justify="center")
    table.add_column("Δ", justify="center")

    for k in keys:
        oa = (a[k].get("graded") or {}).get("overall")
        ob = (b[k].get("graded") or {}).get("overall")
        if isinstance(oa, (int, float)) and isinstance(ob, (int, float)):
            delta = ob - oa
            color = "green" if delta > 0 else "red" if delta < 0 else "white"
            table.add_row(k, str(oa), str(ob), f"[{color}]{delta:+}[/{color}]")
        else:
            table.add_row(k, str(oa), str(ob), "?")
    console.print(table)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", help="Run (prompt) name to grade")
    ap.add_argument("--compare", nargs=2, metavar=("RUN_A", "RUN_B"), help="Compare two graded runs")
    args = ap.parse_args()

    if args.compare:
        compare(*args.compare)
        return 0

    if not args.run:
        ap.error("pass --run NAME or --compare RUN_A RUN_B")
    graded = grade_run(args.run)
    summarize(args.run, graded)
    return 0


if __name__ == "__main__":
    sys.exit(main())
