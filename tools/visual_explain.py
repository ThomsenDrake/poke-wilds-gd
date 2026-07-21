#!/usr/bin/env python3
"""Sidecar<->cluster join that turns raw change clusters into explanations.

visual_region_diff.py does the pixel work and hands each change cluster here
with the coded region it overlaps (canary / ink / string / label / none). This
module joins that against the committed baseline sidecar and, when present, the
fresh shot sidecar, to produce exactly ONE explanation sentence per cluster --
or an explicit `unexplained` tag. The explicit unexplained queue is deliberate:
it guards against false closure (a green-looking run that silently dropped a
label nobody named). Kinds: canary_absent, canary_shifted, palette_dropped,
label_deleted, label_moved, label_overlap_sprite, string_drift, region_ink_lost,
unexplained. Stdlib-only. As a CLI it pretty-prints a clusters.json plus the
unexplained queue so an agent can read the verdict with no vision. Exit 0.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

RED_KINDS = {
    "canary_absent", "canary_shifted", "palette_dropped",
    "label_deleted", "label_moved", "label_overlap_sprite",
    "string_drift", "region_ink_lost",
}


def rects_overlap(a: list[int], b: list[int]) -> bool:
    """True when two [x, y, w, h] integer rects share any area."""
    return not (a[0] + a[0 + 2] <= b[0] or b[0] + b[2] <= a[0]
                or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1])


def _fmt_rect(rect: list[int] | None) -> str:
    return "[]" if not rect else "(%d,%d,%d,%d)" % tuple(rect[:4])


def _labels(sidecar: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(sidecar, dict):
        return []
    labels = sidecar.get("labels")
    return labels if isinstance(labels, list) else []


def _label_texts(sidecar: dict[str, Any] | None) -> set[str]:
    return {str(l.get("text", "")) for l in _labels(sidecar) if l.get("text")}


def _label_rect(sidecar: dict[str, Any] | None, text: str) -> list[int] | None:
    for label in _labels(sidecar):
        if str(label.get("text", "")) == text:
            rect = label.get("display_rect")
            if isinstance(rect, list) and len(rect) == 4:
                return [int(v) for v in rect]
    return None


def _palette(sidecar: dict[str, Any] | None, key: str) -> list[str]:
    if not isinstance(sidecar, dict):
        return []
    palettes = sidecar.get("palettes")
    if not isinstance(palettes, dict):
        return []
    colors = palettes.get(key)
    return colors if isinstance(colors, list) else []


def _canary_rect(sidecar: dict[str, Any] | None) -> list[int] | None:
    if not isinstance(sidecar, dict):
        return None
    rect = sidecar.get("canary_rect")
    return [int(v) for v in rect] if isinstance(rect, list) and len(rect) == 4 and any(rect) else None


def _canary_species(sidecar: dict[str, Any] | None) -> str:
    """Canary species name from the sidecar's crafted_state.wild[0] (the visual
    sweep's single source of truth); 'canary' when absent, so the prose never
    names a sprite the crafted state does not pin."""
    crafted = (sidecar or {}).get("crafted_state")
    wild = crafted.get("wild") if isinstance(crafted, dict) else None
    if isinstance(wild, list) and wild and str(wild[0]):
        return str(wild[0])
    return "canary"


def _explain_canary(cluster: dict, base: dict | None, fresh: dict | None) -> dict:
    rect = _fmt_rect(cluster.get("region"))
    base_colors = set(_palette(base, "canary"))
    fresh_colors = set(_palette(fresh, "canary"))
    if fresh_colors and base_colors:
        dropped = sorted(base_colors - fresh_colors)
        if dropped:
            return {"kind": "canary_absent", "explained": True, "sentence":
                    "canary_absent: %s canary dropped %d/%d baseline colors in %s (%s) -- sprite absent/changed"
                    % (_canary_species(base), len(dropped), len(base_colors), rect, ", ".join(dropped[:4]))}
        if base_colors != fresh_colors:
            return {"kind": "palette_dropped", "explained": True, "sentence":
                    "palette_dropped: canary palette changed in %s (baseline %d colors, fresh %d)"
                    % (rect, len(base_colors), len(fresh_colors))}
    return {"kind": "canary_shifted", "explained": True, "sentence":
            "canary_shifted: %d canary pixels changed in %s (frame/offset drift)"
            % (cluster.get("changed", 0), rect)}


def _explain_string(cluster: dict, base: dict | None, fresh: dict | None) -> dict:
    text = cluster.get("region_text") or "?"
    rect = _fmt_rect(cluster.get("region"))
    if fresh is not None:
        if text not in _label_texts(fresh):
            return {"kind": "label_deleted", "explained": True, "sentence":
                    "label_deleted: expected string '%s' not rendered near %s" % (text, rect)}
        fresh_rect = _label_rect(fresh, text)
        region = cluster.get("region")
        if fresh_rect and region and not rects_overlap(fresh_rect, region):
            return {"kind": "label_moved", "explained": True, "sentence":
                    "label_moved: '%s' moved from %s to %s" % (text, rect, _fmt_rect(fresh_rect))}
    return {"kind": "string_drift", "explained": True, "sentence":
            "string_drift: expected string '%s' region %s changed (%d px)"
            % (text, rect, cluster.get("changed", 0))}


def _explain_label(cluster: dict, base: dict | None, fresh: dict | None) -> dict:
    text = cluster.get("region_text") or "?"
    rect = _fmt_rect(cluster.get("region"))
    if fresh is not None and text not in _label_texts(fresh):
        return {"kind": "label_deleted", "explained": True, "sentence":
                "label_deleted: baseline label '%s' at %s is gone in the fresh capture" % (text, rect)}
    if fresh is not None:
        fresh_rect = _label_rect(fresh, text)
        region = cluster.get("region")
        if fresh_rect and region and not rects_overlap(fresh_rect, region):
            return {"kind": "label_moved", "explained": True, "sentence":
                    "label_moved: label '%s' moved from %s to %s" % (text, rect, _fmt_rect(fresh_rect))}
    canary = _canary_rect(base)
    region = cluster.get("region")
    if canary and region and rects_overlap(region, canary):
        return {"kind": "label_overlap_sprite", "explained": True, "sentence":
                "label_overlap_sprite: label '%s' at %s overlaps the canary sprite %s"
                % (text, rect, _fmt_rect(canary))}
    return {"kind": "region_ink_lost", "explained": True, "sentence":
            "region_ink_lost: label '%s' ink at %s changed (%d px)"
            % (text, rect, cluster.get("changed", 0))}


def explain(cluster: dict, base: dict | None, fresh: dict | None) -> dict:
    """Join one cluster against the sidecars; always returns kind+sentence+explained."""
    kind = cluster.get("region_kind")
    if kind == "canary":
        verdict = _explain_canary(cluster, base, fresh)
    elif kind == "string":
        verdict = _explain_string(cluster, base, fresh)
    elif kind == "label":
        verdict = _explain_label(cluster, base, fresh)
    elif kind == "ink":
        verdict = {"kind": "region_ink_lost", "explained": True, "sentence":
                   "region_ink_lost: expected ink region %s changed (%d px)"
                   % (_fmt_rect(cluster.get("region")), cluster.get("changed", 0))}
    else:
        verdict = {"kind": "unexplained", "explained": False, "sentence":
                   "unexplained: %d changed px at %s outside all coded regions (quarantine-tier)"
                   % (cluster.get("changed", 0), _fmt_rect(cluster.get("bbox")))}
    return verdict


def explain_clusters(clusters: list[dict], base: dict | None, fresh: dict | None) -> tuple[list[dict], int, int]:
    """Attach kind/sentence/explained to every cluster; return (clusters, explained, unexplained)."""
    explained = unexplained = 0
    for cluster in clusters:
        verdict = explain(cluster, base, fresh)
        cluster.update(verdict)
        if verdict["explained"]:
            explained += 1
        else:
            unexplained += 1
    return clusters, explained, unexplained


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--clusters", type=Path, required=True,
                        help="clusters.json written by visual_region_diff.py")
    args = parser.parse_args()
    try:
        data = json.loads(args.clusters.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"error: cannot read {args.clusters}: {exc}", file=sys.stderr)
        return 2
    total_explained = total_unexplained = 0
    for shot in sorted(data.get("shots", {})):
        entry = data["shots"][shot]
        clusters = entry.get("clusters", [])
        if not clusters:
            continue
        print(f"{shot}:")
        for cluster in clusters:
            sentence = cluster.get("sentence") or explain(cluster, None, None)["sentence"]
            tier = cluster.get("tier", "quarantine")
            print(f"  [{tier}] {sentence}")
            if cluster.get("explained", False):
                total_explained += 1
            else:
                total_unexplained += 1
    unexplained_queue = [
        {"shot": shot, "bbox": cluster.get("bbox")}
        for shot in sorted(data.get("shots", {}))
        for cluster in data["shots"][shot].get("clusters", [])
        if not cluster.get("explained", False)
    ]
    print(f"\nclusters explained: {total_explained}, unexplained: {total_unexplained}")
    if unexplained_queue:
        print("unexplained queue (guard against false closure):")
        for item in unexplained_queue:
            print(f"  {item['shot']} bbox={item['bbox']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
