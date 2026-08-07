#!/usr/bin/env python3
"""Visual coverage matrix (Track E) — a STATIC capability map of the visual
verification stack: every registered shot x its rubric group x the reviewer
kinds capable of answering each rubric question x the art-anchor registry.

No Godot run, no model: everything is computed from committed sources —
  - scripts/app/visual_sweep_baselines.gd SHOT_REGISTRY (parsed via the
    check_repo_contracts parser, single-sourced)
  - docs/generated/visual-baselines/ (committed PNG + sidecar inventory)
  - docs/references/vision-review-rubric.md (parsed by vision_review)
  - vision_review.QUESTION_ANSWERERS / ANCHOR_SCENE_BY_GROUP
  - docs/registry/art-anchors.toml (via art_geometry)

When .godot-smoke/vision-review.json exists, a last-run ACTUALS section is
appended (kinds that ran, unanswered questions) — advisory, like the legibility
report's rubric section; the static matrix never depends on a run.

Usage:
  python3 tools/visual_coverage.py            # print the matrix (markdown)
  python3 tools/visual_coverage.py --json     # machine-readable
  python3 tools/visual_coverage.py --write    # regenerate docs/runbook/coverage-matrix.md
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
BASELINE_DIR = ROOT / "docs" / "generated" / "visual-baselines"
RUBRIC_PATH = ROOT / "docs" / "references" / "vision-review-rubric.md"
RUN_REVIEW_JSON = ROOT / ".godot-smoke" / "vision-review.json"
RUNBOOK_DOC = ROOT / "docs" / "runbook" / "coverage-matrix.md"

def _letter(kind: str) -> str:
    """Reviewer kind -> matrix letter. Pure function of the kind string (the
    constants are stable vision-review contract values), so rendering needs no
    module state."""
    return {"deterministic-sidecar-consistency": "D",
            "deterministic-art-anchor": "A",
            "model-vision-llm": "M"}.get(kind, "?")


def _load(name: str, path: Path):
    """Sanctioned importlib load of a sibling tool (the vision_review pattern)."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _shot_inventory(contracts, vr) -> list[dict]:
    """Registered shots x committed baselines. Registry ranges expand inclusive
    (+ extra), mirroring visual_sweep_baselines.shot_numbers; retired numbers
    are reported only when a baseline file exists for one (never — the
    contracts gate REDs first)."""
    registry, error = contracts._parse_shot_registry(ROOT)
    if error or registry is None:
        raise RuntimeError(f"SHOT_REGISTRY: {error or 'absent'}")
    baselines = {p.name: p for p in BASELINE_DIR.glob("*.png")}
    rows: list[dict] = []
    for sweep, entry in registry.items():
        if sweep == "retired" or not isinstance(entry, dict):
            continue
        numbers = list(range(int(entry["range"][0]), int(entry["range"][1]) + 1))
        numbers += [int(n) for n in entry.get("extra", [])]
        for n in numbers:
            matches = [name for name in baselines if name.startswith(f"{n:02d}_")]
            name = matches[0] if matches else f"{n:02d}_MISSING.png"
            rows.append({
                "number": n, "shot": name, "sweep": sweep,
                "group": vr._shot_group(name),
                "baseline": bool(matches),
                "sidecar": bool(matches) and (BASELINE_DIR / (matches[0] + ".sidecar.json")).is_file(),
            })
    rows.sort(key=lambda r: r["number"])
    return rows


def _question_matrix(vr) -> dict[str, list[dict]]:
    """Per rubric group: each question with its capable reviewer kinds."""
    questions = vr.parse_rubric_questions(RUBRIC_PATH.read_text(encoding="utf-8"))
    matrix: dict[str, list[dict]] = {}
    for group, items in questions.items():
        matrix[group] = [{
            "id": q["id"], "text": q["text"],
            "kinds": vr.answerers_for(group, q["text"]),
        } for q in items]
    return matrix


def _anchor_matrix(vr, art_geometry) -> list[dict]:
    """Per anchored scene: group mapping + anchor ids + waived overlay nodes."""
    scene_to_group: dict[str, str] = {}
    for group, scenes in (vr.ANCHOR_SCENE_BY_GROUP or {}).items():
        for scene in ([scenes] if isinstance(scenes, str) else list(scenes)):
            scene_to_group[str(scene)] = group
    by_scene: dict[str, dict] = {}
    for anchor in art_geometry.load_registry(ROOT):
        scene = str(anchor.get("scene", ""))
        entry = by_scene.setdefault(scene, {"scene": scene, "anchors": [], "waived": []})
        entry["anchors"].append(str(anchor.get("id", "?")))
    # registry [[scenes]] blocks carry the waive lists; load_registry flattens
    # anchors only, so read the TOML for waivers.
    try:
        import tomllib
        doc = tomllib.loads((ROOT / "docs" / "registry" / "art-anchors.toml").read_text(encoding="utf-8"))
        for scene_block in doc.get("scenes", []):
            scene = str(scene_block.get("scene", ""))
            if scene in by_scene:
                by_scene[scene]["waived"] = [str(w) for w in scene_block.get("waive", [])]
            elif scene:
                by_scene[scene] = {"scene": scene, "anchors": [], "waived": [str(w) for w in scene_block.get("waive", [])]}
    except (OSError, ValueError):
        # Waivers are advisory display data; an unreadable registry renders as
        # UNKNOWN, never as a false "no waivers".
        for row in by_scene.values():
            row["waived"] = None
    rows = list(by_scene.values())
    for row in rows:
        row["group"] = scene_to_group.get(row["scene"], "")
    rows.sort(key=lambda r: r["scene"])
    return rows


