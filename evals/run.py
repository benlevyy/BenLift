#!/usr/bin/env python3
"""Generate plans for a prompt version against fixtures."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

from rich.console import Console
from rich.table import Table

from lib.client import call_coach
from lib.runner import (
    list_fixtures,
    load_fixture,
    load_prompt,
    parse_plan,
    render_prompt_for_fixture,
    results_path,
)

console = Console()


def run_one(prompt_name: str, fixture_id: str) -> dict:
    prompt = load_prompt(prompt_name)
    fixture = load_fixture(fixture_id)
    system, user = render_prompt_for_fixture(prompt, fixture)

    console.print(f"[cyan]→ {prompt_name} / {fixture_id}[/cyan]")
    # When thinking is enabled, the visible response can be longer than 4k
    # because the thinking field bloats the schema with `hardRulesCheck`
    # evidence strings. Give it 6k.
    visible_budget = 8000 if prompt.thinking_budget else 4096
    resp = call_coach(
        system, user,
        max_tokens=visible_budget,
        assistant_prefill=prompt.assistant_prefill,
        thinking_budget=prompt.thinking_budget,
    )
    plan = parse_plan(resp.text)

    record = {
        "prompt_name": prompt_name,
        "fixture_id": fixture_id,
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
    path = results_path(prompt_name, fixture_id)
    path.write_text(json.dumps(record, indent=2))

    status = "[green]parsed[/green]" if plan else "[red]unparseable[/red]"
    console.print(
        f"  {status}  in={resp.input_tokens} out={resp.output_tokens} "
        f"cached_read={resp.cache_read_tokens} → {path.relative_to(path.parent.parent.parent)}"
    )
    return record


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True, help="Prompt file name (without .md)")
    ap.add_argument("--fixtures", default="all", help="'all' or comma-separated fixture IDs")
    args = ap.parse_args()

    if args.fixtures == "all":
        fixtures = list_fixtures()
    else:
        fixtures = [f.strip() for f in args.fixtures.split(",") if f.strip()]

    results = []
    for fid in fixtures:
        try:
            results.append(run_one(args.prompt, fid))
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]  ✗ {fid}: {e}[/red]")

    table = Table(title=f"run: {args.prompt}")
    table.add_column("fixture")
    table.add_column("parsed", justify="center")
    table.add_column("in", justify="right")
    table.add_column("out", justify="right")
    table.add_column("cache_read", justify="right")
    for r in results:
        table.add_row(
            r["fixture_id"],
            "✓" if r["plan"] else "✗",
            str(r["usage"]["input_tokens"]),
            str(r["usage"]["output_tokens"]),
            str(r["usage"]["cache_read_tokens"]),
        )
    console.print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
