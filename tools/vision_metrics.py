#!/usr/bin/env python3
"""Optional SSIM-map corroboration over baseline|fresh shot pairs (Slice 6).

This is the ONE documented exemption from the core-tools stdlib-only rule
(`OPTIONAL_TOOL_EXEMPTIONS` in tools/check_repo_contracts.py): it imports
scikit-image (+ numpy) from the repo-root pyproject extra
`[project.optional-dependencies] vision = ["scikit-image>=0.22"]`
(`uv sync --extra vision`, or `pip install scikit-image`). Every other tool
stays stdlib-only, and the core verification path never imports this module —
the guard's hardening clause flags any core tool that STATICALLY imports it
(an AST walk over committed source; a runtime `importlib` load of this file is
out of scope for that static guard — the sanctioned sibling-tool importlib
pattern is a reviewed convention, not something the guard enforces at runtime).

QUARANTINE-TIER FOREVER, NEVER A GATE. SSIM windowing averages over 8-16px
windows, which DILUTES exactly the sprite-scale (1-frame strip offset) and
glyph-scale (1-2px XOR) defects the coded oracles catch at exact pixels, so
this tool's output is corroboration/localization heat only, never a verdict:
  (a) it is NOT called from run_playtests.py (no apply_* post-step wiring,
      unlike the region diff / contrast / CVD / Lane-4 review);
  (b) its ssim_divergence findings are quarantine-tier forever — nothing here
      flips any result["ok"], and no graduation streak can promote them;
  (c) the standalone exit code is always 0 except hard misuse (bad args);
      decode/shape failures degrade to a skipped note + warn per pair;
  (d) it lives behind its own registry entry (docs/registry/subsystems.toml,
      vision_fidelity) plus the file-scoped stdlib-guard exemption.

Importable-graceful: WITHOUT scikit-image, every entry point returns
{"skipped": true, "reason": ...} and the CLI prints a skipped note and exits 0
— never an error path that blocks a report or a run. CI (the legibility-garden
workflow: no Godot, no scikit-image, no fresh shots) renders a skip note by
construction.

CLI: python3 tools/vision_metrics.py --shots-dir .godot-smoke/shots \
       --baseline-dir docs/generated/visual-baselines \
       --out .godot-smoke/vision-metrics.json

Per baseline|fresh PNG pair (both present; byte-identical pairs take the same
shortcut as visual_region_diff): grayscale SSIM MAP via
`structural_similarity(a, b, full=True, win_size=7, data_range=255)` on
stdlib-decoded pixels (visual_diff.decode_png_rgba via the sanctioned importlib
pattern — never a forked decoder), tiled into WINDOW_PX windows; a window whose
MEAN SSIM falls below MEAN_SSIM_FLOOR emits a corroboration finding
{kind: "ssim_divergence", shot, region (display px), mean_ssim,
min_window_ssim}. Output doc {schema: "vision-metrics/1", head_sha,
generated_at, parameters, pairs, skipped, findings[]} (gitignored).
"""
from __future__ import annotations

import argparse
import importlib.util
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

# Graceful-degradation guard: this module imports cleanly WITHOUT the optional
# extra; every entry point checks SKIMAGE_AVAILABLE first. numpy rides in as a
# scikit-image dependency, so it lives under the same guard.
try:
    import numpy as np
    from skimage.metrics import structural_similarity
    SKIMAGE_AVAILABLE = True
except ImportError:  # exercised on machines without `uv sync --extra vision`
    SKIMAGE_AVAILABLE = False

SCHEMA = "vision-metrics/1"
WIN_SIZE = 7            # SSIM sliding window (odd; on-scale with the 7px battle font)
WINDOW_PX = 16          # corroboration tile size, display px
MEAN_SSIM_FLOOR = 0.85  # advisory threshold — a parameter, NOT a verdict
SKIP_REASON = ("scikit-image not installed — opt in with `uv sync --extra vision` "
               "(or `pip install scikit-image`); this extra is quarantine-tier and never gates")

_TOOLS = Path(__file__).resolve().parent
ROOT = _TOOLS.parent
_spec = importlib.util.spec_from_file_location("visual_diff", _TOOLS / "visual_diff.py")
if _spec is None or _spec.loader is None:
    raise SystemExit("Cannot load the PNG decoder from tools/visual_diff.py")
