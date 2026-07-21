#!/usr/bin/env python3
"""Explainable per-region visual diff over committed sidecars (stdlib-only).

visual_diff.py stays the global gate (0.5% changed at per-channel tolerance 8,
exit 0/1/2) and is UNTOUCHED; this tool adds the legible per-region layer on top.
It imports visual_diff's PNG decoder via importlib and replicates its
changed-pixel builder verbatim (returning the index SET, which visual_diff keeps
internal) so the recomputed global backstop agrees with the in-engine number.

Region tiers, driven by the committed baseline sidecar:
  - canary_rect at tolerance ~0 (strict channel equality) = FIRST RED-TIER region;
  - expected_regions ink/string rects + baseline labels[].display_rect near-zero = RED;
  - cursor_pairs rects (model cursor cell + live) = MASKED known-dynamic zones
    (the pair's "row" rect is NOT masked: it covers label ink — see _regions);
  - clusters outside every coded region, below the global gate = quarantine-tier
    region_drift + the explicit unexplained queue (guards false closure);
  - the global 0.5%/tolerance-8 gate recomputed as a backstop (RED when exceeded).

Outputs into --output-dir: clusters.json (machine-readable cluster bboxes +
explanations), <shot>.ascii.txt (32x18 change-density grid an agent reads with no
vision), and <shot>.triptych.png (base|shot|diff via png_canvas). Exit-code
contract mirrors visual_diff.py: 0 pass / 1 drift (red-tier failures) / 2 error.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
DEFAULT_THRESHOLD_PCT = 0.5
DEFAULT_TOLERANCE = 8
GRID_COLS, GRID_ROWS, CELL = 32, 18, 36  # 1152/36 x 648/36 canonical window
RAMP = ".:-=*#%@"
EXIT_PASS, EXIT_DRIFT, EXIT_ERROR = 0, 1, 2
RED_REGION_KINDS = {"canary", "ink", "string", "label"}


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def changed_pixel_set(buf_a: bytes, buf_b: bytes, tolerance: int) -> set[int]:
    """Changed-pixel INDICES; verbatim visual_diff.changed_pixel_count internals
    (per-channel plane diff, xor prefilter, delta > tolerance) returning the set
    instead of its length so len(result) == visual_diff's count."""
    changed: set[int] = set()
    for channel in range(4):
        plane_a = buf_a[channel::4]
        plane_b = buf_b[channel::4]
        if plane_a == plane_b:
            continue
        xor_int = int.from_bytes(plane_a, "little") ^ int.from_bytes(plane_b, "little")
        delta = xor_int.to_bytes(len(plane_a), "little")
        for match in re.finditer(rb"[^\x00]", delta):
            index = match.start()
            if abs(plane_a[index] - plane_b[index]) > tolerance:
                changed.add(index)
    return changed


def _mask_indices(rects: list[list[int]], width: int, height: int) -> set[int]:
    """Pixel indices covered by the known-dynamic mask rects (cursor cells)."""
    masked: set[int] = set()
    for rect in rects:
        if not (isinstance(rect, list) and len(rect) == 4):
            continue
        x0 = max(0, int(rect[0])); y0 = max(0, int(rect[1]))
        x1 = min(width, int(rect[0]) + int(rect[2])); y1 = min(height, int(rect[1]) + int(rect[3]))
        for y in range(y0, y1):
            base = y * width
            for x in range(x0, x1):
                masked.add(base + x)
    return masked


def _cluster(indices: set[int], width: int, height: int) -> list[dict]:
    """4-connected components over changed pixel indices -> bbox + count each."""
    remaining = set(indices)
    clusters: list[dict] = []
    while remaining:
        start = next(iter(remaining))
        remaining.discard(start)
        stack = [start]
        minx = miny = 10 ** 9
        maxx = maxy = -1
        count = 0
        while stack:
            p = stack.pop()
            x = p % width
            y = p // width
            count += 1
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for nb in ((p - 1) if x > 0 else -1, (p + 1) if x < width - 1 else -1,
                       (p - width) if y > 0 else -1, (p + width) if y < height - 1 else -1):
                if nb in remaining:
                    remaining.discard(nb)
                    stack.append(nb)
        clusters.append({"bbox": [minx, miny, maxx - minx + 1, maxy - miny + 1], "changed": count})
    clusters.sort(key=lambda c: (-c["changed"], c["bbox"]))
    return clusters


