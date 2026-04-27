"""Anthropic client wrapper with prompt caching on the system prompt.

Prompt caching matters here because every fixture in a run shares the same
system prompt — caching it buys ~90% off the system-prompt input tokens
on runs 2..N within the 5-minute TTL. For a 12-fixture run that's the
difference between pennies and dimes.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

from anthropic import Anthropic
from dotenv import load_dotenv

load_dotenv()

_client: Anthropic | None = None


def client() -> Anthropic:
    global _client
    if _client is None:
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise RuntimeError("ANTHROPIC_API_KEY missing. Copy .env.example → .env.")
        _client = Anthropic(api_key=key)
    return _client


COACH_MODEL = os.environ.get("COACH_MODEL", "claude-haiku-4-5-20251001")
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "claude-opus-4-7")


@dataclass
class CoachResponse:
    text: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_creation_tokens: int


def call_coach(
    system: str,
    user: str,
    *,
    max_tokens: int = 4096,
    assistant_prefill: str | None = None,
    thinking_budget: int | None = None,
) -> CoachResponse:
    """Call the coach model with prompt caching on the system block.

    System is sent as a cache breakpoint — the first call in a run creates
    the cache, subsequent calls read from it.

    `assistant_prefill` forces the model's reply to start with literal text
    we choose. Setting it to "{" eliminates ```json fences and any pre-JSON
    prose, since the model continues from the opening brace. Incompatible
    with `thinking_budget` — extended thinking requires no prefill.

    `thinking_budget` enables extended thinking on Claude 4.x with the given
    token budget. The thinking content does NOT count toward the visible
    response and is not returned in `text`. Required for cases where the
    model needs to deliberate, draft, and self-revise before emitting JSON.
    Sets temperature=1 (required by the API when thinking is enabled).
    """
    if thinking_budget is not None and assistant_prefill is not None:
        raise ValueError("extended thinking is incompatible with assistant prefill")

    messages: list[dict[str, Any]] = [{"role": "user", "content": user}]
    if assistant_prefill is not None:
        messages.append({"role": "assistant", "content": assistant_prefill})

    kwargs: dict[str, Any] = dict(
        model=COACH_MODEL,
        max_tokens=max_tokens,
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=messages,
    )
    if thinking_budget is not None:
        kwargs["thinking"] = {"type": "enabled", "budget_tokens": thinking_budget}
        kwargs["temperature"] = 1.0
        # max_tokens caps the WHOLE response (thinking + visible output) — so
        # we add the thinking budget on top of the visible-output budget the
        # caller wanted, rather than letting thinking eat the visible quota.
        kwargs["max_tokens"] = max_tokens + thinking_budget

    resp = client().messages.create(**kwargs)
    text = "".join(block.text for block in resp.content if block.type == "text")
    # If we prefilled, the API returns only what came AFTER the prefill — so
    # stitch the prefill back on so downstream parsers see a complete response.
    if assistant_prefill is not None:
        text = assistant_prefill + text
    usage = resp.usage
    return CoachResponse(
        text=text,
        input_tokens=usage.input_tokens,
        output_tokens=usage.output_tokens,
        cache_read_tokens=getattr(usage, "cache_read_input_tokens", 0) or 0,
        cache_creation_tokens=getattr(usage, "cache_creation_input_tokens", 0) or 0,
    )


def call_judge(
    system: str,
    user: str,
    *,
    max_tokens: int = 6000,
    enable_web_search: bool = True,
) -> dict[str, Any]:
    """Call the judge model with web_search tool enabled.

    web_search is the Anthropic-hosted server-side tool — the judge uses it
    to verify contested claims against peer-reviewed literature rather than
    grading on its own priors. Without this, grading becomes Claude judging
    Claude, which is a feedback loop with no external signal.
    """
    tools: list[dict[str, Any]] = []
    if enable_web_search:
        tools.append({"type": "web_search_20250305", "name": "web_search", "max_uses": 5})

    resp = client().messages.create(
        model=JUDGE_MODEL,
        max_tokens=max_tokens,
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": user}],
        tools=tools if tools else None,
    )

    # Collect final text (after any tool use rounds are resolved server-side).
    text_blocks: list[str] = []
    citations: list[dict[str, Any]] = []
    for block in resp.content:
        if block.type == "text":
            text_blocks.append(block.text)
            # Text blocks may include inline citations when web_search is used.
            if getattr(block, "citations", None):
                for c in block.citations:
                    try:
                        citations.append(c.model_dump())
                    except Exception:
                        citations.append({"raw": repr(c)})
    return {
        "text": "".join(text_blocks),
        "citations": citations,
        "stop_reason": resp.stop_reason,
        "usage": {
            "input_tokens": resp.usage.input_tokens,
            "output_tokens": resp.usage.output_tokens,
        },
    }