visual_diff = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(visual_diff)


def _head_sha() -> str | None:
    try:
        proc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                              capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout.strip() or None if proc.returncode == 0 else None


def _grayscale(rgba: bytes, width: int, height: int):
    rgb = np.frombuffer(rgba, dtype=np.uint8).reshape(height, width, 4)[:, :, :3].astype(np.float64)
    return 0.2126 * rgb[:, :, 0] + 0.7152 * rgb[:, :, 1] + 0.0722 * rgb[:, :, 2]  # Rec.709


def compare_pair(shot: str, fresh: Path, baseline: Path) -> dict:
    """One pair → {"skipped": {shot, reason}} or {"findings": [...]}."""
    if fresh.read_bytes() == baseline.read_bytes():
        return {"skipped": {"shot": shot, "reason": "byte-identical pair"}}
    fw, fh, fbuf = visual_diff.decode_png_rgba(fresh)
    bw, bh, bbuf = visual_diff.decode_png_rgba(baseline)
    if (fw, fh) != (bw, bh):
        return {"skipped": {"shot": shot,
                            "reason": f"shape mismatch fresh {fw}x{fh} vs baseline {bw}x{bh}"}}
    smap = structural_similarity(_grayscale(fbuf, fw, fh), _grayscale(bbuf, bw, bh),
                                 full=True, win_size=WIN_SIZE, data_range=255)[1]
    findings = []
    for y in range(0, fh, WINDOW_PX):
        for x in range(0, fw, WINDOW_PX):
            tile = smap[y:y + WINDOW_PX, x:x + WINDOW_PX]
            mean = float(tile.mean())
            if mean < MEAN_SSIM_FLOOR:
                findings.append({"kind": "ssim_divergence", "shot": shot,
                                 "region": [x, y, int(tile.shape[1]), int(tile.shape[0])],
                                 "mean_ssim": round(mean, 4),
                                 "min_window_ssim": round(float(tile.min()), 4)})
    return {"findings": findings}


def run_metrics(shots_dir: Path, baseline_dir: Path) -> dict:
    """Compute the vision-metrics doc; never raises on per-pair decode failure."""
    doc: dict = {"schema": SCHEMA, "head_sha": _head_sha(),
                 "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if not SKIMAGE_AVAILABLE:
        doc.update({"skipped": True, "reason": SKIP_REASON, "findings": []})
        return doc
    doc.update({"parameters": {"win_size": WIN_SIZE, "window_px": WINDOW_PX,
                               "mean_ssim_floor": MEAN_SSIM_FLOOR},
                "pairs": 0, "skipped": [], "findings": []})
    if not shots_dir.is_dir() or not baseline_dir.is_dir():
        doc["skipped"].append({"shot": "*", "reason": "shots dir or baseline dir missing"})
        return doc
    for fresh in sorted(shots_dir.glob("*.png")):
        baseline = baseline_dir / fresh.name
        if not baseline.exists():
            continue  # unpaired shots are the region diff's concern, not this one's
        doc["pairs"] += 1
        try:
            result = compare_pair(fresh.stem, fresh, baseline)
        except Exception as exc:  # decode/shape failures degrade, never error the run
            doc["skipped"].append({"shot": fresh.stem, "reason": f"warn: {exc}"})
            continue
        if "skipped" in result:
            doc["skipped"].append(result["skipped"])
        else:
            doc["findings"].extend(result["findings"])
    return doc


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Optional SSIM-map corroboration — quarantine-tier, never a gate.")
    parser.add_argument("--shots-dir", default=".godot-smoke/shots")
    parser.add_argument("--baseline-dir", default="docs/generated/visual-baselines")
    parser.add_argument("--out", default=".godot-smoke/vision-metrics.json")
    args = parser.parse_args()
    doc = run_metrics(Path(args.shots_dir), Path(args.baseline_dir))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if not SKIMAGE_AVAILABLE:
        print(f"vision_metrics: skipped — {SKIP_REASON}")
    else:
        print(f"vision_metrics: {doc['pairs']} pair(s), {len(doc['findings'])} ssim_divergence "
              f"finding(s), {len(doc['skipped'])} skipped — advisory only, quarantine-tier, "
              "never a gate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