def _sidecar_rects(sidecar: dict | None) -> dict:
    """Pull the coded regions + mask out of a (baseline) sidecar, tolerant of gaps."""
    out = {"canary": None, "ink": [], "strings": [], "labels": [], "mask": []}
    if not isinstance(sidecar, dict):
        return out
    canary = sidecar.get("canary_rect")
    if isinstance(canary, list) and len(canary) == 4 and any(canary):
        out["canary"] = [int(v) for v in canary]
    expected = sidecar.get("expected_regions") or {}
    for rect in expected.get("ink", []) or []:
        if isinstance(rect, list) and len(rect) == 4:
            out["ink"].append([int(v) for v in rect])
    for entry in expected.get("strings", []) or []:
        rect = entry.get("region") if isinstance(entry, dict) else None
        if isinstance(rect, list) and len(rect) == 4:
            out["strings"].append({"region": [int(v) for v in rect],
                                   "text": str(entry.get("text", ""))})
    for label in sidecar.get("labels", []) or []:
        rect = label.get("display_rect") if isinstance(label, dict) else None
        if isinstance(rect, list) and len(rect) == 4:
            out["labels"].append({"region": [int(v) for v in rect],
                                  "text": str(label.get("text", ""))})
    for pair in sidecar.get("cursor_pairs", []) or []:
        if not isinstance(pair, dict):
            continue
        # Mask the model cursor cell + the live cursor only. The pair's "row"
        # rect is deliberately NOT masked: it spans the whole menu row and would
        # cover label ink, blinding the string-region gate to a deleted/changed
        # move label. Rows are deterministic here (the crafted state pins the
        # cursor selection), so cursor+live masking is the flake-safe set.
        for key in ("cursor", "live"):
            rect = pair.get(key)
            if isinstance(rect, list) and len(rect) == 4 and any(rect):
                out["mask"].append([int(v) for v in rect])
    return out


def _classify(bbox: list[int], rects: dict, rects_overlap) -> tuple[str | None, list[int] | None, str | None]:
    """Map a cluster bbox to the coded region it overlaps (priority order).
    rects_overlap is visual_explain.rects_overlap — the single geometry home."""
    if rects["canary"] and rects_overlap(bbox, rects["canary"]):
        return "canary", rects["canary"], None
    for entry in rects["strings"]:
        if rects_overlap(bbox, entry["region"]):
            return "string", entry["region"], entry["text"]
    for entry in rects["labels"]:
        if rects_overlap(bbox, entry["region"]):
            return "label", entry["region"], entry["text"]
    for rect in rects["ink"]:
        if rects_overlap(bbox, rect):
            return "ink", rect, None
    return None, None, None


