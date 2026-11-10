"""Deterministic minutes export. Does not infer decisions, assignments, or dates."""

import html
import re
from collections.abc import Iterable
from typing import Protocol


class Utterance(Protocol):
    text: str
    speaker: str | None
    start_secs: float | None


class Action(Protocol):
    text: str
    owner: str | None
    due_date: str | None
    completed: bool
    source_utterance: int
    source_quote: str


def escape(value: str) -> str:
    return re.sub(r"([\\`*_{}\[\]()#+!|>\-])", r"\\\1", html.escape(value, quote=False))


def render_minutes(
    title: str,
    provider: str,
    source_id: str,
    cues: Iterable[Utterance],
    actions: Iterable[Action],
    edited_notes: str | None = None,
) -> str:
    lines = [f"# {escape(title)}", "", f"Source: {escape(provider)} · {escape(source_id)}", ""]
    if edited_notes is not None:
        lines.extend(["## Edited notes", "", escape(edited_notes), ""])
    lines.extend(["## Confirmed actions", ""])
    for action in actions:
        details = " · ".join(v for v in (action.owner, action.due_date) if v)
        lines.extend(
            [
                f"- [{'x' if action.completed else ' '}] {escape(action.text)}"
                + (f" — {escape(details)}" if details else ""),
                f"  - Source utterance {action.source_utterance}: {escape(action.source_quote)}",
                "",
            ]
        )
    lines.extend(["## Source transcript", ""])
    for cue in cues:
        stamp = f"[{cue.start_secs:.3f}s] " if cue.start_secs is not None else ""
        speaker = f"{cue.speaker}: " if cue.speaker else ""
        lines.extend([escape(stamp + speaker + cue.text), ""])
    return "\n".join(lines)
