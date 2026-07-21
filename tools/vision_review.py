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

Stdlib-only. Reuses visual_diff.decode_png_rgba, png_canvas, and
visual_explain.rects_overlap via the sanctioned importlib pattern (never forked).
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

# SoM outline colour per region kind; numbering is kind-priority then region-id.
KIND_COLOR = {
    "canary": (255, 48, 48, 255),
    "string": (255, 200, 0, 255),
    "ink": (255, 200, 0, 255),
    "label": (255, 200, 0, 255),
    "cursor": (0, 220, 255, 255),
    "draw": (160, 160, 160, 255),
    "palette:canary": (255, 0, 255, 255),
}
KIND_ORDER = {"cursor": 0, "string": 1, "label": 2, "ink": 3, "canary": 4, "draw": 5, "palette:canary": 6}


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


# --------------------------------------------------------------------------
# region table: union of fresh + baseline sidecars, addressed per regionIdSpace
# --------------------------------------------------------------------------
def _build_region_table(base: dict | None, fresh: dict | None, window: list[int]) -> dict:
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
def _mk(shot, cls, region_id, bbox, severity, confidence, note, explanation, sidecar_ref):
    return {"shot": shot, "class": cls, "region_id": region_id, "bbox": _ri(bbox),
            "severity": severity, "confidence": confidence, "note": note,
            "explanation": explanation, "sidecar_ref": sidecar_ref,
            "reviewer_kind": "deterministic-sidecar-consistency"}


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
    cursor > string > label > ink > canary > draw (smallest) > palette:canary."""
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


def _run_cmd_reviewer(cmd: str, public_ctx: dict) -> list[dict]:
    """Run the configured plugin reviewer. FAIL-CLOSED per the grounding
    contract: non-zero exit, timeout, invalid JSON, or findings-not-a-list is
    a TOOL ERROR (propagates to the top-level handler -> exit 2 -> runner red).
    A hung or garbage plugin is never a silent fallback to the deterministic
    default -- the default runs only when no --reviewer-cmd is configured."""
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
    except ValueError as exc:
        raise ValueError("reviewer-cmd returned invalid JSON") from exc
    if not isinstance(findings, list):
        raise ValueError("reviewer-cmd findings not a list")
    return findings


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

        table = _build_region_table(base_sidecar, fresh_sidecar, window)
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
        public_ctx["region_table"] = {rid: {"kind": e["kind"], "rects": e["rects"], "source": e["source"]}
                                      for rid, e in table.items()}
        public_ctx["grounding_rules"] = {
            "cite": "region_id resolvable in region_table",
            "intersect": "bbox must pass rects_overlap against >=1 registered rect",
            "enforcement": "ungrounded findings are dropped and counted"}

        if reviewer_cmd:
            raw = _run_cmd_reviewer(reviewer_cmd, public_ctx)
        else:
            raw = default_reviewer(ctx)

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
    doc = {
        "schema": SCHEMA, "generated_by": "tools/vision_review.py",
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "head_sha": _head_sha(), "rubric_ref": RUBRIC_REF,
        "reviewer": {"kind": reviewer_kind, "cmd": reviewer_cmd, "params": _reviewer_params()},
        "manifest": {"window": manifest_window, "shots_covered": covered},
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
    print("vision-review: %d shot(s), %d finding(s) emitted, %d grounded, %d dropped, reviewer=%s"
          % (len(doc["shots"]), g["emitted"], g["grounded"], g["dropped"], doc["reviewer"]["kind"]),
          file=sys.stderr)
    print(json.dumps({"schema": doc["schema"], "grounding": g,
                      "reviewer": doc["reviewer"]["kind"], "shots": len(doc["shots"])}, sort_keys=True))
    return EXIT_OK  # findings are quarantine-tier; only tool errors exit 2


if __name__ == "__main__":
    sys.exit(main())
