#!/usr/bin/env python3
"""Art-anchor gate: registry completeness + source-art freshness + live-respect.

The mechanical check behind docs/registry/art-anchors.toml (spec:
docs/product-specs/vision-fidelity.md § Source-art anchor registry). Three
concerns, tiered per the house style:

  RED (blocks; art_anchor_issues folds into check_repo_contracts.run):
    - registry schema violations (malformed rect, unknown derivation/element_kind,
      duplicate id, attested-without-attestation-block, missing
      source_art/art_sha256/nodes);
    - art_sha256 != recorded pin (the art moved under the registry -- pokewilds/ is
      a submodule whose contents are not individually tracked here, so the sha is
      the art-change enforcement; mismatch forces a deliberate re-derivation);
    - recomputed derivation != stage_rect (declared-but-stale anchor / typo). The
      derivation is a deterministic integer function of the art bytes, so any
      delta is a stale entry, never art 'drifting quietly'.
    - answers_questions label not a live KIND_ART_ANCHOR fingerprint (the G1->G2
      bridge field is load-bearing: cross-validated against vision_review.
      QUESTION_ANSWERERS so it cannot rot silently while the real bridge is
      enforced there).

  ADVISORY (counted, surfaced, never fails the gate):
    - un-anchored, un-waived overlay nodes (pre-graduation coverage gap -- the
      mechanized pilot _review row); the rule arms once >=1 anchor exists, so the
      current tree is not a wave of false reds (progressive arming, mirrors
      region_coverage_issues' have_any_sidecar);
    - attested anchor past reverify_by (re-attest cadence).

  LIVE-RESPECT (baseline-regeneration refusal; live_violations):
    - read a FRESH sidecar's draw_order rect for each anchored node (stage-px --
      the SAME space as stage_rect, zero mapping in the comparison) and assert
      within tol_px. Invoked from run_playtests.apply_anchor_gate to REFUSE a
      baseline regeneration that would freeze a misalignment, and from --live for
      plants/audits. Anchored nodes the sidecar does not expose are reported
      UNVERIFIABLE, never silently passed. NOTE: since render_introspection's
      RECURSIVE battle draw_order collection landed, BOTH seeded battle bars are
      verifiable on any fresh battle sidecar (the nested PlayerHUD/PlayerHPBar too)
      -- UNVERIFIABLE is obsolete for them but stays correct for future anchors
      registered ahead of their scene's collection support, and for pre-collection
      sidecars (e.g. one captured before the recursion existed).

Stdlib-only CORE tool: geometry/derivation live in tools/art_geometry.py (loaded
via the sanctioned importlib pattern); the PNG decoder is art_geometry's
importlib load of visual_diff.decode_png_rgba. OPTIONAL_TOOL_EXEMPTIONS stays
pinned to {vision_metrics.py}.

CLI: default runs the RED + advisory checks (exit 1 on any RED issue).
     --live SIDECAR.json runs live-respect against one sidecar (exit 1 on drift).
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def format_issues(issues: list[str]) -> str:
    """Same one-line-per-issue renderer as legibility_lib.format_issues, inlined
    so this tool stays self-contained when importlib-loaded from a runner whose
    sys.path[0] is not tools/ (the runner loads it via spec_from_file_location)."""
    return "\n".join(f"- {issue}" for issue in issues)


_AG_PATH = Path(__file__).resolve().with_name("art_geometry.py")
_spec = importlib.util.spec_from_file_location("art_geometry", _AG_PATH)
if _spec is None or _spec.loader is None:
    raise SystemExit(f"cannot load art_geometry from {_AG_PATH}")
art_geometry = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(art_geometry)


def _valid_rect(rect) -> bool:
    return (isinstance(rect, list) and len(rect) == 4
            and all(isinstance(v, int) for v in rect)
            and rect[2] > 0 and rect[3] > 0)


def _parse_date(text: str) -> datetime.date | None:
    try:
        return datetime.date.fromisoformat(str(text))
    except (ValueError, TypeError):
        return None


_VR_PATH = Path(__file__).resolve().with_name("vision_review.py")


def _load_vision_review():
    """importlib-load the sibling vision_review (the sanctioned pattern, same as
    art_geometry above) so the answers_questions bridge field can be cross-
    validated against the enforced QUESTION_ANSWERERS map. None if unavailable --
    that module's integrity is independently RED-guarded by check_repo_contracts.
    rubric_question_inventory_issues, which loads the SAME module, so a load
    failure degrades both checks in lockstep (never a silent one-sided bypass)."""
    try:
        spec = importlib.util.spec_from_file_location("vision_review", _VR_PATH)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:  # a load error here must not mask the schema/freshness REDs
        return None


def _answers_questions_issues(anchors: list[dict]) -> list[str]:
    """RED: `answers_questions` is the documented G1->G2 bridge field -- make it
    LOAD-BEARING so it cannot rot silently while the real bridge is enforced
    elsewhere. Each label must be a rubric question FINGERPRINT that
    vision_review.QUESTION_ANSWERERS actually assigns to KIND_ART_ANCHOR for the
    anchor's shot group (the SAME content-based join key the coverage ledger and
    the KIND_ART_ANCHOR self-tag use). A label that matches no art-anchor-
    answerable fingerprint is drift (a stale claim, or the bridge removed under
    the registry) and fires RED. Composes with rubric_inventory_issues
    (check_repo_contracts), which separately enforces that each
    QUESTION_ANSWERERS fingerprint still matches a parsed rubric question -- so
    registry label == live fingerprint == live question is RED-protected end to
    end (a rubric reword RED-fires both, never rots one side unnoticed)."""
    vision_review = _load_vision_review()
    if vision_review is None:
        return []
    scene_to_group = {scene: group
                      for group, scene in (vision_review.ANCHOR_SCENE_BY_GROUP or {}).items()}
    answerable_by_group: dict[str, set[str]] = {}
    for group, decls in (vision_review.QUESTION_ANSWERERS or {}).items():
        answerable_by_group[group] = {fp for fp, kinds in decls
                                      if vision_review.KIND_ART_ANCHOR in kinds}
    issues: list[str] = []
    for anchor in anchors:
        labels = anchor.get("answers_questions")
        if labels is None:
            continue  # optional field: absence makes no claim, never an error
        aid = anchor.get("id", "<no-id>")
        if not (isinstance(labels, list) and labels
                and all(isinstance(l, str) and l for l in labels)):
            issues.append(f"art-anchor `{aid}`: `answers_questions` must be a non-empty "
                          f"list of rubric question fingerprints (got {labels!r})")
            continue
        group = scene_to_group.get(str(anchor.get("scene", "")))
        if group is None:
            issues.append(f"art-anchor `{aid}`: `answers_questions` set but scene "
                          f"`{anchor.get('scene')}` maps to no rubric shot group "
                          f"(extend vision_review.ANCHOR_SCENE_BY_GROUP deliberately)")
            continue
        valid = answerable_by_group.get(group, set())
        for label in labels:
            if label not in valid:
                issues.append(
                    f"art-anchor `{aid}`: answers_questions label '{label}' is not a "
                    f"rubric question fingerprint that `{vision_review.KIND_ART_ANCHOR}` "
                    f"answers in group '{group}' — the G1->G2 bridge drifted; re-map the "
                    f"label to a live QUESTION_ANSWERERS fingerprint (or drop the field)")
    return issues


def _schema_issues(anchors: list[dict]) -> list[str]:
    issues: list[str] = []
    seen_ids: set[str] = set()
    for anchor in anchors:
        aid = anchor.get("id")
        if not aid or not isinstance(aid, str):
            issues.append("art-anchor: an entry is missing a string `id`")
            continue
        if aid in seen_ids:
            issues.append(f"art-anchor `{aid}`: duplicate id in the registry")
        seen_ids.add(aid)
        # art_sha256 is required, not optional: it is the anti-fossilization pin
        # the freshness check asserts (pokewilds/ is a submodule whose contents
        # are not individually tracked here). An entry added without a pin would
        # silently lose the art-change enforcement the registry exists to give.
        for key in ("scene", "source_art", "stage_rect", "derivation", "art_sha256"):
            if key not in anchor:
                issues.append(f"art-anchor `{aid}`: missing required key `{key}`")
        pin = anchor.get("art_sha256")
        if "art_sha256" in anchor and not (isinstance(pin, str) and len(pin) == 64
                                           and all(c in "0123456789abcdef" for c in pin)):
            issues.append(f"art-anchor `{aid}`: `art_sha256` must be a 64-char lowercase "
                          f"hex sha256 pin (got {pin!r})")
        nodes = anchor.get("nodes")
        if not (isinstance(nodes, list) and nodes and all(isinstance(n, str) for n in nodes)):
            issues.append(f"art-anchor `{aid}`: `nodes` must be a non-empty list of node ids")
        rect = anchor.get("stage_rect")
        if "stage_rect" in anchor and not _valid_rect(rect):
            issues.append(f"art-anchor `{aid}`: `stage_rect` must be [x,y,w,h] positive integers (got {rect!r})")
        derivation = anchor.get("derivation")
        if derivation is not None and derivation not in art_geometry.KNOWN_DERIVATIONS:
            issues.append(f"art-anchor `{aid}`: unknown derivation `{derivation}` "
                          f"(expected one of {', '.join(art_geometry.KNOWN_DERIVATIONS)})")
        kind = anchor.get("element_kind")
        if kind is not None and kind not in art_geometry.KNOWN_ELEMENT_KINDS:
            issues.append(f"art-anchor `{aid}`: unknown element_kind `{kind}` "
                          f"(expected one of {', '.join(art_geometry.KNOWN_ELEMENT_KINDS)})")
        if derivation == "attested":
            attestation = anchor.get("attestation")
            if not isinstance(attestation, dict):
                issues.append(f"art-anchor `{aid}`: derivation `attested` requires an [anchors.attestation] block")
            else:
                for key in ("by", "date", "rationale", "reverify_by"):
                    if not attestation.get(key):
                        issues.append(f"art-anchor `{aid}`: attestation is missing `{key}`")
    return issues


def _freshness_issues(root: Path, anchors: list[dict]) -> list[str]:
    """RED: art sha pin + recompute==stage_rect. Art moving under the registry or
    a stale transcription both fire here -- provenance lives in the check."""
    issues: list[str] = []
    for anchor in anchors:
        aid = anchor.get("id", "<no-id>")
        rel = anchor.get("source_art")
        if not rel:
            continue
        path = art_geometry.art_path(root, anchor)
        if not path.exists():
            issues.append(f"art-anchor `{aid}`: source art missing: {rel}")
            continue
        pin = anchor.get("art_sha256")
        actual = art_geometry.sha256_hex(path)
        if not pin:
            issues.append(f"art-anchor `{aid}`: art_sha256 pin missing — the freshness "
                          "assertion cannot run without it (schema RED also fires)")
        elif actual != pin:
            issues.append(
                f"art-anchor `{aid}`: art_sha256 mismatch for {rel} "
                f"(registry {str(pin)[:12]}… vs art {actual[:12]}…) — the art changed under the "
                "registry; re-derive the anchor deliberately and update the pin")
        if anchor.get("derivation") in art_geometry.RECOMPUTABLE:
            derived = art_geometry.derive_rect(path, anchor)
            rect = anchor.get("stage_rect")
            if derived is None:
                issues.append(f"art-anchor `{aid}`: derivation `{anchor.get('derivation')}` found no feature "
                              f"in {rel} with the pinned params (derivation_params stale or art changed)")
            elif derived != rect:
                issues.append(
                    f"art-anchor `{aid}`: recomputed stage_rect {derived} != registry {rect} "
                    f"({anchor.get('derivation')} on {rel}) — declared-but-stale anchor; update stage_rect to the "
                    "art-derived value")
    return issues


def art_anchor_issues(root: Path = ROOT) -> list[str]:
    """RED static gate, folded into check_repo_contracts.run(). Schema + art
    freshness. Absent registry = no issues (arms once the file exists)."""
    anchors = art_geometry.load_registry(root)
    if not anchors:
        return []
    return (_schema_issues(anchors) + _freshness_issues(root, anchors)
            + _answers_questions_issues(anchors))


def art_anchor_advisories(root: Path = ROOT, today: datetime.date | None = None) -> list[str]:
    """Counted advisories (never fail the gate): un-anchored overlay nodes +
    expired attestation. The completeness rule arms once >=1 anchor exists."""
    today = today or datetime.date.today()
    anchors = art_geometry.load_registry(root)
    advisories: list[str] = []
    if not anchors:
        return []  # not armed: no anchors registered yet

    # expired attestation (re-attest cadence)
    for anchor in anchors:
        attestation = anchor.get("attestation") or {}
        reverify = _parse_date(attestation.get("reverify_by", ""))
        if reverify and reverify < today:
            advisories.append(
                f"art-anchor `{anchor.get('id')}`: attestation expired {attestation.get('reverify_by')} — re-attest")

    # completeness: every overlay node in a declared art scene must be anchored
    # or waived. Uncovered nodes are the honest coverage-gap list (never faked).
    anchored_by_scene: dict[str, set[str]] = {}
    for anchor in anchors:
        anchored_by_scene.setdefault(str(anchor.get("scene", "")), set()).update(anchor.get("nodes") or [])
    for scene in art_geometry.load_scenes(root):
        scene_path = Path(root) / str(scene.get("scene", ""))
        if not scene_path.exists():
            advisories.append(f"art-anchor scene `{scene.get('scene')}`: scene file missing — cannot scan overlay inventory")
            continue
        inventory = art_geometry.overlay_inventory(
            scene_path, str(scene.get("stage", "")), list(scene.get("overlay_types") or []))
        covered = anchored_by_scene.get(str(scene.get("scene", "")), set()) | set(scene.get("waive") or [])
        uncovered = [node for node in inventory if node not in covered]
        if uncovered:
            advisories.append(
                f"art-anchor coverage: {len(uncovered)} overlay node(s) in {scene.get('scene')} are not art-anchored "
                f"(advisory; anchor or waive each): {', '.join(uncovered)}")
    return advisories


# --------------------------------------------------------------------------
# live-respect (baseline-regeneration refusal + --live audits)
# --------------------------------------------------------------------------
def _draw_order_rects(sidecar: dict) -> dict[str, list[int]]:
    """node id -> stage-px rect, for draw_order entries with a non-empty rect."""
    out: dict[str, list[int]] = {}
    for node in sidecar.get("draw_order") or []:
        if not (isinstance(node, dict) and node.get("node")):
            continue
        rect = node.get("rect")
        if isinstance(rect, list) and len(rect) == 4 and any(rect):
            out[str(node["node"])] = [int(v) for v in rect]
    return out


def live_violations(sidecar: dict, root: Path = ROOT) -> tuple[list[dict], list[dict]]:
    """Compare each anchored node's sidecar draw_order rect to its stage_rect
    (stage-to-stage, NO mapping). Returns (violations, unverifiable):
      violations   — anchored node present in draw_order but off its anchor (>tol)
      unverifiable — anchored node absent from draw_order (live-respect cannot
                     confirm; reported, never silently passed)
    Only anchors whose scene nodes are in this sidecar's shot are considered; an
    anchor for a node that never appears in a given shot is simply not checked
    there (the node-keyed lookup is the scope)."""
    rects = _draw_order_rects(sidecar)
    violations: list[dict] = []
    unverifiable: list[dict] = []
    for anchor in art_geometry.load_registry(root):
        aid = anchor.get("id", "<no-id>")
        rect = anchor.get("stage_rect")
        tol = int(anchor.get("tol_px", 1))
        if not _valid_rect(rect):
            continue
        for node_id in anchor.get("nodes") or []:
            if node_id not in rects:
                # only flag unverifiable when SOME draw_order exists (a shot with
                # no draw_order at all, e.g. a menu shot, simply isn't this anchor's
                # scene) and the anchor's scene matches the shot's battle HUD.
                if rects:
                    unverifiable.append({"id": aid, "node": node_id, "stage_rect": rect})
                continue
            live = rects[node_id]
            if not art_geometry.rects_close(live, rect, tol):
                violations.append({"id": aid, "node": node_id, "stage_rect": rect,
                                   "live_rect": live, "tol_px": tol})
    return violations, unverifiable


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", type=Path, metavar="SIDECAR.json",
                        help="run live-respect against one sidecar (exit 1 on drift)")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()

    if args.live:
        try:
            sidecar = json.loads(Path(args.live).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"error: cannot read sidecar {args.live}: {exc}", file=sys.stderr)
            return 2
        violations, unverifiable = live_violations(sidecar, args.root)
        for item in unverifiable:
            print(f"  advisory: anchor {item['id']} node {item['node']} not in draw_order — "
                  f"live-respect unverifiable for this sidecar")
        if violations:
            print("art-anchor live-respect FAILED:")
            for item in violations:
                print(f"- anchor {item['id']} ({item['node']}): live {item['live_rect']} violates "
                      f"art anchor {item['stage_rect']} (tol {item['tol_px']}px) — fix the alignment, not the baseline")
            return 1
        print(f"art-anchor live-respect passed ({args.live.name}).")
        return 0

    issues = art_anchor_issues(args.root)
    advisories = art_anchor_advisories(args.root)
    for advisory in advisories:
        print(f"advisory: {advisory}", file=sys.stderr)
    if issues:
        print("Art-anchor check failed:")
        print(format_issues(issues))
        return 1
    print(f"Art-anchor check passed. ({len(advisories)} advisory)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
