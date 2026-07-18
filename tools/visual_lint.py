#!/usr/bin/env python3
"""Region-based visual lint for UI captures (Lane 2 pixel half).

Stdlib-only sibling of visual_diff.py (PNG decode shared via importlib, same
pattern as run_playtests.py). Driven by scripts/app/ui_render_audit.gd with a
JSON job describing expected ink regions (must be dark), forbidden zones
(must stay empty), and single text rows (must show a healthy one-row ink
profile). Ink = luminance < 128.

Thresholds, calibrated against the committed baselines
(docs/generated/visual-baselines/09/10/12, 1152x648 window captures with the
160x144 stage at ~4.278x) and stage-scale SubViewport captures (what
ui_render_audit feeds in): densities are scale-free ratios.
- baked/rendered text rows measure ink density 0.30..0.40, so ink_min 0.02
  only fires when expected text is essentially absent;
- inter-row/border strips measure 0.0 dark, so forbidden_max 0.01 is pure
  noise allowance;
- a healthy single text row measures band_height 7px stage (20..34px at
  4.278x) and densest-row share 0.44..0.69, so the job carries band_max
  (scenario-computed as 12px stage * capture scale) and density_max 0.85
  for exact-overlap superposition;
- mean band density of healthy rows measures 0.30..0.40 across all baselines
  (font glyph density is near-constant), while two rows superimposed with a
  2px-stage offset measure 0.51, so mean_density_max defaults to 0.45.

CLI: --image P --job J --out O. The verdict JSON ({"ok", "findings"}) is
written to O and printed to stdout; exit 1 when any finding exists,
2 on usage/decode errors. CI can run this without Godot.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys

_DIFF_PATH = Path(__file__).resolve().with_name("visual_diff.py")
_spec = importlib.util.spec_from_file_location("visual_diff", _DIFF_PATH)
if _spec is None or _spec.loader is None:
    raise SystemExit(f"Cannot load the PNG decoder from {_DIFF_PATH}")
visual_diff = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(visual_diff)

INK_LUMINANCE = 128
DEFAULT_INK_MIN = 0.02
DEFAULT_FORBIDDEN_MAX = 0.01
DEFAULT_DENSITY_MAX = 0.85
DEFAULT_MEAN_DENSITY_MAX = 0.45
EXIT_PASS = 0
EXIT_FINDINGS = 1
EXIT_ERROR = 2


def dark_mask(width: int, height: int, pixels: bytes) -> list[bool]:
    """One bool per pixel: True when luminance < INK_LUMINANCE."""
    mask = []
    for i in range(width * height):
        r = pixels[i * 4]
        g = pixels[i * 4 + 1]
        b = pixels[i * 4 + 2]
        mask.append((r * 299 + g * 587 + b * 114) // 1000 < INK_LUMINANCE)
    return mask


def _clip(rect: list[float], width: int, height: int) -> tuple[int, int, int, int]:
    x0 = max(0, int(rect[0]))
    y0 = max(0, int(rect[1]))
    x1 = min(width, int(rect[0] + rect[2]))
    y1 = min(height, int(rect[1] + rect[3]))
    return x0, y0, max(0, x1 - x0), max(0, y1 - y0)


def ink_density(mask: list[bool], width: int, rect: tuple[int, int, int, int]) -> float:
    """Share of dark pixels inside the (clipped) rect; 0.0 for empty rects."""
    x0, y0, w, h = rect
    if w <= 0 or h <= 0:
        return 0.0
    dark = 0
    for y in range(y0, y0 + h):
        base = y * width
        dark += sum(mask[base + x0 : base + x0 + w])
    return dark / float(w * h)


def text_row_profile(mask: list[bool], width: int, rect: tuple[int, int, int, int]) -> dict:
    """Ink band profile of a single text row: contiguous dark rows (height)
    and the densest row's dark share. Garbled (overlapping) rows show an
    over-tall band or an over-dense row."""
    x0, y0, w, h = rect
    if w <= 0 or h <= 0:
        return {"band_height": 0, "max_density": 0.0}
    per_row = []
    for y in range(y0, y0 + h):
        base = y * width
        per_row.append(sum(mask[base + x0 : base + x0 + w]))
    band_height = 0
    current = 0
    for count in per_row:
        current = current + 1 if count > 0 else 0
        band_height = max(band_height, current)
    return {"band_height": band_height, "max_density": max(per_row) / float(w)}


def run_lint(image_path: Path, job: dict) -> dict:
    width, height, pixels = visual_diff.decode_png_rgba(image_path)
    mask = dark_mask(width, height, pixels)
    ink_min = float(job.get("ink_min", DEFAULT_INK_MIN))
    forbidden_max = float(job.get("forbidden_max", DEFAULT_FORBIDDEN_MAX))
    findings: list[dict] = []
    for region in job.get("ink_regions", []):
        density = ink_density(mask, width, _clip(region, width, height))
        if density < ink_min:
            findings.append({"kind": "low_ink", "region": region, "density": round(density, 4)})
    for region in job.get("forbidden_zones", []):
        density = ink_density(mask, width, _clip(region, width, height))
        if density > forbidden_max:
            findings.append({"kind": "forbidden_ink", "region": region, "density": round(density, 4)})
    for region in job.get("text_rows", []):
        clipped = _clip(region, width, height)
        profile = text_row_profile(mask, width, clipped)
        if profile["band_height"] == 0:
            findings.append({"kind": "low_ink", "region": region, "density": 0.0})
            continue
        band_max = job.get("band_max")
        density_max = float(job.get("density_max", DEFAULT_DENSITY_MAX))
        mean_density = ink_density(mask, width, clipped)
        mean_max = float(job.get("mean_density_max", DEFAULT_MEAN_DENSITY_MAX))
        over_band = band_max is not None and profile["band_height"] > float(band_max)
        if over_band or profile["max_density"] >= density_max or mean_density >= mean_max:
            findings.append({"kind": "garble", "region": region,
                             "band_height": profile["band_height"],
                             "max_density": round(profile["max_density"], 4),
                             "mean_density": round(mean_density, 4)})
    return {"ok": not findings, "findings": findings}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True, help="capture PNG to lint")
    parser.add_argument("--job", type=Path, required=True, help="JSON job: ink_regions/forbidden_zones/text_rows + thresholds")
    parser.add_argument("--out", type=Path, required=True, help="verdict JSON output path")
    args = parser.parse_args()

    try:
        job = json.loads(args.job.read_text(encoding="utf-8"))
        verdict = run_lint(args.image, job)
    except (OSError, json.JSONDecodeError, visual_diff.PngError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
    args.out.write_text(json.dumps(verdict, sort_keys=True), encoding="utf-8")
    print(json.dumps(verdict, sort_keys=True))
    return EXIT_PASS if verdict["ok"] else EXIT_FINDINGS


if __name__ == "__main__":
    sys.exit(main())
