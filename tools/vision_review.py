#!/usr/bin/env python3
"""Lane-4 vision review: grounded, agent-legible findings over visual-sweep shots.

Assembles, per CHANGED shot, a review bundle (full-frame before/after pair,
native-resolution crops of every diff cluster, numbered Set-of-Mark overlays,
the expected-strings manifest, the rubric section, and a region table), then
runs a reviewer over it. The DEFAULT reviewer is a DETERMINISTIC sidecar-
consistency checker -- a pure function of the sidecar + clusters bytes -- so the
pipeline runs with NO model and is CI-safe; --reviewer-cmd plugs in an external
reviewer (stdin JSON of bundle paths + context, stdout {"findings":[...]}).

ENFORCEMENT (pipeline-side, runs after ANY reviewer, before the file is written):
a finding is grounded iff it cites a region_id resolvable in the shot's region
table AND its bbox passes visual_explain.rects_overlap against >=1 rect
registered to that id. Ungrounded/invalid findings are dropped and counted; the
emitted array is grounded by construction. Findings are QUARANTINE-tier: this
tool exits 0 on completion and 2 only on a tool error (bad PNG decode, unwritable
output). It writes .godot-smoke/vision-review.json, unconditionally replacing the
stale pilot, with a shot-hash manifest that is the freshness authority.

Stdlib-only. Reuses visual_diff.decode_png_rgba, png_canvas,
visual_explain.rects_overlap, and art_geometry via the sanctioned importlib pattern
(never forked).

ANCHOR BRIDGE (the G1<->G2 join): for shots of an anchored scene group the region
table gains anchor:<id> entries -- art-anchors.toml stage_rects (loaded via
art_geometry) mapped stage->display by the existing _stage_to_display home -- and
the default reviewer gains the anchor_drift class (reviewer_kind
deterministic-art-anchor, quarantine-tier): each anchored node with a live
draw_order rect is compared stage-to-stage to its anchor within the registry
tol_px; drift emits a finding grounded by construction (bbox = the enclosing
rect of the live mapped rect and the registered anchor rect, so it intersects
the anchor rect for drifts of any magnitude), while nodes absent from
draw_order are counted UNVERIFIED, never findings.
The kind self-tags into the rubric-coverage ledger, so the HP-bar trigger question
registers answered whenever the pass runs -- even on a zero-drift tree.

RUBRIC-COVERAGE LEDGER: the manifest also carries a `rubric_coverage` block --
every shot-group's rubric questions parsed into a stable inventory, each mapped to
the reviewer KIND(S) that can answer it, recording per group which kinds ran a
FRESH pass and which questions are therefore answered. "Unanswered" is a first-
class COUNTED state (the mechanized pilot `_review` coverage-gap row), surfaced
advisory-loud (manifest warnings, legibility report, verify_all WARN) and NEVER
red. A RED question-inventory backstop (rubric_inventory_issues, folded into
check_repo_contracts) pins the inventory so a rubric edit cannot silently empty it.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
SCHEMA = "vision-review/2"
RUBRIC_REF = "docs/references/vision-review-rubric.md"
SEVERITIES = ("low", "medium", "high")
REVIEWER_TIMEOUT = 300
CROP_PAD = 8
EXIT_OK, EXIT_ERROR = 0, 2

# Reviewer kinds (shared by _mk, the anchor bridge, and the coverage ledger).
KIND_DETERMINISTIC = "deterministic-sidecar-consistency"  # this module's default reviewer
KIND_ART_ANCHOR = "deterministic-art-anchor"              # art-anchor drift class (G1<->G2 bridge)
KIND_MODEL = "model-qwen3-vl"                             # Qwen3-VL rubric reviewer (vlm slice)

# SoM outline colour per region kind; numbering is kind-priority then region-id.
# `anchor` rects are ART-TRUTH (art-anchors.toml), ranked above sidecar-derived kinds.
KIND_COLOR = {
    "canary": (255, 48, 48, 255),
    "string": (255, 200, 0, 255),
    "ink": (255, 200, 0, 255),
    "label": (255, 200, 0, 255),
    "cursor": (0, 220, 255, 255),
    "anchor": (0, 255, 128, 255),
    "draw": (160, 160, 160, 255),
    "palette:canary": (255, 0, 255, 255),
}
KIND_ORDER = {"cursor": 0, "string": 1, "label": 2, "ink": 3, "anchor": 4,
              "canary": 5, "draw": 6, "palette:canary": 7}

# Shot-group -> scene whose baked-art overlay nodes art-anchors.toml anchors; the
# region table carries anchor:<id> regions only for shots of that group.
ANCHOR_SCENE_BY_GROUP = {"battle": "scenes/ui/BattleView.tscn"}


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _valid_rect(rect) -> bool:
    return isinstance(rect, (list, tuple)) and len(rect) == 4 and int(rect[2]) > 0 and int(rect[3]) > 0


def _ri(rect) -> list[int]:
    return [int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])]


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _sidecar_for(png: Path) -> Path:
    return png.with_name(png.name + ".sidecar.json")


def _head_sha() -> str | None:
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                             text=True, timeout=5)
        sha = out.stdout.strip()
        return sha or None
    except (OSError, subprocess.SubprocessError):
        return None


# --------------------------------------------------------------------------
# battle_view stage->display mapping (documented integer-scale formula)
# --------------------------------------------------------------------------
def _battle_scale(window: list[int]) -> tuple[int, int, int]:
    w, h = window[0], window[1]
    k = min((w - 32) // 160, (h - 32) // 144)
    return max(1, k), (w - 160 * max(1, k)) // 2, (h - 144 * max(1, k)) // 2


def _stage_to_display(rect: list[int], window: list[int]) -> list[int]:
    k, ox, oy = _battle_scale(window)
    return [ox + rect[0] * k, oy + rect[1] * k, rect[2] * k, rect[3] * k]


_ART_GEOMETRY = None


def _art_geometry():
    """Sanctioned importlib load of tools/art_geometry.py (the single registry-parse
    + rect-tolerance home), cached -- the anchor bridge never re-parses TOML itself."""
    global _ART_GEOMETRY
    if _ART_GEOMETRY is None:
        _ART_GEOMETRY = _load("art_geometry", TOOLS / "art_geometry.py")
    return _ART_GEOMETRY


# --------------------------------------------------------------------------
# region table: union of fresh + baseline sidecars, addressed per regionIdSpace
# --------------------------------------------------------------------------
def _build_region_table(base: dict | None, fresh: dict | None, window: list[int],
                        group: str | None = None) -> dict:
    table: dict[str, dict] = {}

    def add(rid, kind, rect, source, meta=None):
        if not _valid_rect(rect):
            return
        rect = _ri(rect)
        entry = table.setdefault(rid, {"kind": kind, "rects": [], "sources": set(),
                                       "meta": meta or {}})
        if rect not in entry["rects"]:
            entry["rects"].append(rect)
        entry["sources"].add(source)
        if meta:
            entry["meta"].update(meta)

    for sidecar, source in ((base, "baseline"), (fresh, "fresh")):
        if not isinstance(sidecar, dict):
            continue
        canary = sidecar.get("canary_rect")
        if _valid_rect(canary) and any(canary):
            add("canary", "canary", canary, source)
            add("palette:canary", "palette:canary", canary, source)
        expected = sidecar.get("expected_regions") or {}
        for i, rect in enumerate(expected.get("ink") or []):
            add(f"ink:{i}", "ink", rect, source)
        for entry in expected.get("strings") or []:
            if isinstance(entry, dict) and entry.get("text"):
                add(f"string:{entry['text']}", "string", entry.get("region"), source,
                    {"text": str(entry["text"])})
        for i, label in enumerate(sidecar.get("labels") or []):
            if isinstance(label, dict):
                add(f"label:{i}", "label", label.get("display_rect"), source,
                    {"text": str(label.get("text", ""))})
        for pair in sidecar.get("cursor_pairs") or []:
            if not (isinstance(pair, dict) and pair.get("id")):
                continue
            rid = f"cursor:{pair['id']}"
            # groundable rect = cursor cell U row U live (ANY of the three counts;
            # row is groundable for citation even though it is not a diff mask).
            for key in ("cursor", "row", "live"):
                add(rid, "cursor", pair.get(key), source)
        for node in sidecar.get("draw_order") or []:
            if not (isinstance(node, dict) and node.get("node")):
                continue
            rect = node.get("rect")
            if _valid_rect(rect) and any(rect):  # overworld nodes carry rect [] -> ungroundable
                add(f"draw:{node['node']}", "draw", _stage_to_display(_ri(rect), window), source)

    # anchor:<id> -- the FIRST region kind whose rect is ART-TRUTH, not sidecar/code
    # output (the G1<->G2 bridge): the art-anchors.toml stage_rects for the shot's
    # scene group, mapped stage->display via the single _stage_to_display home, so
    # grounding + VLM citations resolve them like any other region. The meta carries
    # the stage-space truth the default reviewer's anchor_drift class compares to.
    scene = ANCHOR_SCENE_BY_GROUP.get(group) if group else None
    if scene:
        for anchor in _art_geometry().load_registry(ROOT):
            aid = anchor.get("id")
            rect = anchor.get("stage_rect")
            if anchor.get("scene") != scene or not (isinstance(aid, str) and aid and _valid_rect(rect)):
                continue
            add(f"anchor:{aid}", "anchor", _stage_to_display(_ri(rect), window), "registry",
                {"anchor_id": aid, "stage_rect": _ri(rect), "tol_px": int(anchor.get("tol_px", 0)),
                 "nodes": [str(n) for n in anchor.get("nodes") or []]})

    for entry in table.values():
        sources = entry.pop("sources")
        entry["source"] = "both" if len(sources) > 1 else next(iter(sources))
    return table


def _selfcheck_draw_cursor(table: dict) -> str | None:
    """Runtime cross-check: mapped draw:Cursor must equal a cursor_pairs live rect
    whenever both exist. Returns a warning string on mismatch, else None."""
    draw = table.get("draw:Cursor")
    if not draw:
        return None
    live_rects = [r for rid, e in table.items() if e["kind"] == "cursor" for r in e["rects"]]
    if live_rects and draw["rects"] and draw["rects"][0] not in live_rects:
        return ("draw:Cursor mapped rect %s matched no cursor_pairs live rect %s "
                "(battle_view mapping may be wrong)" % (draw["rects"][0], live_rects[:3]))
    return None


# --------------------------------------------------------------------------
# deterministic default reviewer (pure function of sidecar + clusters bytes)
# --------------------------------------------------------------------------
def _mk(shot, cls, region_id, bbox, severity, confidence, note, explanation, sidecar_ref,
        reviewer_kind=KIND_DETERMINISTIC):
    return {"shot": shot, "class": cls, "region_id": region_id, "bbox": _ri(bbox),
            "severity": severity, "confidence": confidence, "note": note,
            "explanation": explanation, "sidecar_ref": sidecar_ref,
            "reviewer_kind": reviewer_kind}


def _enclosing(rects: list[list[int]]) -> list[int]:
    x0 = min(r[0] for r in rects); y0 = min(r[1] for r in rects)
    x1 = max(r[0] + r[2] for r in rects); y1 = max(r[1] + r[3] for r in rects)
    return [x0, y0, x1 - x0, y1 - y0]


def _pair_rects(pair: dict) -> list[list[int]]:
    return [_ri(pair[k]) for k in ("cursor", "row", "live") if _valid_rect(pair.get(k))]


def _active_row(pair: dict) -> bool:
    """True when the pair's baseline live rect overlaps its own cursor cell -- i.e.
    the cursor physically selected this row (disambiguates the shared live cursor)."""
    cell, live = pair.get("cursor"), pair.get("live")
    if not (_valid_rect(cell) and _valid_rect(live)):
        return False
    return _rects_overlap(_ri(live), _ri(cell))


def default_reviewer(ctx: dict) -> list[dict]:
    """Every finding cites a region BY CONSTRUCTION (generated from a sidecar
    field; bbox = that field's rect). Emits nothing for byte-identical shots and
    nothing groundable for shots lacking regions (coverage counted, never faked)."""
    shot = ctx["shot"]
    base = ctx.get("baseline_sidecar") or {}
    fresh = ctx.get("fresh_sidecar") or {}
    clusters = ctx.get("clusters") or []
    findings: list[dict] = []

    # --- labels: matched by RAW ARRAY INDEX -- the SAME index space
    # _build_region_table keys label:{i} by (it enumerates the raw sidecar array and
    # skips non-dicts WITHOUT renumbering). Enumerating raw here too keeps a finding's
    # label:{i} resolvable in the region table even if a sidecar ever carries a
    # non-dict label entry; also disambiguates duplicate texts like the two
    # '35'/'DECIDUEYE' labels. ---
    base_labels = base.get("labels") or []
    fresh_labels = fresh.get("labels") or []
    # MULTASET of fresh label texts: a baseline occurrence counts as deleted only
    # when no UNMATCHED fresh occurrence of its text remains, so a deleted
    # DUPLICATE (baseline ['35','35'] -> fresh ['35']) fires ONE label_deleted
    # instead of going silent (a set-membership test would see '35' still present).
    fresh_remaining: dict[str, int] = {}
    for fl0 in fresh_labels:
        if isinstance(fl0, dict) and fl0.get("text"):
            t = str(fl0.get("text"))
            fresh_remaining[t] = fresh_remaining.get(t, 0) + 1
    for i, bl in enumerate(base_labels):
        if not isinstance(bl, dict):
            continue
        btext = str(bl.get("text", "")); brect = bl.get("display_rect")
        if not _valid_rect(brect):
            continue
        field = f"labels[{i}]"
        fl = fresh_labels[i] if i < len(fresh_labels) else None
        ftext = str(fl.get("text", "")) if isinstance(fl, dict) else None
        if ftext is None:
            if btext and fresh_remaining.get(btext, 0) <= 0:  # index gone AND no unmatched fresh occurrence -> deleted
                findings.append(_mk(shot, "label_deleted", f"label:{i}", brect, "medium", "high",
                                    f"label '{btext}' deleted",
                                    f"Baseline label[{i}] text '{btext}' was deleted: the fresh capture has "
                                    f"fewer occurrences of '{btext}' than the baseline.",
                                    {"source": "both", "field": f"{field}.text", "baseline": btext, "fresh": None}))
            elif btext:
                fresh_remaining[btext] -= 1  # absorbed by an off-index fresh label with the same text
            continue
        if ftext != btext:
            findings.append(_mk(shot, "label_text_changed", f"label:{i}", brect, "medium", "high",
                                f"label {i} text changed from '{btext}'",
                                f"Baseline label[{i}] text '{btext}' became '{ftext}' at the same index.",
                                {"source": "both", "field": f"{field}.text", "baseline": btext, "fresh": ftext}))
        else:
            if fresh_remaining.get(btext, 0) > 0:
                fresh_remaining[btext] -= 1  # same-index match consumes its fresh occurrence
            frect = fl.get("display_rect")
            if _valid_rect(frect) and _ri(frect) != _ri(brect):
                findings.append(_mk(shot, "label_moved", f"label:{i}", brect, "medium", "high",
                                    f"label '{btext}' moved",
                                    f"Label '{btext}' moved from {_ri(brect)} to {_ri(frect)}.",
                                    {"source": "both", "field": f"{field}.display_rect",
                                     "baseline": _ri(brect), "fresh": _ri(frect)}))

    # --- cursor_pairs: missing / moved / appeared, deduped by shared live rect ---
    base_pairs = {p["id"]: p for p in base.get("cursor_pairs") or [] if isinstance(p, dict) and p.get("id")}
    fresh_pairs = {p["id"]: p for p in fresh.get("cursor_pairs") or [] if isinstance(p, dict) and p.get("id")}
    missing_by_live: dict[tuple, list[str]] = {}
    for pid, bp in base_pairs.items():
        blive, fp = bp.get("live"), fresh_pairs.get(pid)
        flive = fp.get("live") if fp else None
        bvalid, fvalid = _valid_rect(blive), _valid_rect(flive)
        field = f"cursor_pairs[id={pid}].live"
        if bvalid and not fvalid:
            missing_by_live.setdefault(tuple(_ri(blive)), []).append(pid)
        elif bvalid and fvalid and _ri(blive) != _ri(flive) and _active_row(bp):
            findings.append(_mk(shot, "cursor_moved", f"cursor:{pid}", _ri(blive), "medium", "high",
                                f"cursor '{pid}' moved", f"Cursor '{pid}' live rect moved from "
                                f"{_ri(blive)} to {_ri(flive)}.",
                                {"source": "both", "field": field, "baseline": _ri(blive), "fresh": _ri(flive)}))
        elif not bvalid and fvalid:
            findings.append(_mk(shot, "cursor_appeared", f"cursor:{pid}", _ri(flive), "medium", "high",
                                f"cursor '{pid}' appeared", f"Cursor '{pid}' appeared at {_ri(flive)}.",
                                {"source": "both", "field": field, "baseline": None, "fresh": _ri(flive)}))
    for live, ids in missing_by_live.items():
        # one finding per shared live rect: attribute to the active row (cursor cell
        # inside that live), else the first id -> exactly one cursor_missing/row.
        active = next((pid for pid in ids if _valid_rect(base_pairs[pid].get("cursor"))
                       and _rect_inside(base_pairs[pid]["cursor"], list(live))), ids[0])
        bbox = _enclosing(_pair_rects(base_pairs[active]))
        findings.append(_mk(shot, "cursor_missing", f"cursor:{active}", bbox, "medium", "high",
                            f"cursor '{active}' missing",
                            "Cursor live rect present in baseline is gone in the fresh capture. "
                            "Is the cursor vertically centered on the row it selects? (presence precondition)",
                            {"source": "both", "field": f"cursor_pairs[id={active}].live",
                             "baseline": list(live), "fresh": []}))

    # --- draw_order: z / y_sort / sequence deltas (groundable nodes only) ---
    base_order = [n for n in base.get("draw_order") or [] if isinstance(n, dict) and n.get("node")]
    fresh_order = [n for n in fresh.get("draw_order") or [] if isinstance(n, dict) and n.get("node")]
    fresh_nodes = {n["node"]: n for n in fresh_order}
    base_seq = [n["node"] for n in base_order]
    fresh_seq = [n["node"] for n in fresh_order]
    ungroundable_deltas = 0
    for bn in base_order:
        node = bn["node"]; fn = fresh_nodes.get(node)
        if fn is None:
            delta = True
        else:
            delta = (bn.get("z") != fn.get("z")) or (bn.get("y_sort") != fn.get("y_sort"))
        if delta:
            rid = f"draw:{node}"
            if ctx["region_table"].get(rid, {}).get("rects"):
                findings.append(_mk(shot, "draw_order_changed", rid,
                                    ctx["region_table"][rid]["rects"][0], "medium", "high",
                                    f"draw node '{node}' changed",
                                    f"Draw node '{node}' z/y_sort/presence changed vs baseline.",
                                    {"source": "both", "field": f"draw_order[node={node}]",
                                     "baseline": {"z": bn.get("z"), "y_sort": bn.get("y_sort")},
                                     "fresh": {"z": fn.get("z"), "y_sort": fn.get("y_sort")} if fn else None}))
            else:
                ungroundable_deltas += 1
    if base_seq != fresh_seq and sorted(base_seq) == sorted(fresh_seq):
        # genuine REORDER only (same node multiset, different order). A pure node
        # add/delete already counted once per node above; guarding on the multiset
        # stops one deletion from double-counting (once as a node delta, once here).
        ungroundable_deltas += 1  # sequence delta recorded as ungroundable context

    # --- anchor_drift: live draw_order stage rect vs the art-anchor stage_rect ---
    # The G1<->G2 bridge: truth is the SOURCE ART (art-anchors.toml via art_geometry),
    # compared stage-to-stage within the registry tol_px (absent = 0, exact int). The
    # finding's bbox = the ENCLOSING rect of the live rect (mapped stage->display)
    # and the registered (mapped) anchor rect: it CONTAINS the anchor rect, so it
    # intersects it by construction for drifts of ANY magnitude -- a live-rect-only
    # bbox stops intersecting once the drift reaches the bar width, which would
    # ground-drop the finding for exactly the catastrophic case;
    # pipeline-side grounding is still the gate. Nodes ABSENT from draw_order are
    # counted UNVERIFIED (a pre-collection sidecar cannot be said to drift) -- a
    # warning, never a finding. Self-tags KIND_ART_ANCHOR into the coverage ledger
    # even on a zero-finding pass (the comparison itself is the answered question).
    anchor_entries = [(rid, e) for rid, e in ctx["region_table"].items() if e.get("kind") == "anchor"]
    # anchor_kind_ran means the stage-to-stage comparison ACTUALLY EXECUTED: an
    # entry whose meta (nodes/stage_rect) was stripped from a serialized region
    # table CANNOT run the comparison, so it is counted live-unverified with the
    # true cause, never as a ran comparison (the coverage ledger must not credit
    # a comparison that never happened, and must not mislabel a missing meta as
    # a node absent from draw_order).
    comparison_ran = False
    anchor_unverified: list[str] = []
    window = ctx.get("window") or [1152, 648]  # documented default-capture fallback (plugin ctx)
    for rid, entry in anchor_entries:
        meta = entry.get("meta") or {}
        stage_rect = meta.get("stage_rect")
        nodes = meta.get("nodes") or []
        aid = meta.get("anchor_id", rid)
        tol = int(meta.get("tol_px", 0))
        if not nodes or not _valid_rect(stage_rect):
            anchor_unverified.append(f"{aid} (anchor meta unavailable: nodes/stage_rect "
                                     f"missing from region-table entry)")
            continue
        comparison_ran = True
        live, live_node = None, None
        for node in fresh_order:
            if node["node"] in nodes and _valid_rect(node.get("rect")) and any(node["rect"]):
                live, live_node = _ri(node["rect"]), node["node"]
                break
        if live is None:
            anchor_unverified.append(f"{aid} (node absent from draw_order: {', '.join(nodes)})")
            continue
        if _valid_rect(stage_rect) and not _art_geometry().rects_close(live, _ri(stage_rect), tol):
            drift_bbox = _stage_to_display(live, window)
            anchor_rects = entry.get("rects") or []
            if anchor_rects and _valid_rect(anchor_rects[0]):
                drift_bbox = _enclosing([drift_bbox, anchor_rects[0]])
            findings.append(_mk(shot, "anchor_drift", rid, drift_bbox, "high", "high",
                                f"anchor '{aid}' drift on '{live_node}'",
                                f"Live draw_order rect {live} for '{live_node}' is off its source-art anchor "
                                f"{_ri(stage_rect)} (tol {tol}px) — the track lives in the baked art; fix the "
                                f"node, never the baseline.",
                                {"source": "fresh", "field": f"draw_order[node={live_node}].rect",
                                 "baseline": _ri(stage_rect), "fresh": live}, KIND_ART_ANCHOR))
    ctx["anchor_kind_ran"] = comparison_ran
    ctx["anchor_unverified"] = anchor_unverified

    # --- palettes: canary drop (hud is ungroundable, never emits) ---
    bcan = set((base.get("palettes") or {}).get("canary") or [])
    fcan = set((fresh.get("palettes") or {}).get("canary") or [])
    dropped = sorted(bcan - fcan)
    canary_rect = base.get("canary_rect")
    if dropped and _valid_rect(canary_rect) and any(canary_rect):
        findings.append(_mk(shot, "palette_dropped", "palette:canary", canary_rect, "high", "high",
                            f"canary palette dropped {len(dropped)} colors",
                            f"Canary palette dropped {len(dropped)}/{len(bcan)} baseline colors "
                            f"({', '.join(dropped[:4])}).",
                            {"source": "both", "field": "palettes.canary",
                             "baseline": sorted(bcan), "fresh": sorted(fcan)}))

    # --- canary_rect geometry delta ---
    fcr = fresh.get("canary_rect")
    if (_valid_rect(canary_rect) and any(canary_rect) and _valid_rect(fcr)
            and _ri(canary_rect) != _ri(fcr)):
        findings.append(_mk(shot, "canary_rect_changed", "canary", canary_rect, "high", "high",
                            "canary rect changed", f"Canary rect moved from {_ri(canary_rect)} to {_ri(fcr)}.",
                            {"source": "both", "field": "canary_rect",
                             "baseline": _ri(canary_rect), "fresh": _ri(fcr)}))

    # --- expected_regions ink / string rect deltas ---
    bink = (base.get("expected_regions") or {}).get("ink") or []
    fink = (fresh.get("expected_regions") or {}).get("ink") or []
    for i in range(min(len(bink), len(fink))):
        if _valid_rect(bink[i]) and _valid_rect(fink[i]) and _ri(bink[i]) != _ri(fink[i]):
            findings.append(_mk(shot, "expected_region_changed", f"ink:{i}", bink[i], "medium", "high",
                                f"ink region {i} changed", f"Expected ink region {i} rect changed.",
                                {"source": "both", "field": f"expected_regions.ink[{i}]",
                                 "baseline": _ri(bink[i]), "fresh": _ri(fink[i])}))
    fstr = {str(e.get("text")): e for e in (fresh.get("expected_regions") or {}).get("strings") or []
            if isinstance(e, dict)}
    for e in (base.get("expected_regions") or {}).get("strings") or []:
        if not isinstance(e, dict) or not e.get("text"):
            continue
        fe = fstr.get(str(e["text"]))
        if fe and _valid_rect(e.get("region")) and _valid_rect(fe.get("region")) \
                and _ri(e["region"]) != _ri(fe["region"]):
            findings.append(_mk(shot, "expected_region_changed", f"string:{e['text']}", e["region"],
                                "medium", "high", f"string '{e['text']}' region changed",
                                f"Expected string '{e['text']}' region rect changed.",
                                {"source": "both", "field": f"expected_regions.strings[text={e['text']}]",
                                 "baseline": _ri(e["region"]), "fresh": _ri(fe["region"])}))

    # --- cluster_unexplained: one per unexplained cluster intersecting a region ---
    ungroundable_clusters = 0
    for cluster in clusters:
        if cluster.get("explained", False):
            continue
        bbox = cluster.get("bbox")
        if not _valid_rect(bbox):
            continue
        chosen = _pick_region_for_bbox(_ri(bbox), ctx["region_table"])
        if chosen is None:
            ungroundable_clusters += 1  # explicit queue preserved: silence is counted, never lost
            continue
        findings.append(_mk(shot, "cluster_unexplained", chosen["id"], bbox, "low", "medium",
                            f"unexplained change cluster ({cluster.get('changed', 0)} px)",
                            f"{cluster.get('changed', 0)} changed px at {_ri(bbox)} outside all coded "
                            f"regions; intersects groundable region {chosen['id']}.",
                            {"source": "both", "field": None,
                             "baseline": None, "fresh": None, "cluster": True}))

    ctx["ungroundable_deltas"] = ungroundable_deltas
    ctx["ungroundable_clusters"] = ungroundable_clusters
    return findings


def _rect_inside(inner, outer) -> bool:
    inner, outer = _ri(inner), _ri(outer)
    return (inner[0] >= outer[0] and inner[1] >= outer[1]
            and inner[0] + inner[2] <= outer[0] + outer[2]
            and inner[1] + inner[3] <= outer[1] + outer[3])


def _pick_region_for_bbox(bbox: list[int], table: dict) -> dict | None:
    """Most-specific groundable region intersecting bbox: priority
    cursor > string > label > ink > anchor > canary > draw (smallest) > palette:canary."""
    best = None
    for rid, entry in table.items():
        kind = entry["kind"]
        if kind not in KIND_ORDER:
            continue
        rects = entry["rects"]
        if not rects:
            continue
        hit = next((r for r in rects if _rects_overlap(bbox, r)), None)
        if hit is None:
            continue
        area = hit[2] * hit[3]
        rank = (KIND_ORDER[kind], area if kind == "draw" else 0)
        if best is None or rank < best[0]:
            best = (rank, {"id": rid, "kind": kind, "rect": hit})
    return best[1] if best else None


_EXPLAIN = None


def _rects_overlap(a: list[int], b: list[int]) -> bool:
    """The SINGLE geometry home: visual_explain.rects_overlap via importlib,
    never re-implemented. Cached so the module is loaded at most once."""
    global _EXPLAIN
    if _EXPLAIN is None:
        _EXPLAIN = _load("visual_explain", TOOLS / "visual_explain.py")
    return _EXPLAIN.rects_overlap(a, b)


# --------------------------------------------------------------------------
# schema validate/repair + grounding enforcement + finding_id
# --------------------------------------------------------------------------
def _repair(finding: dict) -> tuple[dict | None, str | None]:
    if not isinstance(finding, dict):
        return None, "schema_invalid"
    bbox = finding.get("bbox")
    try:
        bbox = [int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])]
    except (TypeError, ValueError, IndexError):
        return None, "schema_invalid"
    finding["bbox"] = bbox
    if finding.get("severity") not in SEVERITIES:
        finding["severity"] = "medium"
        finding.setdefault("repairs", []).append("severity coerced to medium")
    if finding.get("confidence") not in SEVERITIES:
        finding["confidence"] = "low"
        finding.setdefault("repairs", []).append("confidence coerced to low")
    if not isinstance(finding.get("region_id"), str) or not finding["region_id"]:
        return None, "unknown_region_id"
    if not isinstance(finding.get("class"), str) or not finding["class"]:
        finding["class"] = "unclassified"
    return finding, None


def _finding_id(f: dict) -> str:
    ref = f.get("sidecar_ref") or {}
    payload = {"v": 1, "shot": f.get("shot"), "class": f.get("class"),
               "region_id": f.get("region_id"), "bbox": f.get("bbox"),
               "sidecar_field": ref.get("field"),
               "baseline": ref.get("baseline"), "fresh": ref.get("fresh"),
               "cluster": bool(ref.get("cluster")) or f.get("class") == "cluster_unexplained"}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return "vr1-" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def enforce_grounding(raw_findings: list, table: dict, window: list[int]) -> tuple[list[dict], dict]:
    """Drop-and-count. 100% of emitted findings are grounded BY CONSTRUCTION."""
    emitted: list[dict] = []
    reasons = {"unknown_region_id": 0, "no_intersection": 0, "schema_invalid": 0, "bbox_out_of_frame": 0}
    samples: list[dict] = []
    dropped = 0
    for raw in raw_findings:
        finding, reason = _repair(raw if isinstance(raw, dict) else {})
        if finding is None:
            reason = reason or "schema_invalid"
        else:
            x, y, w, h = finding["bbox"]
            if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > window[0] or y + h > window[1]:
                reason = "bbox_out_of_frame"
            else:
                entry = table.get(finding["region_id"])
                if entry is None or not entry["rects"]:
                    reason = "unknown_region_id"
                else:
                    hit = next((r for r in entry["rects"] if _rects_overlap(finding["bbox"], r)), None)
                    if hit is None:
                        reason = "no_intersection"
                    else:
                        finding["region"] = hit
                        finding["finding_id"] = _finding_id(finding)
                        emitted.append(finding)
                        continue
        dropped += 1
        reasons[reason] = reasons.get(reason, 0) + 1
        if len(samples) < 8:
            samples.append({"reason": reason, "region_id": (raw or {}).get("region_id") if isinstance(raw, dict) else None,
                            "class": (raw or {}).get("class") if isinstance(raw, dict) else None})
    stats = {"emitted": len(emitted), "grounded": len(emitted), "dropped": dropped,
             "dropped_reasons": reasons, "dropped_samples": samples}
    return emitted, stats


# --------------------------------------------------------------------------
# bundle assembly (per changed shot)
# --------------------------------------------------------------------------
def _crop_buf(buf: bytes, width: int, x0: int, y0: int, cw: int, ch: int) -> bytes:
    out = bytearray(cw * ch * 4)
    for j in range(ch):
        src = ((y0 + j) * width + x0) * 4
        out[j * cw * 4:(j + 1) * cw * 4] = buf[src:src + cw * 4]
    return bytes(out)


def _twin(canvas_mod, base_buf, fresh_buf, width, height, rect, label) -> bytes:
    x, y, w, h = rect
    x0 = max(0, x - CROP_PAD); y0 = max(0, y - CROP_PAD)
    x1 = min(width, x + w + CROP_PAD); y1 = min(height, y + h + CROP_PAD)
    cw, ch = max(1, x1 - x0), max(1, y1 - y0)
    gap, label_h = 4, 8
    canvas = canvas_mod.Canvas(cw * 2 + gap, ch + label_h, (24, 24, 24, 255))
    canvas.blit(0, label_h, cw, ch, _crop_buf(base_buf, width, x0, y0, cw, ch))
    canvas.blit(cw + gap, label_h, cw, ch, _crop_buf(fresh_buf, width, x0, y0, cw, ch))
    canvas.text(0, 1, "BASE", (200, 200, 200, 255))
    canvas.text(cw + gap, 1, "FRESH", (200, 200, 200, 255))
    canvas.text(0, ch + label_h - 5, str(label)[:20], (255, 200, 0, 255))
    return canvas.png()


def _sidecar_delta_summary(base: dict | None, fresh: dict | None) -> list[str]:
    """Compact sidecar-delta list for bundle context (aids plugin reviewers)."""
    base = base or {}; fresh = fresh or {}
    deltas: list[str] = []
    btext = [str(l.get("text")) for l in base.get("labels") or [] if isinstance(l, dict)]
    ftext = [str(l.get("text")) for l in fresh.get("labels") or [] if isinstance(l, dict)]
    if btext != ftext:
        deltas.append(f"labels: baseline {btext} -> fresh {ftext}")
    bp = {p["id"]: p.get("live") for p in base.get("cursor_pairs") or [] if isinstance(p, dict) and p.get("id")}
    fp = {p["id"]: p.get("live") for p in fresh.get("cursor_pairs") or [] if isinstance(p, dict) and p.get("id")}
    if bp != fp:
        deltas.append(f"cursor_pairs.live: baseline {bp} -> fresh {fp}")
    bcan = sorted((base.get("palettes") or {}).get("canary") or [])
    fcan = sorted((fresh.get("palettes") or {}).get("canary") or [])
    if bcan != fcan:
        deltas.append(f"palettes.canary: dropped {sorted(set(bcan) - set(fcan))}")
    if base.get("draw_order") and fresh.get("draw_order"):
        bseq = [(n.get("node"), n.get("z"), n.get("y_sort")) for n in base["draw_order"]]
        fseq = [(n.get("node"), n.get("z"), n.get("y_sort")) for n in fresh["draw_order"]]
        if bseq != fseq:
            deltas.append("draw_order: node/z/y_sort sequence changed")
    return deltas


def _rubric_section(shot: str, rubric_text: str) -> str:
    stem = shot.split(".")[0]
    if stem.startswith(("09", "10", "11", "12")):
        marker = "Battle states"
    elif stem.startswith(("06", "07", "08")):
        marker = "Menu states"
    elif stem.startswith(("04", "05")):
        marker = "Day/night states"
    elif stem.startswith(("15", "16", "17")):
        marker = "Camping states"
    elif stem.startswith("matrix"):
        marker = "Display-matrix states"
    else:
        marker = "Overworld states"
    lines = rubric_text.splitlines()
    out, active = [], False
    for line in lines:
        if line.startswith("## "):
            active = marker in line
        if active:
            out.append(line)
    return "\n".join(out) or rubric_text


# --------------------------------------------------------------------------
# rubric-coverage ledger
#
# Mechanizes the pilot's RETIRED `_review` coverage-gap pseudo-shot: instead of a
# fake finding, "the rubric's art-fidelity questions were answered" becomes a
# checkable, freshness-gated, HONESTLY-COUNTED fact. Every shot-group's rubric
# questions are parsed into a stable inventory; each question declares which
# reviewer KIND can answer it; the manifest records, per shot-group, which kinds
# ran a FRESH pass and which questions are therefore answered. "Unanswered" is a
# first-class COUNTED state -- never faked as answered and never red (advisory-
# loud): a shot-group with unanswered questions emits a rubric_coverage_gap line
# that rides the manifest, the legibility report, and verify_all's WARN surface.
# --------------------------------------------------------------------------
# KIND_DETERMINISTIC / KIND_ART_ANCHOR / KIND_MODEL are defined module-top (shared
# by _mk, the anchor bridge above, and the ledger below).

# Ordered shot-group inventory. `marker` is the substring _rubric_section matches
# on the "## " heading -- the SAME single source of truth the bundle excerpter
# uses, so the coverage ledger and the per-shot rubric excerpt never disagree.
RUBRIC_GROUPS = [
    ("overworld", "Overworld states"),
    ("day_night", "Day/night states"),
    ("menu", "Menu states"),
    ("battle", "Battle states"),
    ("camping", "Camping states"),
    ("display_matrix", "Display-matrix states"),
]

# Answerer declarations: per shot-group, a list of (fingerprint, capable kinds).
# A question's fingerprint is a distinctive LOWERCASE substring of its canonical
# text; matching by CONTENT (not position) makes the join robust to rubric
# REORDERING, while REWORDING a question breaks its fingerprint -> the question
# falls through to "unassigned" (a COUNTED state), surfacing the id rotation
# instead of silently keeping a stale answerer. A brand-new question nobody mapped
# is likewise counted. The deterministic sidecar-consistency reviewer answers ONLY
# the two battle questions its classes mechanically implement (cursor row centering
# via cursor_*, name/level presence via label_*); the HP-bar art-fidelity question
# needs the art-anchor class, and every judgment / non-baked-UI question needs the
# model reviewer -- exactly the 13/19 an art anchor is structurally blind to.
QUESTION_ANSWERERS = {
    "battle": [
        ("cursor vertically centered", [KIND_DETERMINISTIC, KIND_MODEL]),
        ("name plates read fully", [KIND_DETERMINISTIC, KIND_MODEL]),
        ("hp bars on their baked tracks", [KIND_ART_ANCHOR, KIND_MODEL]),
        ("single clean frame", [KIND_MODEL]),
        ("text inside its box", [KIND_MODEL]),
    ],
    "overworld": [
        ("biome read as its intended terrain", [KIND_MODEL]),
        ("props sit on their tiles", [KIND_MODEL]),
        ("render behind tall prop canopies", [KIND_MODEL]),
        ("tall-grass patches visibly distinct", [KIND_MODEL]),
        ("untextured solid-color", [KIND_MODEL]),
        ("player sprite intact", [KIND_MODEL]),
    ],
    "day_night": [
        ("tint plausibly", [KIND_MODEL]),
        ("hint bar", [KIND_MODEL]),
    ],
    "menu": [
        ("uniformly dimmed", [KIND_MODEL]),
        ("panels framed and readable", [KIND_MODEL]),
        ("every row align its name", [KIND_MODEL]),
        ("hp bars visible and color-graded", [KIND_MODEL]),
        ("clipped, overlapping, or escaping", [KIND_MODEL]),
    ],
    "display_matrix": [
        ("every window size", [KIND_MODEL]),
    ],
    "camping": [
        ("glow visible around the fire", [KIND_MODEL]),
        ("recipe names + ingredient counts legible", [KIND_MODEL]),
    ],
}

# Static pin so a rubric edit cannot SILENTLY EMPTY a question list: when the
# parsed inventory drifts from these counts the run records a loud warning
# (advisory in this slice; a RED check_repo_contracts backstop is the documented
# follow-up). Totals: 6 + 2 + 5 + 5 + 2 + 1 = 21 rubric questions.
EXPECTED_QUESTION_COUNTS = {
    "overworld": 6, "day_night": 2, "menu": 5, "battle": 5, "camping": 2, "display_matrix": 1,
}

ANSWER_VERDICTS = ("yes", "no")


def _canonical_question(text: str) -> str:
    return " ".join(str(text).split())


def _question_id(text: str) -> str:
    """Stable rubric-question join key: `q1-` + 8 hex of sha256 over the canonical
    (whitespace-collapsed) question text. Stable across REORDERING; REWORDING
    rotates the id (surfaced as an unassigned question, never a silent loss). The
    versioned prefix lets the scheme rotate without collisions (the finding_id
    `vr1-` convention applied to questions)."""
    return "q1-" + hashlib.sha256(_canonical_question(text).encode("utf-8")).hexdigest()[:8]


def _shot_group(name: str) -> str | None:
    """Map a shot name to its rubric group key (shares _rubric_section's prefix
    map). None for a name no group claims."""
    stem = str(name).split(".")[0]
    if stem.startswith(("09", "10", "11", "12")):
        return "battle"
    if stem.startswith(("06", "07", "08")):
        return "menu"
    if stem.startswith(("04", "05")):
        return "day_night"
    if stem.startswith(("15", "16", "17")):
        return "camping"
    if stem.startswith("matrix"):
        return "display_matrix"
    if stem.startswith(("01", "02", "03")):
        return "overworld"
    return None


def parse_rubric_questions(rubric_text: str) -> dict:
    """Parse the rubric's per-shot-group '## ' sections into a stable inventory:
    {group_key: [{"id", "text"}, ...]}. A question is a column-0 '- ' bullet plus
    its indented wrap lines, joined on whitespace; collection stops at the next
    '## ' heading, so the grounding/schema/automation sections (tables + prose,
    not shot-group questions) are never misparsed as questions."""
    lines = str(rubric_text or "").splitlines()
    markers = {marker: key for key, marker in RUBRIC_GROUPS}
    questions: dict[str, list[dict]] = {key: [] for key, _ in RUBRIC_GROUPS}
    active_group: str | None = None
    current: list[str] = []

    def flush() -> None:
        nonlocal current
        if active_group is not None and current:
            text = _canonical_question(" ".join(current))
            if text:
                questions[active_group].append({"id": _question_id(text), "text": text})
        current = []

    for line in lines:
        if line.startswith("## "):
            flush()
            active_group = None
            for marker, key in markers.items():
                if marker in line:
                    active_group = key
                    break
            continue
        if line.startswith("###"):
            flush()
            active_group = None  # a subsection (e.g. a future Answerers table) ends question collection
            continue
        if active_group is None:
            continue
        if line.startswith("- "):
            flush()
            current = [line[2:].strip()]
        elif line.strip() == "":
            flush()
        elif current and line[:1] in (" ", "\t"):
            current.append(line.strip())
        else:
            flush()  # unexpected non-bullet, non-indented line ends the bullet
    flush()
    return questions


def answerers_for(group_key: str, question_text: str) -> list[str]:
    """Capable reviewer kinds for a question: the first declaration whose
    fingerprint is a substring of the canonical (lowercased) question text. [] =
    unassigned (a counted state that surfaces a reworded/new question nobody
    mapped)."""
    canonical = _canonical_question(question_text).lower()
    for fingerprint, kinds in QUESTION_ANSWERERS.get(group_key, []):
        if fingerprint in canonical:
            return list(kinds)
    return []


def _unanswered_reason(group_key: str, capable: list[str]) -> str:
    if not capable:
        return "no answerer declared (rubric question not mapped in QUESTION_ANSWERERS)"
    base = f"no fresh reviewer of kind [{' / '.join(capable)}] ran this pass"
    if group_key == "overworld":
        base += "; overworld shots carry zero groundable regions"
    return base


def _validate_answer(answer) -> tuple[dict | None, str | None]:
    """Repair/validate a reviewer's rubric answer (the additive answers[] seam a
    --reviewer-cmd plugin uses to ANSWER rubric questions). verdict in {yes,no};
    question_id a stable q1- id; region_id + bbox optional (an answer that cites a
    resolvable region grounds a verdict-`no` quarantine finding; one without a
    resolvable region is counted, never a finding)."""
    if not isinstance(answer, dict):
        return None, "schema_invalid"
    qid = answer.get("question_id")
    verdict = answer.get("verdict")
    if not isinstance(qid, str) or not qid:
        return None, "schema_invalid"
    if verdict not in ANSWER_VERDICTS:
        return None, "schema_invalid"
    clean = {"question_id": qid, "verdict": verdict,
             "note": str(answer.get("note", "")),
             "reviewer_kind": str(answer.get("reviewer_kind") or "cmd")}
    region_id = answer.get("region_id")
    bbox = answer.get("bbox")
    if isinstance(region_id, str) and region_id:
        clean["region_id"] = region_id
    try:
        clean["bbox"] = [int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])]
    except (TypeError, ValueError, IndexError):
        clean["bbox"] = None
    return clean, None


def _kinds_that_ran(reviewer_kind: str, shots_out: list, answers: list,
                    extra_kinds=None) -> set:
    """The reviewer kinds that ran a fresh pass this run: the configured reviewer,
    every kind that self-tagged an emitted finding or a returned answer, and any
    kinds a composite wrapper declared via reviewer_meta.kinds_ran (extra_kinds).
    A composite VLM/art-anchor wrapper self-tags and/or declares, so its coverage
    registers without any pipeline change -- even on a 0-changed-shot run."""
    kinds = {reviewer_kind}
    kinds.update(extra_kinds or ())
    for shot in shots_out or []:
        if not isinstance(shot, dict):
            continue
        for finding in shot.get("findings") or []:
            if isinstance(finding, dict) and finding.get("reviewer_kind"):
                kinds.add(finding["reviewer_kind"])
    for answer in answers or []:
        if isinstance(answer, dict) and answer.get("reviewer_kind"):
            kinds.add(answer["reviewer_kind"])
    return kinds


def compute_rubric_coverage(rubric_text, reviewer_kind, shots_out, covered,
                            run_answers=None, extra_kinds=None):
    """Build the rubric-coverage ledger block + advisory gap lines + inventory
    warnings. Coverage is a function of (rubric inventory, answerer declarations,
    reviewer configuration); its FRESHNESS rides the manifest sha (review_is_fresh
    covers every covered shot). A question is `answered` iff a capable reviewer
    kind RAN this pass, or a returned answer addressed its id. Returns
    (block, gap_lines, warnings)."""
    run_answers = run_answers or []
    inventory = parse_rubric_questions(rubric_text)
    kinds_ran = _kinds_that_ran(reviewer_kind, shots_out, run_answers, extra_kinds)
    answered_ids = {a["question_id"] for a in run_answers
                    if isinstance(a, dict) and a.get("question_id")}

    covered_by_group: dict[str, list[str]] = {key: [] for key, _ in RUBRIC_GROUPS}
    changed_by_group: dict[str, list[str]] = {key: [] for key, _ in RUBRIC_GROUPS}
    for entry in covered or []:
        if not isinstance(entry, dict):
            continue
        name = entry.get("shot")
        group = _shot_group(name or "")
        if group is None:
            continue
        covered_by_group[group].append(name)
        if entry.get("changed"):
            changed_by_group[group].append(name)

    groups = []
    gaps = []
    warnings: list[str] = []
    totals = {"questions_total": 0, "questions_answered": 0, "unanswered": 0,
              "unassigned": 0, "groups_with_gap": 0}
    for group_key, marker in RUBRIC_GROUPS:
        qlist = inventory.get(group_key, [])
        expected = EXPECTED_QUESTION_COUNTS.get(group_key)
        if expected is not None and len(qlist) != expected:
            warnings.append(
                f"rubric_coverage: {group_key} parsed {len(qlist)} question(s), expected "
                f"{expected} -- the rubric question inventory drifted; re-map "
                f"QUESTION_ANSWERERS / EXPECTED_QUESTION_COUNTS deliberately")
        answered: list[dict] = []
        unanswered: list[dict] = []
        group_kinds: set[str] = set()
        for q in qlist:
            capable = answerers_for(group_key, q["text"])
            ran = sorted(set(capable) & kinds_ran)
            totals["questions_total"] += 1
            if not capable:
                totals["unassigned"] += 1
            if ran or q["id"] in answered_ids:
                by = ran or sorted({a["reviewer_kind"] for a in run_answers
                                    if isinstance(a, dict) and a.get("question_id") == q["id"]})
                group_kinds.update(by)
                totals["questions_answered"] += 1
                answered.append({"id": q["id"], "text": q["text"], "by": by})
            else:
                totals["unanswered"] += 1
                unanswered.append({"id": q["id"], "text": q["text"],
                                   "reason": _unanswered_reason(group_key, capable)})
        if unanswered:
            totals["groups_with_gap"] += 1
            needs = sorted({k for q in unanswered
                            for k in (answerers_for(group_key, q["text"]) or [KIND_MODEL])})
            gaps.append({
                "group": group_key, "marker": marker,
                "questions_total": len(qlist), "questions_answered": len(answered),
                "unanswered": len(unanswered), "needs_reviewer_kinds": needs,
                "reason": (f"{len(unanswered)} of {len(qlist)} rubric question(s) have no "
                           f"fresh reviewer pass (needs [{' / '.join(needs)}])"),
            })
        groups.append({
            "group": group_key, "marker": marker,
            "questions_total": len(qlist), "questions_answered": len(answered),
            "reviewer_kinds": sorted(group_kinds),
            "shots_covered": sorted(covered_by_group[group_key]),
            "shots_changed": sorted(changed_by_group[group_key]),
            "answered": answered, "unanswered": unanswered,
        })
    block = {"schema": "rubric-coverage/1",
             "reviewer_kinds_ran": sorted(kinds_ran),
             "totals": totals, "groups": groups, "gaps": gaps}
    gap_lines = [f"rubric_coverage_gap [{g['group']}]: {g['reason']}" for g in gaps]
    return block, gap_lines, warnings


def rubric_inventory_issues(rubric_text: str) -> list[str]:
    """RED-tier integrity of the rubric question inventory -- the static backstop
    (region_diff_backstop_sync-style) so a rubric edit cannot SILENTLY EMPTY or
    rotate the question list the coverage ledger is built on: (1) each shot-group
    must parse to its EXPECTED_QUESTION_COUNTS pin, and (2) every declared answerer
    fingerprint must still match a parsed question in its group (a REWORDED
    question breaks its fingerprint, so its answerer no longer maps -- surfaced
    here as a forcing function, the q1- id rotation made loud, never a silent stale
    mapping). Pure function of the rubric text + the declarations above; folded
    into check_repo_contracts.run(). Distinct from the coverage GAP (unanswered
    questions), which is advisory and never red."""
    issues: list[str] = []
    inventory = parse_rubric_questions(rubric_text)
    for group_key, _ in RUBRIC_GROUPS:
        expected = EXPECTED_QUESTION_COUNTS.get(group_key)
        parsed = len(inventory.get(group_key, []))
        if expected is not None and parsed != expected:
            issues.append(
                f"rubric question inventory drift: {group_key} parses {parsed} "
                f"question(s), expected {expected} -- a rubric edit changed the "
                f"question list; update EXPECTED_QUESTION_COUNTS deliberately")
    for group_key, decls in QUESTION_ANSWERERS.items():
        texts = [_canonical_question(q["text"]).lower()
                 for q in inventory.get(group_key, [])]
        for fingerprint, _kinds in decls:
            if not any(fingerprint in text for text in texts):
                issues.append(
                    f"rubric answerer fingerprint stale: {group_key} '{fingerprint}' "
                    f"matches no parsed question -- the question was reworded; re-map "
                    f"QUESTION_ANSWERERS deliberately (id rotation, not a silent loss)")
    return issues


def assemble_bundle(name, base_png, fresh_png, base_sidecar, fresh_sidecar, clusters,
                    table, bundle_dir, vd, canvas_mod, window, rubric_text) -> tuple[dict, dict]:
    """Returns (bundle-relative paths, som_legend): the legend maps region_id to
    the number drawn on the SoM overlays, so it rides in the reviewer stdin JSON
    (not pixels-only) AND in the on-disk context.json."""
    if bundle_dir.is_dir():  # clear stale crops/overlays from a prior run
        for stale in bundle_dir.iterdir():
            if stale.is_file():
                stale.unlink()
    bundle_dir.mkdir(parents=True, exist_ok=True)
    base_bytes = base_png.read_bytes()
    fresh_bytes = fresh_png.read_bytes()
    (bundle_dir / "before.png").write_bytes(base_bytes)   # raw byte copies, no re-encode
    (bundle_dir / "after.png").write_bytes(fresh_bytes)
    _, _, base_buf = vd.decode_png_rgba(base_png)
    _, _, fresh_buf = vd.decode_png_rgba(fresh_png)
    width, height = window[0], window[1]
    stem = Path(name).stem

    crops: list[str] = []
    for i, cluster in enumerate(clusters):
        bbox = cluster.get("bbox")
        if not _valid_rect(bbox):
            continue
        png = _twin(canvas_mod, base_buf, fresh_buf, width, height, _ri(bbox), f"cluster{i + 1}")
        path = bundle_dir / f"crop_{i + 1:03d}_cluster.png"
        path.write_bytes(png)
        crops.append(f"vision-review/{stem}/{path.name}")

    # Set-of-Mark overlays: every groundable region outlined + numbered.
    legend: dict[str, int] = {}
    ordered = sorted(table.items(), key=lambda kv: (KIND_ORDER.get(kv[1]["kind"], 99), kv[0]))
    for mark, (rid, entry) in enumerate(ordered, start=1):
        legend[rid] = mark
    for frame_buf, fname in ((base_buf, "som_before.png"), (fresh_buf, "som_after.png")):
        canvas = canvas_mod.Canvas(width, height, (0, 0, 0, 255))
        canvas.blit(0, 0, width, height, frame_buf)
        for rid, entry in ordered:
            color = KIND_COLOR.get(entry["kind"], (255, 255, 255, 255))
            for rect in entry["rects"]:
                canvas.box(rect[0], rect[1], rect[2], rect[3], color)
                canvas.text(rect[0], max(0, rect[1] - 6), str(legend[rid]), color)
        (bundle_dir / fname).write_bytes(canvas.png())

    # expected-strings manifest
    expected = {
        "strings": (fresh_sidecar or {}).get("expected_regions", {}).get("strings", []),
        "labels": [{"text": l.get("text"), "region": l.get("display_rect")}
                   for l in (fresh_sidecar or {}).get("labels", []) if isinstance(l, dict)],
    }
    (bundle_dir / "expected_strings.json").write_text(
        json.dumps(expected, indent=2, sort_keys=True), encoding="utf-8")
    (bundle_dir / "rubric.txt").write_text(_rubric_section(name, rubric_text), encoding="utf-8")

    context = {
        "shot": name, "shot_kind": stem.split("_")[0], "window": window,
        "crafted_state": (fresh_sidecar or base_sidecar or {}).get("crafted_state"),
        "sidecar_deltas": _sidecar_delta_summary(base_sidecar, fresh_sidecar),
        "clusters": [{"bbox": c.get("bbox"), "changed": c.get("changed"),
                      "tier": c.get("tier"), "sentence": c.get("sentence")} for c in clusters],
        "region_table": {rid: {"kind": e["kind"], "rects": e["rects"], "source": e["source"]}
                         for rid, e in table.items()},
        "som_legend": legend,
    }
    (bundle_dir / "context.json").write_text(json.dumps(context, indent=2, sort_keys=True), encoding="utf-8")

    return ({"before": f"vision-review/{stem}/before.png", "after": f"vision-review/{stem}/after.png",
             "som_before": f"vision-review/{stem}/som_before.png",
             "som_after": f"vision-review/{stem}/som_after.png", "crops": crops,
             "expected_strings": f"vision-review/{stem}/expected_strings.json",
             "rubric": f"vision-review/{stem}/rubric.txt", "context": f"vision-review/{stem}/context.json"},
            legend)


def _evidence_crop(name, finding, base_buf, fresh_buf, window, bundle_dir, canvas_mod) -> str | None:
    rect = finding.get("region") or finding.get("bbox")
    if not _valid_rect(rect):
        return None
    stem = Path(name).stem
    try:
        png = _twin(canvas_mod, base_buf, fresh_buf, window[0], window[1], _ri(rect),
                    finding.get("region_id", ""))
        fname = "crop_%s_%s.png" % (finding["finding_id"], finding.get("region_id", "region").replace(":", "_"))
        (bundle_dir / fname).write_bytes(png)
        return f"vision-review/{stem}/{fname}"
    except (OSError, ValueError):
        return None


# --------------------------------------------------------------------------
# reviewer dispatch
# --------------------------------------------------------------------------
def _reviewer_params() -> dict:
    return {"temperature": 0, "n": 2, "vote": "both-passes-must-emit (unanimity)",
            "order_shuffle": True, "runs": 1,
            "note": "n=2 vote honored only for model reviewers; deterministic default "
                    "runs once -- votes are meaningless when deterministic"}


def _run_cmd_reviewer(cmd: str, public_ctx: dict) -> tuple[list, list]:
    """Run the configured plugin reviewer. FAIL-CLOSED per the grounding
    contract: non-zero exit, timeout, invalid JSON, or findings-not-a-list is
    a TOOL ERROR (propagates to the top-level handler -> exit 2 -> runner red).
    A hung or garbage plugin is never a silent fallback to the deterministic
    default -- the default runs only when no --reviewer-cmd is configured.

    Returns (findings, answers, meta_kinds). `answers` is the ADDITIVE rubric-
    coverage seam (a plugin ANSWERS rubric questions via [{question_id, verdict,
    region_id?, bbox?, note?}]); it is optional, but when present it must be a
    list, exactly like findings -- a malformed answers field is a tool error, never
    a silent drop, so a plugin cannot quietly pretend it answered nothing.
    `meta_kinds` is the set of reviewer kinds the plugin declares it RAN via
    `reviewer_meta.kinds_ran` -- how a COMPOSITE wrapper (which always runs the
    deterministic pass internally and adds the model pass) registers its internal
    deterministic coverage even on a 0-changed-shot run where nothing self-tags a
    finding. Optional; malformed entries are ignored (never a tool error)."""
    try:
        argv = shlex.split(cmd)
        proc = subprocess.run(argv, input=json.dumps(public_ctx), capture_output=True,
                              text=True, timeout=REVIEWER_TIMEOUT, shell=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError(f"reviewer-cmd failed: {exc}") from exc
    if proc.returncode != 0:
        raise ValueError(f"reviewer-cmd exit {proc.returncode}: {proc.stderr.strip()[:400]}")
    try:
        doc = json.loads(proc.stdout)
        findings = doc.get("findings") if isinstance(doc, dict) else None
        answers = doc.get("answers", []) if isinstance(doc, dict) else None
        meta = doc.get("reviewer_meta") if isinstance(doc, dict) else None
    except ValueError as exc:
        raise ValueError("reviewer-cmd returned invalid JSON") from exc
    if not isinstance(findings, list):
        raise ValueError("reviewer-cmd findings not a list")
    if not isinstance(answers, list):
        raise ValueError("reviewer-cmd answers not a list")
    meta_kinds: set[str] = set()
    if isinstance(meta, dict):
        declared = meta.get("kinds_ran")
        if isinstance(declared, list):
            meta_kinds = {k for k in declared if isinstance(k, str) and k}
    return findings, answers, meta_kinds


# --------------------------------------------------------------------------
# orchestration
# --------------------------------------------------------------------------
def review_is_fresh(review_doc: dict, shots_dir: Path, baseline_dir: Path | None = None) -> bool:
    """Freshness authority: false when any covered shot's current bytes mismatch
    a hash its manifest entry recorded -- the FRESH PNG sha always, plus the
    baseline PNG sha and both sidecar shas when the entry recorded a hash (a
    recorded hash whose file is gone also counts as stale; hashes the builder
    could not record -- a missing sidecar at write time -- are skipped) -- or a
    shot WITH a baseline PNG is absent from the manifest. With baseline_dir the
    shot-scope predicate (has-baseline-PNG) is the SAME one the manifest builder
    uses; baseline_dir=None keeps the legacy has-fresh-sidecar scope and
    fresh-PNG-only comparison for callers that know only the shots dir."""
    if not isinstance(review_doc, dict) or review_doc.get("schema") != SCHEMA:
        return False
    covered = {e.get("shot"): e for e in review_doc.get("manifest", {}).get("shots_covered", [])}
    if not shots_dir.is_dir():
        return False
    for png in shots_dir.glob("*.png"):
        base_png = (baseline_dir / png.name) if baseline_dir is not None else None
        if base_png is not None:
            if not base_png.is_file():
                continue  # manifest-builder scope: baselined shots only
        elif not _sidecar_for(png).exists():
            continue  # legacy scope: only baseline-backed shots are in scope
        entry = covered.get(png.name)
        if entry is None:
            return False
        pairs: list[tuple[Path, str]] = [(png, "sha256")]
        if base_png is not None:
            pairs += [(base_png, "baseline_sha256"),
                      (_sidecar_for(png), "sidecar_fresh_sha256"),
                      (_sidecar_for(base_png), "sidecar_baseline_sha256")]
        for path, key in pairs:
            recorded = entry.get(key)
            if recorded is None:
                continue  # unrecorded (e.g. sidecar absent at write time)
            if not path.is_file():
                return False  # recorded hash but the file is gone -> stale
            try:
                if _sha256_bytes(path.read_bytes()) != recorded:
                    return False
            except OSError:
                return False
    return True


def run_vision_review(shots_dir: Path, baseline_dir: Path, output_dir: Path,
                      changed: list[str] | None = None, reviewer_cmd: str | None = None,
                      clusters_path: Path | None = None) -> dict:
    if not shots_dir.is_dir():
        raise RuntimeError(f"shots directory missing: {shots_dir}")
    if not baseline_dir.is_dir():
        raise RuntimeError(f"baseline directory missing: {baseline_dir}")

    vd = _load("visual_diff", TOOLS / "visual_diff.py")
    canvas_mod = _load("png_canvas", TOOLS / "png_canvas.py")
    global _EXPLAIN
    _EXPLAIN = _load("visual_explain", TOOLS / "visual_explain.py")  # single geometry home (rects_overlap)

    rubric_text = ""
    rubric_path = ROOT / RUBRIC_REF
    if rubric_path.exists():
        rubric_text = rubric_path.read_text(encoding="utf-8")
    clusters_doc = _load_json(clusters_path) if clusters_path and clusters_path.exists() else None
    clusters_by_shot = (clusters_doc or {}).get("shots", {})
    warnings: list[str] = []
    if clusters_doc is None:
        warnings.append("clusters.json absent/stale; degrading to sidecar-delta-only findings")

    changed_set = set(changed) if changed is not None else None
    baseline_names = {p.name for p in baseline_dir.glob("*.png")}
    shot_names = sorted(p.name for p in shots_dir.glob("*.png") if p.name in baseline_names)

    review_dir = output_dir / "vision-review"
    shots_out: list[dict] = []
    covered: list[dict] = []
    windows: list[list[int]] = []
    grounding_totals = {"emitted": 0, "grounded": 0, "dropped": 0, "dropped_reasons": {},
                        "dropped_samples": [], "ungroundable_deltas": 0, "ungroundable_clusters": 0,
                        "ungroundable_shots": []}
    reviewer_kind = "cmd" if reviewer_cmd else "deterministic-sidecar-consistency"
    run_answers: list[dict] = []  # validated rubric answers returned by a plugin reviewer
    answers_dropped = 0
    run_meta_kinds: set[str] = set()  # kinds a composite wrapper declares via reviewer_meta

    for name in shot_names:
        base_png = baseline_dir / name
        fresh_png = shots_dir / name
        fresh_bytes = fresh_png.read_bytes()
        base_bytes = base_png.read_bytes()
        base_sidecar = _load_json(_sidecar_for(base_png))
        fresh_sidecar = _load_json(_sidecar_for(fresh_png))
        window = (base_sidecar or fresh_sidecar or {}).get("window") or [1152, 648]
        windows.append(window)
        is_changed = (name in changed_set) if changed_set is not None else (fresh_bytes != base_bytes)

        covered.append({"shot": name, "sha256": _sha256_bytes(fresh_bytes),
                        "baseline_sha256": _sha256_bytes(base_bytes),
                        "sidecar_fresh_sha256": _sha256_bytes(_sidecar_for(fresh_png).read_bytes())
                        if _sidecar_for(fresh_png).exists() else None,
                        "sidecar_baseline_sha256": _sha256_bytes(_sidecar_for(base_png).read_bytes())
                        if _sidecar_for(base_png).exists() else None,
                        "changed": is_changed})
        if not is_changed:
            shots_out.append({"shot": name, "changed": False, "bundle": None,
                              "reviewer_raw_count": 0, "dropped_count": 0, "findings": []})
            continue

        table = _build_region_table(base_sidecar, fresh_sidecar, window, _shot_group(name))
        warn = _selfcheck_draw_cursor(table)
        if warn:
            warnings.append(f"{name}: {warn}")
        clusters = (clusters_by_shot.get(name) or {}).get("clusters", [])
        bundle_dir = review_dir / Path(name).stem
        paths, som_legend = assemble_bundle(name, base_png, fresh_png, base_sidecar, fresh_sidecar,
                                            clusters, table, bundle_dir, vd, canvas_mod, window, rubric_text)

        ctx = {"shot": name, "shot_kind": Path(name).stem.split("_")[0], "paths": paths,
               "region_table": table, "reviewer_params": _reviewer_params(),
               "finding_schema": SCHEMA, "window": window, "clusters": clusters,
               "som_legend": som_legend,
               "baseline_sidecar": base_sidecar, "fresh_sidecar": fresh_sidecar,
               "ungroundable_deltas": 0, "ungroundable_clusters": 0}
        # window + clusters + som_legend are part of the stdin contract (not just
        # the on-disk context.json) so a plugin reviewer can work from stdin alone:
        # frame bounds from window, change regions from clusters, and the SoM
        # number -> region_id join from som_legend (the SAME dict context.json
        # carries -- in-frame, groundable bboxes need no pixel reading).
        public_ctx = {k: ctx[k] for k in
                      ("shot", "shot_kind", "paths", "reviewer_params", "finding_schema",
                       "window", "clusters", "som_legend")}
        # anchor:<id> entries keep their stage-truth META in the public table:
        # a composite plugin reviewer (vlm_reviewer) re-runs default_reviewer over
        # this stdin ctx alone, and the anchor_drift class reads entry["meta"] for
        # anchor_id/nodes/stage_rect/tol_px. Stripping it made the internal default
        # reviewer see nodes=[]/stage_rect=None, count BOTH bars live-unverified
        # instead of running the comparison, and undercount battle hp as unanswered.
        public_ctx["region_table"] = {
            rid: {"kind": e["kind"], "rects": e["rects"], "source": e["source"],
                  **({"meta": {"anchor_id": (e.get("meta") or {}).get("anchor_id"),
                               "nodes": list((e.get("meta") or {}).get("nodes") or []),
                               "stage_rect": (e.get("meta") or {}).get("stage_rect"),
                               "tol_px": int((e.get("meta") or {}).get("tol_px", 0))}}
                     if e["kind"] == "anchor" else {})}
            for rid, e in table.items()}
        public_ctx["grounding_rules"] = {
            "cite": "region_id resolvable in region_table",
            "intersect": "bbox must pass rects_overlap against >=1 registered rect",
            "enforcement": "ungrounded findings are dropped and counted"}

        if reviewer_cmd:
            raw, raw_answers, meta_kinds = _run_cmd_reviewer(reviewer_cmd, public_ctx)
            run_meta_kinds |= meta_kinds
            # Validate the additive answers[] seam; a verdict-"no" answer that cites
            # a resolvable region + bbox becomes a quarantine finding through the SAME
            # enforce_grounding path as every other finding (ungrounded ones drop and
            # count). Every valid answer (yes or no) marks its question addressed.
            for ans in raw_answers:
                clean, reason = _validate_answer(ans)
                if clean is None:
                    answers_dropped += 1
                    warnings.append(f"{name}: dropped answer ({reason})")
                    continue
                run_answers.append(clean)
                if clean["verdict"] == "no" and clean.get("region_id") and clean.get("bbox"):
                    raw.append({"shot": name, "class": "rubric_answer_no",
                                "region_id": clean["region_id"], "bbox": clean["bbox"],
                                "severity": "medium", "confidence": "low",
                                "note": f"rubric answer 'no': {clean['question_id']}",
                                "explanation": (clean["note"] or
                                                f"Reviewer answered 'no' to rubric question "
                                                f"{clean['question_id']}."),
                                "sidecar_ref": {"source": "fresh",
                                                "field": f"answers[question_id={clean['question_id']}]",
                                                "baseline": None, "fresh": clean["verdict"]},
                                "reviewer_kind": clean["reviewer_kind"]})
        else:
            raw = default_reviewer(ctx)
            # The anchor class self-tags into the coverage ledger's ran set even on a
            # ZERO-finding pass (an aligned tree) -- the comparison itself ran -- and
            # reports anchored nodes absent from draw_order (counted, never findings).
            if ctx.get("anchor_kind_ran"):
                run_meta_kinds.add(KIND_ART_ANCHOR)
            if ctx.get("anchor_unverified"):
                warnings.append(f"{name}: art-anchor live-unverified (counted, never a "
                                f"finding): {'; '.join(ctx['anchor_unverified'])}")

        emitted, stats = enforce_grounding(raw, table, window)

        # post-review evidence crops (cited region base|fresh twin) per grounded finding
        try:
            _, _, base_buf = vd.decode_png_rgba(base_png)
            _, _, fresh_buf = vd.decode_png_rgba(fresh_png)
            for finding in emitted:
                finding["evidence_crop"] = _evidence_crop(
                    name, finding, base_buf, fresh_buf, window, bundle_dir, canvas_mod)
        except (vd.PngError, OSError) as exc:
            warnings.append(f"{name}: evidence crops skipped ({exc})")

        shots_out.append({"shot": name, "changed": True, "bundle": f"vision-review/{Path(name).stem}",
                          "reviewer_raw_count": len(raw), "dropped_count": stats["dropped"],
                          "findings": emitted})
        grounding_totals["emitted"] += stats["emitted"]
        grounding_totals["grounded"] += stats["grounded"]
        grounding_totals["dropped"] += stats["dropped"]
        for k, v in stats["dropped_reasons"].items():
            grounding_totals["dropped_reasons"][k] = grounding_totals["dropped_reasons"].get(k, 0) + v
        grounding_totals["dropped_samples"].extend(stats["dropped_samples"])
        grounding_totals["ungroundable_deltas"] += ctx.get("ungroundable_deltas", 0)
        grounding_totals["ungroundable_clusters"] += ctx.get("ungroundable_clusters", 0)
        if not table:
            grounding_totals["ungroundable_shots"].append(name)

    grounding_totals["dropped_samples"] = grounding_totals["dropped_samples"][:8]
    # Informational-only union of the per-shot effective windows (review_is_fresh and
    # grounding both use the per-shot window, never this). Derived from the shots so a
    # non-default capture reports its real frame instead of a hard-coded [1152, 648].
    manifest_window = [max((w[0] for w in windows), default=1152),
                       max((w[1] for w in windows), default=648)]
    # Rubric-coverage ledger: per-shot-group answered/unanswered, honestly counted.
    # Gap lines + inventory-drift warnings ride `warnings` so run_playtests forwards
    # them and main()/verify_all surface them -- advisory-loud, never red.
    rubric_coverage, gap_lines, coverage_warnings = compute_rubric_coverage(
        rubric_text, reviewer_kind, shots_out, covered, run_answers=run_answers,
        extra_kinds=run_meta_kinds)
    if answers_dropped:
        coverage_warnings.append(f"rubric_coverage: dropped {answers_dropped} invalid "
                                 f"reviewer answer(s) (counted, never emitted)")
    warnings.extend(coverage_warnings)
    warnings.extend(gap_lines)
    doc = {
        "schema": SCHEMA, "generated_by": "tools/vision_review.py",
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "head_sha": _head_sha(), "rubric_ref": RUBRIC_REF,
        "reviewer": {"kind": reviewer_kind, "cmd": reviewer_cmd, "params": _reviewer_params()},
        "manifest": {"window": manifest_window, "shots_covered": covered},
        "rubric_coverage": rubric_coverage,
        "grounding": grounding_totals,
        "shots": shots_out,
        "warnings": warnings,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "vision-review.json").write_text(
        json.dumps(doc, indent=2, sort_keys=True), encoding="utf-8")
    return doc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots-dir", type=Path, required=True)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".godot-smoke")
    parser.add_argument("--changed", default=None,
                        help="comma-separated shot names to force-treat as changed")
    parser.add_argument("--reviewer-cmd", default=None,
                        help="external reviewer (stdin JSON, stdout {\"findings\":[...]}); "
                             "non-zero exit / timeout / invalid JSON is a tool error "
                             "(exit 2, fail-closed) -- never a silent fallback to the default")
    parser.add_argument("--clusters", type=Path, default=None,
                        help="clusters.json from visual_region_diff (default: output-dir/region-diff/clusters.json)")
    args = parser.parse_args()

    changed = [s for s in args.changed.split(",")] if args.changed else None
    clusters_path = args.clusters or (args.output_dir / "region-diff" / "clusters.json")
    try:
        doc = run_vision_review(args.shots_dir, args.baseline_dir, args.output_dir,
                                changed=changed, reviewer_cmd=args.reviewer_cmd,
                                clusters_path=clusters_path)
    except Exception as exc:  # tool error -> fail red (exit 2)
        print(f"error: vision review failed: {exc}", file=sys.stderr)
        return EXIT_ERROR

    g = doc["grounding"]
    for shot in doc["shots"]:
        for finding in shot["findings"]:
            print("quarantine %s [%s] %s: %s" % (shot["shot"], finding["class"],
                                                 finding["region_id"], finding["explanation"]),
                  file=sys.stderr)
    for warn in doc.get("warnings", []):
        print(f"warn: {warn}", file=sys.stderr)
    cov = doc.get("rubric_coverage", {})
    ct = cov.get("totals", {})
    gap_detail = ("; " + "; ".join(gp["reason"] for gp in cov.get("gaps", []))
                  if cov.get("gaps") else "")
    print("vision-review: %d shot(s), %d finding(s) emitted, %d grounded, %d dropped, reviewer=%s"
          % (len(doc["shots"]), g["emitted"], g["grounded"], g["dropped"], doc["reviewer"]["kind"]),
          file=sys.stderr)
    print("rubric-coverage: %d/%d question(s) answered by a fresh reviewer pass; "
          "%d unanswered across %d shot-group(s)%s"
          % (ct.get("questions_answered", 0), ct.get("questions_total", 0),
             ct.get("unanswered", 0), ct.get("groups_with_gap", 0), gap_detail),
          file=sys.stderr)
    print(json.dumps({"schema": doc["schema"], "grounding": g,
                      "reviewer": doc["reviewer"]["kind"], "shots": len(doc["shots"]),
                      "rubric_coverage": ct}, sort_keys=True))
    return EXIT_OK  # findings are quarantine-tier; only tool errors exit 2


if __name__ == "__main__":
    sys.exit(main())
