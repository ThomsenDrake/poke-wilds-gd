#!/usr/bin/env python3
"""Shared review-context enrichment for the vision-review pipeline.

Single canonical home for the prior-findings / legibility-lines loaders, the
prompt-block formatters, and the per-group specialist lens. Three consumers:

  - tools/vision_review.py         writer: enriches context.json at bundle assembly
  - tools/vlm_reviewer.py          reader: prefers the enriched public_ctx, falls
                                   back to these loaders for standalone invocation
  - tools/commandcode_play_agent.py bundle: prior findings for the plan agent

Loaders are best-effort and NEVER raise: absent/unreadable files degrade to
empty. Outputs are capped (default 8 entries, 160-char explanations, 240-char
lines) so context.json and prompts stay bounded. Stdlib-only.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Compact finding keys carried into prompts/bundles (explanation truncated separately).
PRIOR_FINDING_KEYS = ("finding_id", "class", "region_id", "severity", "confidence", "note")

# Contrast/CVD relevance keywords for legibility-report lines.
_LEGIBILITY_KEYWORDS = ("ratio", "contrast", "cvd", "collapse", "deutan", "protan",
                        "tritan", "canary", "deltae", "wcag")

# Per-group specialist focus (Track C.1): one cmd invocation still answers the
# shot's own group questions, but the system prompt scopes judgment to the
# group's specialty so menu/overworld/battle reviewers don't dilute.
SPECIALIST_FOCUS = {
    "menu": ("SPECIALIST LENS — MENU/TYPOGRAPHY: prioritize layout grid alignment, "
             "plate margins, clipped/overlapping labels, cursor-to-row centering, "
             "kerning, and GBC plate readability. Ignore overworld terrain."),
    "overworld": ("SPECIALIST LENS — OVERWORLD: prioritize terrain/foliage continuity, "
                  "y-sort of props vs player vs mons, floating sprites, nest ring "
                  "legibility, and day/night tint honesty. Ignore battle HUD geometry."),
    "battle": ("SPECIALIST LENS — BATTLE HUD: prioritize HP track seating, name/level "
               "plate readability, cursor-to-row centering, message-box framing, and "
               "sprite strip-bleed. Ignore overworld y-sort."),
    "overworld_mons": ("SPECIALIST LENS — OVERWORLD MONS: prioritize roaming mon y-sort "
                       "against props/player, nest-ring + egg + Alpha-badge legibility, "
                       "and species-sprite integrity (no blank tiles)."),
    "camping": ("SPECIALIST LENS — CAMPING: prioritize campfire/torch glow over night "
                "tint and craft-menu recipe/ingredient legibility."),
    "day_night": ("SPECIALIST LENS — DAY/NIGHT: prioritize uniform night tint and "
                  "readable HUD under dimming."),
    "display_matrix": ("SPECIALIST LENS — DISPLAY MATRIX: prioritize pixel-crisp text "
                       "at every window size and centered surface margins."),
    "satellite": ("SPECIALIST LENS — SATELLITE SWEEP: prioritize focal-content presence, "
                  "clipping/stretch, and untextured ghost blobs."),
}


def specialist_block(group: str | None) -> str:
    """The group's SPECIALIST LENS prompt line, or "" for unknown/absent groups."""
    return SPECIALIST_FOCUS.get(str(group or ""), "")


def _first_readable(dirs: list[Path], filename: str) -> Path | None:
    for d in dirs:
        try:
            cand = Path(d) / filename
            if cand.is_file():
                return cand
        except (OSError, TypeError, ValueError):
            continue
    return None


def load_prior_findings(shot_name: str, *dirs: Path, limit: int = 8) -> list[dict]:
    """Prior vision-review.json findings for this shot (filtered by stem).

    Searches `dirs` in order for vision-review.json; ROOT/.godot-smoke is always
    the final fallback. Each entry is a compact summary (PRIOR_FINDING_KEYS +
    a 160-char explanation) so the bundle stays small while the model sees
    known false positives. [] when absent/unreadable. Never raises."""
    try:
        stem = Path(str(shot_name)).stem
        if not stem:
            return []
        path = _first_readable(list(dirs) + [ROOT / ".godot-smoke"], "vision-review.json")
        if path is None:
            return []
        doc = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            return []
        out: list[dict] = []
        for entry in doc.get("shots") or []:
            if not isinstance(entry, dict):
                continue
            if Path(str(entry.get("shot") or "")).stem != stem:
                continue
            for f in entry.get("findings") or []:
                if not isinstance(f, dict):
                    continue
                compact = {k: f[k] for k in PRIOR_FINDING_KEYS if f.get(k) is not None}
                if isinstance(f.get("explanation"), str) and f["explanation"]:
                    compact["explanation"] = str(f["explanation"])[:160]
                out.append(compact)
                if len(out) >= limit:
                    return out
        return out
    except Exception:
        return []


def load_legibility_lines(shot_name: str, *dirs: Path, limit: int = 8) -> list[str]:
    """Legibility-report.md contrast/CVD lines mentioning this shot.

    Searches `dirs` in order for legibility-report.md; ROOT/.godot-smoke is
    always the final fallback. Keeps canary/label contrast + CVD collapse lines
    (name or stem must appear), stripped of list bullets, capped at 240 chars.
    [] when absent/unparseable. Never raises."""
    try:
        name = str(shot_name)
        stem = Path(name).stem
        if not stem:
            return []
        path = _first_readable(list(dirs) + [ROOT / ".godot-smoke"], "legibility-report.md")
        if path is None:
            return []
        out: list[str] = []
        for raw in path.read_text(encoding="utf-8").splitlines():
            if stem not in raw and name not in raw:
                continue
            stripped = raw.strip()
            if stripped.startswith(("- ", "* ")):
                stripped = stripped[2:].strip()
            if not stripped:
                continue
            if len(stripped) > 240:
                stripped = stripped[:237] + "..."
            out.append(stripped)
            if len(out) >= limit:
                break
        return out
    except Exception:
        return []


def format_prior_block(prior: list[dict], max_rows: int = 4) -> str:
    """Prompt block for prior findings; "" when empty (no block, no noise)."""
    if not prior:
        return ""
    rows: list[str] = []
    for f in prior[:max_rows]:
        rows.append("- [%s/%s] %s: %s (id %s)" % (
            str(f.get("class") or "?"), str(f.get("severity") or ""),
            str(f.get("region_id") or "?"), str(f.get("note") or "")[:80],
            str(f.get("finding_id") or "")[:12]))
    return ("PRIOR FINDINGS FOR THIS SHOT (from .godot-smoke/vision-review.json, filtered by shot stem; "
            "these are quarantined history — known false positives may be among them; do NOT repeat a prior "
            "false positive without fresh visual evidence):\n" + "\n".join(rows)[:900])


def format_legibility_block(lines: list[str], max_lines: int = 6) -> str:
    """Prompt block for legibility lines; "" when empty (no block, no noise)."""
    if not lines:
        return ""
    body = "\n".join("- %s" % line for line in lines[:max_lines])[:900]
    return ("LEGIBILITY (from .godot-smoke/legibility-report.md, canary/label contrast + CVD collapse lines "
            "mentioning this shot; use as accessibility context, not a verdict):\n" + body)