def _last_run_actuals(vr) -> dict | None:
    """Advisory last-run column from .godot-smoke/vision-review.json (kinds that
    ran + unanswered questions). None when absent/stale — the static matrix
    must never depend on a run artifact."""
    try:
        doc = json.loads(RUN_REVIEW_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get("schema") != "vision-review/2":
        return None
    coverage = doc.get("rubric_coverage") or {}
    groups = {}
    for gdoc in coverage.get("groups") or []:
        if isinstance(gdoc, dict) and gdoc.get("group"):
            groups[str(gdoc["group"])] = {
                "answered": int(gdoc.get("questions_answered") or 0),
                "unanswered": len(gdoc.get("unanswered") or []),
                "reviewer_kinds": sorted(gdoc.get("reviewer_kinds") or []),
            }
    return {
        "generated_at": doc.get("generated_at"),
        "head_sha": doc.get("head_sha"),
        "reviewer_kinds": sorted(coverage.get("reviewer_kinds_ran") or []),
        "groups": groups,
    }


def build() -> dict:
    vr = _load("vision_review", TOOLS / "vision_review.py")
    contracts = _load("check_repo_contracts", TOOLS / "check_repo_contracts.py")
    art_geometry = _load("art_geometry", TOOLS / "art_geometry.py")
    return {
        "shots": _shot_inventory(contracts, vr),
        "questions": _question_matrix(vr),
        "anchors": _anchor_matrix(vr, art_geometry),
        "last_run": _last_run_actuals(vr),
    }


def _letters(kinds: list[str]) -> str:
    return "".join(_letter(k) for k in kinds) or "—"


def render_markdown(matrix: dict) -> str:
    out: list[str] = []
    out.append("Status: current")
    out.append(f"Last verified: {date.today().isoformat()}")
    out.append("Review cadence days: 21")
    out.append("Source paths: scripts/app/visual_sweep_baselines.gd, "
               "docs/generated/visual-baselines, docs/references/vision-review-rubric.md, "
               "tools/vision_review.py, docs/registry/art-anchors.toml, tools/visual_coverage.py")
    out.append("")
    out.append("# Visual coverage matrix")
    out.append("")
    out.append("Generated by `tools/visual_coverage.py --write` — regenerate after any "
               "shot-registry, rubric, answerer, or art-anchor change. Static capability "
               "map: which reviewer kinds CAN answer each rubric question (D = "
               "deterministic sidecar, A = art anchor, M = model vision), not what a "
               "specific run did (see the last-run section when present).")
    out.append("")
    out.append("## Shot inventory")
    out.append("")
    out.append("| # | shot | sweep | rubric group | baseline | sidecar |")
    out.append("|---|------|-------|--------------|----------|---------|")
    for row in matrix["shots"]:
        out.append("| {number} | {shot} | {sweep} | {group} | {base} | {side} |".format(
            number=row["number"], shot=row["shot"], sweep=row["sweep"], group=row["group"],
            base="yes" if row["baseline"] else "**MISSING**",
            side="yes" if row["sidecar"] else "no"))
    out.append("")
    out.append("## Rubric answerer capability")
    for group, questions in matrix["questions"].items():
        out.append("")
        out.append(f"### {group} ({len(questions)} questions)")
        out.append("")
        out.append("| question | kinds |")
        out.append("|----------|-------|")
        for q in questions:
            text = q["text"] if len(q["text"]) <= 90 else q["text"][:87] + "..."
            out.append(f"| {text} | {_letters(q['kinds'])} |")
    out.append("")
    out.append("## Art-anchor registry")
    out.append("")
    out.append("| scene | shot group | anchors | waived overlays |")
    out.append("|-------|-----------|---------|-----------------|")
    for row in matrix["anchors"]:
        waived = "?" if row["waived"] is None else (", ".join(row["waived"]) or "—")
        out.append("| {scene} | {group} | {n} | {waived} |".format(
            scene=row["scene"], group=row["group"] or "—",
            n=len(row["anchors"]), waived=waived))
    last = matrix.get("last_run")
    if last:
        out.append("")
        out.append("## Last-run actuals (advisory)")
        out.append("")
        out.append(f"From `.godot-smoke/vision-review.json` ({last.get('generated_at')}, "
                   f"head {str(last.get('head_sha'))[:8]}).")
        out.append("")
        out.append("| group | answered | unanswered |")
        out.append("|-------|----------|------------|")
        for group, counts in sorted(last["groups"].items()):
            out.append(f"| {group} | {counts['answered']} | {counts['unanswered']} |")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Visual coverage matrix (static capability + advisory last-run actuals)")
    parser.add_argument("--json", action="store_true", help="print the matrix as JSON")
    parser.add_argument("--write", action="store_true", help=f"regenerate {RUNBOOK_DOC.relative_to(ROOT)}")
    args = parser.parse_args()

    matrix = build()
    if args.json:
        print(json.dumps(matrix, indent=2, sort_keys=True))
        return 0
    markdown = render_markdown(matrix)
    if args.write:
        RUNBOOK_DOC.parent.mkdir(parents=True, exist_ok=True)
        RUNBOOK_DOC.write_text(markdown, encoding="utf-8")
        print(f"wrote {RUNBOOK_DOC.relative_to(ROOT)}")
        return 0
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
