#!/usr/bin/env python3
"""WCAG rendered-pixel contrast check (stdlib-only, vision-fidelity Slice 4).

Measures the contrast a label ACTUALLY has in a capture (not the design-time
color pair), so it CAN catch text-over-battle-effect contrast loss the static
checks miss when such a shot is captured: a translucent effect drawn over a
label changes the FRESH pixels only. (The fresh path today sees visual_sweep's
16 static states -- none mid-effect with an overlay over a label -- so that
case is a capability, not yet a captured frame.) It imports visual_diff's PNG
decoder via importlib (same pattern as visual_lint.py) and shares its ink
predicate (lum < 128).

WCAG relative luminance: linearize each sRGB channel
(cl = c/255; lin = cl/12.92 if cl <= 0.04045 else ((cl+0.055)/1.055)**2.4),
L = 0.2126*Rlin + 0.7152*Glin + 0.0722*Blin, ratio = (max(L)+0.05)/(min(L)+0.05).
Thresholds: 7px battle text is WCAG "normal" -> AA 4.5:1; 3:1 is kept as the
`large` parameter for any future >=18pt (or >=14pt bold) label.

DETERMINISTIC by construction (exit criterion 3): fg and bg are the
lower-median of the SORTED DISTINCT ink (lum<128) / fill (lum>=128) colors in
the rect. Sorting distinct colors and indexing the middle is a pure reduction
-- no RNG, no float-order dependence -- so identical input bytes yield
identical ratios, and Slice 2 proved the captures byte-identical across runs
(2/2 bit-identical sweeps) => zero run-to-run variance. Calibrated on the
committed battle baselines (09-12): each label is black 7px text on the
#f8f8f8 box fill with AA-fringe grays between; the median-distinct estimator
measures healthy labels at ratio 5.147..8.404 (recorded 09-12 evidence),
1.14x-1.87x headroom over the 4.5 bar, so a darkened fill or lightened ink
pulls the ratio toward 1.0 and trips it decisively. The fg is the lower-median
of the SORTED DISTINCT ink colors -- an AA-fringe gray, not the pure-black
core -- so the ratio UNDERSTATES true contrast (a black/#f8 pair is ~17:1);
the tightest label is '35' on 10_battle_moves at 5.147 (1.14x headroom). That
margin is comfortable while contrast_low is quarantine-tier; on promotion to
coded RED, re-measure the low-end headroom (or anchor fg to a low percentile
of ink luminance) and/or hold the thin-margin labels quarantine-tier.

Routing is the CALLER's decision, never this tool's: it emits kind=contrast_low
findings; the runner/report keeps them quarantine-tier until the determinism
proof + clean-run history graduate them to coded red (spec: "contrast_low coded
after the determinism proof"). CLI: --shots-dir D --out O walks PNGs against
their sibling .sidecar.json labels[].display_rect; --image P --rects J --out O
checks one image against an explicit rects JSON ([{"text","rect":[x,y,w,h]}]).
Exit 0 pass / 1 findings / 2 error, mirroring visual_lint.py.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys

_TOOLS = Path(__file__).resolve().parent
_DIFF_PATH = _TOOLS / "visual_diff.py"
_spec = importlib.util.spec_from_file_location("visual_diff", _DIFF_PATH)
if _spec is None or _spec.loader is None:
    raise SystemExit(f"Cannot load the PNG decoder from {_DIFF_PATH}")
visual_diff = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(visual_diff)

INK_LUMINANCE = 128  # shared with visual_lint.py's ink definition
NORMAL_NEED = 4.5  # WCAG AA, normal text (7px battle glyphs)
LARGE_NEED = 3.0  # WCAG AA, large text (>=18pt / >=14pt bold)
EXIT_PASS, EXIT_FINDINGS, EXIT_ERROR = 0, 1, 2


def _linearize(channel: int) -> float:
    cl = channel / 255.0
    return cl / 12.92 if cl <= 0.04045 else ((cl + 0.055) / 1.055) ** 2.4


def _relative_luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = (_linearize(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _clip(rect: list[int], width: int, height: int) -> tuple[int, int, int, int]:
    x0 = max(0, int(rect[0])); y0 = max(0, int(rect[1]))
    x1 = min(width, int(rect[0]) + int(rect[2])); y1 = min(height, int(rect[1]) + int(rect[3]))
    return x0, y0, max(0, x1 - x0), max(0, y1 - y0)


def _median_distinct(colors: list[tuple[int, int, int]]) -> tuple[int, int, int] | None:
    """Lower-median of the SORTED DISTINCT colors: a deterministic, fringe-
    tolerant representative of the cluster (no frequency weighting, no RNG)."""
    distinct = sorted(set(colors))
    if not distinct:
        return None
    return distinct[(len(distinct) - 1) // 2]


def contrast_ratio(pixels: bytes, width: int, height: int, rect: list[int],
                   large: bool = False) -> dict | None:
    """Pure function of the pixels in `rect`: {ratio, fg, bg, need} or None when
    the rect has no ink or no fill (nothing to compare). Deterministic."""
    x0, y0, w, h = _clip(rect, width, height)
    if w <= 0 or h <= 0:
        return None
    ink: list[tuple[int, int, int]] = []
    fill: list[tuple[int, int, int]] = []
    for y in range(y0, y0 + h):
        base = y * width
        for x in range(x0, x0 + w):
            i = (base + x) * 4
            color = (pixels[i], pixels[i + 1], pixels[i + 2])
            if (color[0] * 299 + color[1] * 587 + color[2] * 114) // 1000 < INK_LUMINANCE:
                ink.append(color)
            else:
                fill.append(color)
    fg = _median_distinct(ink)
    bg = _median_distinct(fill)
    if fg is None or bg is None:
        return None
    lfg = _relative_luminance(fg)
    lbg = _relative_luminance(bg)
    ratio = (max(lfg, lbg) + 0.05) / (min(lfg, lbg) + 0.05)
    # ratio is rounded for display only; the pass/fail decision in check_rects
    # uses the raw value so a true ratio in [need - 0.0005, need) cannot slip
    # through rounding.
    return {"ratio": round(ratio, 3), "fg": list(fg), "bg": list(bg),
            "need": LARGE_NEED if large else NORMAL_NEED, "_raw": ratio}


def check_rects(pixels: bytes, width: int, height: int, rects: list[dict],
                shot: str = "", large: bool = False) -> list[dict]:
    """contrast_low finding per modeled label rect whose ratio < need."""
    findings: list[dict] = []
    for entry in rects:
        rect = entry.get("rect")
        if not (isinstance(rect, list) and len(rect) == 4):
            continue
        measured = contrast_ratio(pixels, width, height, rect, large=large)
        if measured is None or measured.pop("_raw") >= measured["need"]:
            continue
        findings.append({"kind": "contrast_low", "shot": shot,
                         "label_text": str(entry.get("text", "")),
                         "rect": [int(v) for v in rect], **measured})
    return findings


def check_image(image_path: Path, rects: list[dict], large: bool = False) -> dict:
    width, height, pixels = visual_diff.decode_png_rgba(image_path)
    findings = check_rects(pixels, width, height, rects, shot=image_path.name, large=large)
    return {"ok": not findings, "findings": findings}


def label_rects_from_sidecar(sidecar: dict) -> list[dict]:
    """labels[].display_rect -> [{text, rect}] in the capture's pixel space."""
    rects: list[dict] = []
    for label in (sidecar or {}).get("labels", []) or []:
        rect = label.get("display_rect") if isinstance(label, dict) else None
        if isinstance(rect, list) and len(rect) == 4:
            rects.append({"text": str(label.get("text", "")), "rect": [int(v) for v in rect]})
    return rects