def _ascii_grid(indices: set[int], width: int, height: int, header: list[str]) -> str:
    cols = min(GRID_COLS, max(1, width // CELL))
    rows = min(GRID_ROWS, max(1, height // CELL))
    counts = [[0] * cols for _ in range(rows)]
    for p in indices:
        x = p % width
        y = p // width
        c = min(cols - 1, x // CELL)
        r = min(rows - 1, y // CELL)
        counts[r][c] += 1
    lines = list(header) + [""]
    lines.append("change-density grid (%dx%d cells, %dpx each):" % (cols, rows, CELL))
    lines.append("legend: " + " ".join("%s=%s" % (ch, lab) for ch, lab in zip(
        RAMP, ["0", "1-2", "3-9", "10-39", "40-159", "160-639", "640-2559", "2560+"])))
    for r in range(rows):
        row_chars = []
        for c in range(cols):
            n = counts[r][c]
            if n <= 0: idx = 0
            elif n < 3: idx = 1
            elif n < 10: idx = 2
            elif n < 40: idx = 3
            elif n < 160: idx = 4
            elif n < 640: idx = 5
            elif n < 2560: idx = 6
            else: idx = 7
            row_chars.append(RAMP[idx])
        lines.append("".join(row_chars))
    return "\n".join(lines) + "\n"


def _triptych(png_canvas, base_buf, shot_buf, analysis, clusters, width, height) -> bytes:
    factor = 4
    bw, bh, base_small = png_canvas.downscale(base_buf, width, height, factor)
    sw, sh, shot_small = png_canvas.downscale(shot_buf, width, height, factor)
    diff = png_canvas.Canvas(width, height, (0, 0, 0, 255))
    red = (255, 48, 48, 255)
    for p in analysis:
        diff.set_pixel(p % width, p // width, red)
    dw, dh, diff_small = png_canvas.downscale(diff.buf, width, height, factor)
    gap, label_h = 8, 12
    canvas = png_canvas.Canvas(bw * 3 + gap * 4, bh + gap * 2 + label_h, (24, 24, 24, 255))
    y0 = gap + label_h
    panels = [gap, gap * 2 + bw, gap * 3 + bw * 2]
    for px, buf, name in zip(panels, (base_small, shot_small, diff_small), ("BASE", "SHOT", "DIFF")):
        canvas.blit(px, y0, bw, bh, buf)
        canvas.text(px, gap, name, (200, 200, 200, 255))
    amber = (255, 200, 0, 255)
    for i, cluster in enumerate(clusters):
        x, y, w, h = cluster["bbox"]
        color = red if cluster.get("tier") == "red" else amber
        bx, by = x // factor, y // factor
        bwi, bhi = max(2, w // factor), max(2, h // factor)
        for px in (panels[1], panels[2]):
            canvas.box(px + bx, y0 + by, bwi, bhi, color)
            canvas.text(px + bx, y0 + by - 6 if by >= 6 else y0 + by + bhi + 1, str(i + 1), color)
    return canvas.png()


def _load_sidecar(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def sidecar_path_for(png: Path) -> Path:
    """<shot>.png -> <shot>.png.sidecar.json (pinned spelling, sibling of the PNG)."""
    return png.with_name(png.name + ".sidecar.json")


def diff_shot(vd, png_canvas, explain, name, shots_dir, baseline_dir, out_dir,
              threshold_pct, tolerance) -> dict:
    shot_png = shots_dir / name
    base_png = baseline_dir / name
    shot_bytes = shot_png.read_bytes()
    base_bytes = base_png.read_bytes()
    if shot_bytes == base_bytes:
        return {"status": "byte-identical", "global_pct": 0.0, "global_fail": False,
                "clusters": [], "region_failures": [], "quarantine": []}
    shot_w, shot_h, shot_buf = vd.decode_png_rgba(shot_png)
    base_w, base_h, base_buf = vd.decode_png_rgba(base_png)
    if (shot_w, shot_h) != (base_w, base_h):
        raise vd.PngError(f"{name}: size mismatch shot {shot_w}x{shot_h} vs baseline {base_w}x{base_h}")
    width, height, total = shot_w, shot_h, shot_w * shot_h

    # Global backstop: verbatim visual_diff algorithm at the global tolerance,
    # unmasked, so len == the in-engine number.
    global_changed = changed_pixel_set(shot_buf, base_buf, tolerance)
    global_pct = round(len(global_changed) * 100.0 / total, 4) if total else 0.0
    global_fail = global_pct > threshold_pct

    base_sidecar = _load_sidecar(sidecar_path_for(base_png))
    fresh_sidecar = _load_sidecar(sidecar_path_for(shot_png))
    rects = _sidecar_rects(base_sidecar)
    masked = _mask_indices(rects["mask"], width, height)

    # Region analysis: strict (tolerance 0) change set minus known-dynamic masks.
    strict = changed_pixel_set(shot_buf, base_buf, 0)
    analysis = strict - masked
    clusters = _cluster(analysis, width, height)
    region_failures: list[dict] = []
    quarantine: list[dict] = []
    for cluster in clusters:
        kind, region, text = _classify(cluster["bbox"], rects, explain.rects_overlap)
        cluster["region_kind"] = kind
        cluster["region"] = region
        cluster["region_text"] = text
        cluster["tier"] = "red" if kind in RED_REGION_KINDS else "quarantine"
    explain.explain_clusters(clusters, base_sidecar, fresh_sidecar)
    for cluster in clusters:
        record = {"shot": name, "kind": cluster.get("kind", "unexplained"),
                  "region": cluster.get("region") or cluster.get("bbox"),
                  "detail": cluster.get("sentence", "")}
        if cluster.get("tier") == "red":
            region_failures.append(record)
        else:
            record["kind"] = "region_drift"
            quarantine.append(record)
    if global_fail:
        region_failures.append({"shot": name, "kind": "global_backstop", "region": [],
                                "detail": "global gate %.4f%% > %.2f%% at tolerance %d (backstop)"
                                          % (global_pct, threshold_pct, tolerance)})

    header = [
        "shot: %s" % name,
        "global: %.4f%% changed (%d px) threshold %.2f%% tol %d -> %s"
        % (global_pct, len(global_changed), threshold_pct, tolerance, "FAIL" if global_fail else "ok"),
        "sidecar: %s" % ("present" if base_sidecar else "ABSENT (only global backstop applies)"),
        "clusters: %d (red %d, quarantine %d)"
        % (len(clusters), len(region_failures) - (1 if global_fail else 0), len(quarantine)),
    ]
    for cluster in clusters:
        header.append("  [%s] %s" % (cluster.get("tier", "?"), cluster.get("sentence", "")))
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(name).stem
    (out_dir / f"{stem}.ascii.txt").write_text(
        _ascii_grid(analysis, width, height, header), encoding="utf-8")
    try:
        (out_dir / f"{stem}.triptych.png").write_bytes(
            _triptych(png_canvas, base_buf, shot_buf, analysis, clusters, width, height))
    except (OSError, ValueError) as exc:  # triptych is a convenience; never fail the gate on it
        header.append("triptych skipped: %s" % exc)
    if base_sidecar is None:
        # A locally deleted baseline sidecar silently degrades this shot to the
        # global backstop (the red-tier coded regions cannot run). Surface it in
        # quarantine (report/stderr tier, never a failure) instead of passing quiet.
        quarantine.append({"shot": name, "kind": "sidecar_absent", "region": [],
                           "detail": "baseline sidecar missing; only the global backstop applies (per-region gate degraded)"})
    return {"status": "compared", "global_pct": global_pct, "global_fail": global_fail,
            "clusters": clusters, "region_failures": region_failures, "quarantine": quarantine,
            "has_sidecar": base_sidecar is not None}


def run_region_diff(shots_dir: Path, baseline_dir: Path, out_dir: Path,
                    threshold_pct: float = DEFAULT_THRESHOLD_PCT,
                    tolerance: int = DEFAULT_TOLERANCE) -> dict:
    if not shots_dir.is_dir():
        return {"ok": False, "errors": [f"shots directory missing: {shots_dir}"],
                "region_failures": [], "quarantine": [], "clusters_explained": 0,
                "clusters_unexplained": 0, "artifacts": []}
    if not baseline_dir.is_dir():
        return {"ok": False, "errors": [f"baseline directory missing: {baseline_dir}"],
                "region_failures": [], "quarantine": [], "clusters_explained": 0,
                "clusters_unexplained": 0, "artifacts": []}
    # Clear stale per-shot artifacts first so renamed/deleted shots or perturbation
    # runs leave no misleading leftovers (clusters.json is overwritten below).
    if out_dir.is_dir():
        for pattern in ("*.ascii.txt", "*.triptych.png"):
            for stale in out_dir.glob(pattern):
                try:
                    stale.unlink()
                except OSError:
                    pass
    vd = _load("visual_diff", TOOLS / "visual_diff.py")
    png_canvas = _load("png_canvas", TOOLS / "png_canvas.py")
    explain = _load("visual_explain", TOOLS / "visual_explain.py")

    shot_names = sorted(p.name for p in shots_dir.glob("*.png"))
    baseline_names = {p.name for p in baseline_dir.glob("*.png")}
    errors: list[str] = []
    skipped: list[str] = []
    shots: dict[str, dict] = {}
    all_region_failures: list[dict] = []
    all_quarantine: list[dict] = []
    clusters_explained = clusters_unexplained = 0
    compared = 0
    for name in shot_names:
        if name not in baseline_names:
            skipped.append(name)  # owned by the in-engine missing-baseline gate
            continue
        try:
            record = diff_shot(vd, png_canvas, explain, name, shots_dir, baseline_dir,
                               out_dir, threshold_pct, tolerance)
        except (vd.PngError, OSError) as exc:
            errors.append(f"{name}: {exc}")
            continue
        compared += 1
        shots[name] = record
        all_region_failures.extend(record["region_failures"])
        all_quarantine.extend(record["quarantine"])
        for cluster in record["clusters"]:
            if cluster.get("explained"):
                clusters_explained += 1
            else:
                clusters_unexplained += 1

    clusters_doc = {
        "generated_by": "visual_region_diff.py",
        "threshold_pct": threshold_pct,
        "tolerance": tolerance,
        "shots": {name: {"status": rec["status"], "global_pct": rec["global_pct"],
                         "global_fail": rec["global_fail"], "clusters": rec["clusters"]}
                  for name, rec in shots.items()},
    }
    artifacts: list[str] = []
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        clusters_path = out_dir / "clusters.json"
        clusters_path.write_text(json.dumps(clusters_doc, indent=2, sort_keys=True), encoding="utf-8")
        artifacts.append(str(clusters_path))
        artifacts += sorted(str(p) for p in out_dir.glob("*.ascii.txt"))
        artifacts += sorted(str(p) for p in out_dir.glob("*.triptych.png"))
    except OSError as exc:
        errors.append(f"cannot write output dir {out_dir}: {exc}")

    max_drift = max((rec["global_pct"] for rec in shots.values()), default=0.0)
    return {
        "ok": not errors and not all_region_failures,
        "errors": errors,
        "shots_compared": compared,
        "skipped_no_baseline": skipped,
        "region_failures": all_region_failures,
        "quarantine": all_quarantine,
        "clusters_explained": clusters_explained,
        "clusters_unexplained": clusters_unexplained,
        "global_backstop": {"max_drift_pct": max_drift, "threshold_pct": threshold_pct,
                            "tolerance": tolerance,
                            "mismatched": sorted(n for n, r in shots.items() if r["global_fail"])},
        "artifacts": artifacts,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots-dir", type=Path, required=True)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".godot-smoke" / "region-diff")
    parser.add_argument("--threshold-pct", type=float, default=DEFAULT_THRESHOLD_PCT)
    parser.add_argument("--tolerance", type=int, default=DEFAULT_TOLERANCE)
    args = parser.parse_args()
    result = run_region_diff(args.shots_dir, args.baseline_dir, args.output_dir,
                             args.threshold_pct, args.tolerance)
    for failure in result["region_failures"]:
        print("RED %s [%s]: %s" % (failure["shot"], failure["kind"], failure["detail"]), file=sys.stderr)
    for finding in result["quarantine"]:
        print("quarantine %s: %s" % (finding["shot"], finding["detail"]), file=sys.stderr)
    for error in result["errors"]:
        print("error: %s" % error, file=sys.stderr)
    printable = {k: v for k, v in result.items()}
    print(json.dumps(printable, sort_keys=True))
    if result["errors"]:
        return EXIT_ERROR
    return EXIT_PASS if result["ok"] else EXIT_DRIFT


if __name__ == "__main__":
    sys.exit(main())
