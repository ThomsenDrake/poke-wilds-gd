#!/usr/bin/env python3
"""Color-vision-deficiency simulation (stdlib-only, vision-fidelity Slice 4).

Simulates the HP-bar and canary palettes under protanopia, deuteranopia
and tritanopia and reports color pairs that COLLAPSE -- distinguishable in
normal vision but indistinguishable under a deficiency. Findings are kind
cvd_collapse and are QUARANTINE-FOREVER: accessibility EVIDENCE for a human,
never a red gate, never self-graduating (no finding can turn the suite red;
a tool ERROR still fails red, fail-closed like every other gate).

MATRICES — severity 1.0 (full dichromacy, the worst-case accessibility bound),
linear-sRGB, from the paper's published values:

  Machado, Oliveira & Fernandes, "A Physiologically-based Model for Simulation
  of Color Vision Deficiency," IEEE Transactions on Visualization and Computer
  Graphics 15(6), 2009, DOI 10.1109/TVCG.2009.113.

The verbatim severity ladder (0.0-1.0) these 1.0 rows are drawn from is
tabulated in Machado's 2010 thesis (G. M. Machado, "Um modelo fisiologicamente
baseado para a simulação de deficiências de visão de cores," UFRGS, LUME
repository handle 10183/26950) and is cross-checked against colour-science's
dataset and colorspacious ([MOF09]). NOT the Lokno gist the plan rejects. Rows
sum to 1.0 (white preservation) -- asserted at import as a tamper check.

COLLAPSE metric: CIE76 deltaE in CIELAB (the hue-aware difference WCAG luminance
ratio cannot see -- green and red have near-identical luminance). A pair
collapses under a deficiency when its original deltaE >= DELTA_E_THRESHOLD
(meant to be distinguishable) but its simulated deltaE < DELTA_E_THRESHOLD.
Calibrated on the HP-bar triple: green/red original deltaE 109.2 collapses to
8.1 under deutan (recorded evidence), while protan (34.3) and tritan (118.7)
stay above the 10.0 threshold, so 10.0 cleanly captures the classic hazard.

CLI: --shots-dir D --out O pulls palettes.canary from each sibling sidecar and
adds the hardcoded HP-bar triple; --palettes J --out O checks an explicit
{[[a,b],...]} pair list. Exit 0 no collapse / 1 collapses found / 2 error.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

# Severity 1.0 Machado-Oliveira-Fernandes 2009 matrices (see module docstring).
MACHADO_1_0 = {
    "protan": [
        [0.152286, 1.052583, -0.204868],
        [0.114503, 0.786281, 0.099216],
        [-0.003882, -0.048116, 1.051998],
    ],
    "deutan": [
        [0.367322, 0.860646, -0.227968],
        [0.280085, 0.672501, 0.047413],
        [-0.011820, 0.042940, 0.968881],
    ],
    "tritan": [
        [1.255528, -0.076749, -0.178779],
        [-0.078411, 0.930809, 0.147602],
        [0.004733, 0.691367, 0.303900],
    ],
}
DELTA_E_THRESHOLD = 10.0  # CIE76 "clearly distinguishable" boundary (calibrated)
# HP-bar fill triple, verbatim from scripts/ui/battle_surface.gd _set_hp_bar.
HP_BAR = {"green": "#3aa63f", "yellow": "#edba1e", "red": "#d03d34"}
EXIT_PASS, EXIT_FINDINGS, EXIT_ERROR = 0, 1, 2


def _white_preservation() -> None:
    """Tamper check: every matrix maps white to white (rows sum to 1.0)."""
    for name, matrix in MACHADO_1_0.items():
        for row_index, row in enumerate(matrix):
            if abs(sum(row) - 1.0) > 1e-3:
                raise ValueError(f"Machado {name} row {row_index} does not sum to 1.0: {row}")


_white_preservation()


def _hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def _srgb_to_linear(channel: int) -> float:
    c = channel / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(channel: float) -> int:
    c = max(0.0, min(1.0, channel))
    return round(255 * (c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055))


def simulate(value: str, deficiency: str) -> str:
    """Map an sRGB hex color through the deficiency matrix (linear domain)."""
    matrix = MACHADO_1_0[deficiency]
    linear = [_srgb_to_linear(c) for c in _hex_to_rgb(value)]
    out = [sum(matrix[r][c] * linear[c] for c in range(3)) for r in range(3)]
    r, g, b = (_linear_to_srgb(v) for v in out)
    return f"#{r:02x}{g:02x}{b:02x}"


def _lab(value: str) -> tuple[float, float, float]:
    """sRGB hex -> CIELAB (D65) via linear-sRGB -> XYZ."""
    r, g, b = (_srgb_to_linear(c) for c in _hex_to_rgb(value))
    x = 0.4124 * r + 0.3576 * g + 0.1805 * b
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = 0.0193 * r + 0.1192 * g + 0.9505 * b
    xn, yn, zn = 0.95047, 1.0, 1.08883

    def f(t: float) -> float:
        return t ** (1 / 3) if t > (6 / 29) ** 3 else t / (3 * (6 / 29) ** 2) + 4 / 29

    fx, fy, fz = f(x / xn), f(y / yn), f(z / zn)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e76(value_a: str, value_b: str) -> float:
    """CIE76 color difference (Euclidean distance in CIELAB)."""
    lab_a, lab_b = _lab(value_a), _lab(value_b)
    return sum((u - v) ** 2 for u, v in zip(lab_a, lab_b)) ** 0.5


def check_pairs(pairs: list[list[str]], source: str = "") -> list[dict]:
    """cvd_collapse per (deficiency, pair) whose simulated deltaE drops below the
    threshold from an originally-distinguishable (>= threshold) deltaE."""
    findings: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    for pair in pairs:
        if not (isinstance(pair, (list, tuple)) and len(pair) == 2):
            continue
        color_a, color_b = str(pair[0]).lower(), str(pair[1]).lower()
        if color_a == color_b:
            continue
        original = delta_e76(color_a, color_b)
        if original < DELTA_E_THRESHOLD:
            continue  # not meant to be distinguishable; cannot "collapse"
        for deficiency in MACHADO_1_0:
            key = (deficiency, color_a, color_b)
            if key in seen:
                continue
            seen.add(key)
            simulated = delta_e76(simulate(color_a, deficiency), simulate(color_b, deficiency))
            if simulated < DELTA_E_THRESHOLD:
                findings.append({"kind": "cvd_collapse", "deficiency": deficiency,
                                 "pair": [color_a, color_b], "source": source,
                                 "original_delta_e": round(original, 2),
                                 "simulated_delta_e": round(simulated, 2),
                                 "threshold": DELTA_E_THRESHOLD})
    findings.sort(key=lambda f: (f["source"], f["deficiency"], f["pair"]))
    return findings


def hp_bar_pairs() -> list[list[str]]:
    """All unordered pairs of the HP-bar triple (green/yellow/red)."""
    colors = list(HP_BAR.values())
    return [[colors[i], colors[j]] for i in range(len(colors)) for j in range(i + 1, len(colors))]


def canary_pairs(sidecar: dict) -> list[list[str]]:
    """Distinct-color pairs from a sidecar's palettes.canary. Grays self-filter:
    a gray (R==G==B) is fixed by the white-preserving matrix, so gray/gray pairs
    keep their deltaE and never trip the collapse test; only chromatic pairs can."""
    colors = sorted({str(c).lower() for c in (sidecar or {}).get("palettes", {}).get("canary", []) or []})
    return [[colors[i], colors[j]] for i in range(len(colors)) for j in range(i + 1, len(colors))]


def run_cvd(images_dir: Path) -> dict:
    """HP-bar triple + each sidecar's canary palette, all three deficiencies."""
    findings = check_pairs(hp_bar_pairs(), source="hp_bar")
    errors: list[str] = []
    palettes_checked = 1  # the hardcoded HP-bar triple always runs
    if images_dir is not None and images_dir.is_dir():
        for sidecar_path in sorted(images_dir.glob("*.png.sidecar.json")):
            try:
                sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                errors.append(f"{sidecar_path.name}: {exc}")
                continue
            pairs = canary_pairs(sidecar if isinstance(sidecar, dict) else {})
            if pairs:
                palettes_checked += 1
                findings.extend(check_pairs(pairs, source=sidecar_path.name.removesuffix(".sidecar.json")))
    return {"ok": not errors, "findings": findings,
            "palettes_checked": palettes_checked, "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots-dir", type=Path, help="dir of PNGs with sibling .sidecar.json")
    parser.add_argument("--palettes", type=Path, help='JSON pair list: [["#a","#b"],...]')
    parser.add_argument("--out", type=Path, required=True, help="verdict JSON output path")
    args = parser.parse_args()
    try:
        if args.palettes:
            pairs = json.loads(args.palettes.read_text(encoding="utf-8"))
            result = {"ok": True, "findings": check_pairs(pairs, source=args.palettes.name),
                      "palettes_checked": 1, "errors": []}
        else:
            result = run_cvd(args.shots_dir)
    except (OSError, ValueError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR
    args.out.write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    if result["errors"]:
        return EXIT_ERROR
    return EXIT_PASS if not result["findings"] else EXIT_FINDINGS


if __name__ == "__main__":
    sys.exit(main())