def run_contrast(images_dir: Path, large: bool = False) -> dict:
    """Walk PNGs with a sibling .sidecar.json; contrast-check each label rect.

    A PNG without a sidecar (or with no labels) is skipped, never an error --
    only battle shots carry labels (check_repo_contracts enforces that).
    """
    if not images_dir.is_dir():
        return {"ok": False, "errors": [f"images directory missing: {images_dir}"], "findings": []}
    findings: list[dict] = []
    checked = 0
    errors: list[str] = []
    for png in sorted(images_dir.glob("*.png")):
        sidecar_path = png.with_name(png.name + ".sidecar.json")
        if not sidecar_path.exists():
            continue
        try:
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            errors.append(f"{sidecar_path.name}: {exc}")
            continue
        rects = label_rects_from_sidecar(sidecar if isinstance(sidecar, dict) else {})
        if not rects:
            continue
        try:
            width, height, pixels = visual_diff.decode_png_rgba(png)
        except (visual_diff.PngError, OSError) as exc:
            errors.append(f"{png.name}: {exc}")
            continue
        checked += 1
        findings.extend(check_rects(pixels, width, height, rects, shot=png.name, large=large))
    return {"ok": not errors and not findings, "findings": findings,
            "images_checked": checked, "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots-dir", type=Path, help="dir of PNGs with sibling .sidecar.json")
    parser.add_argument("--image", type=Path, help="single PNG (with --rects)")
    parser.add_argument("--rects", type=Path, help='JSON: [{"text","rect":[x,y,w,h]}]')
    parser.add_argument("--large", action="store_true", help="use the 3:1 large-text threshold")
    parser.add_argument("--out", type=Path, required=True, help="verdict JSON output path")
    args = parser.parse_args()
    try:
        if args.image and args.rects:
            rects = json.loads(args.rects.read_text(encoding="utf-8"))
            result = check_image(args.image, rects, large=args.large)
            result["images_checked"] = 1
            result["errors"] = []
        elif args.shots_dir:
            result = run_contrast(args.shots_dir, large=args.large)
        else:
            print("error: pass --shots-dir, or --image with --rects", file=sys.stderr)
            return EXIT_ERROR
    except (OSError, ValueError, visual_diff.PngError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
    args.out.write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    if result["errors"]:
        return EXIT_ERROR
    return EXIT_PASS if result["ok"] else EXIT_FINDINGS


if __name__ == "__main__":
    sys.exit(main())
