#!/usr/bin/env python3
"""Verify-first aid for the Slice 2 determinism pins (stdlib-only).

Subcommands:
  pins [--project project.godot]   assert the ADOPTED pins ([rendering]
      2d/snap/snap_2d_transforms_to_pixel=true, anti_aliasing/quality/msaa_2d=0)
      are present, and the REJECTED candidate pins (default_texture_filter;
      any [display] stretch section) are absent.
  cmp --a DIR --b DIR              byte-compare every PNG across two shot dirs
      (e.g. two consecutive sweeps, or shots vs committed baselines).
  canary --shot P [--x --y --w --h --k]
      DECIDUEYE-canary block uniformity: every kxk block uniform, and every
      horizontal color transition aligned to the k-grid (0 off-grid). Defaults
      are the canonical 1152x648 battle shots' canary rect (640,68,224,224) at
      integer scale 4 -- see docs/product-specs/vision-fidelity.md.

Any future rendering/display pin change must re-run this gate BEFORE new
baselines are committed (verify-first discipline: measured evidence, never
assumed). verify_all.py absorbs these checks when it lands. Reuses
tools/visual_diff.py's stdlib PNG decoder so numbers share one implementation.
Exit: 0 pass, 1 verify failure, 2 usage/decode error.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ADOPTED_PINS = {
    "2d/snap/snap_2d_transforms_to_pixel": "true",
    "anti_aliasing/quality/msaa_2d": "0",
}
REJECTED_RENDERING_KEYS = ("textures/canvas_textures/default_texture_filter",)
REJECTED_SECTIONS = ("display",)  # stretch pins; the section itself is the breakpoint
EXIT_PASS, EXIT_FAIL, EXIT_ERROR = 0, 1, 2


def _load_visual_diff():
    spec = importlib.util.spec_from_file_location("visual_diff", ROOT / "tools" / "visual_diff.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_project_settings(path: Path) -> dict[str, dict[str, str]]:
    """section -> {key: value} for the .godot ini format (no multiline values)."""
    sections: dict[str, dict[str, str]] = {}
    section = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(";"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            sections.setdefault(section, {})
        elif "=" in stripped:
            key, value = stripped.split("=", 1)
            sections.setdefault(section, {})[key.strip()] = value.strip()
    return sections


def cmd_pins(project_file: Path) -> tuple[dict, int]:
    try:
        sections = parse_project_settings(project_file)
    except OSError as exc:
        return {"ok": False, "errors": [f"cannot read {project_file}: {exc}"]}, EXIT_ERROR
    rendering = sections.get("rendering", {})
    issues = []
    for key, expected in ADOPTED_PINS.items():
        if rendering.get(key) != expected:
            issues.append(f"[rendering] {key}: expected {expected}, found {rendering.get(key)!r}")
    for key in REJECTED_RENDERING_KEYS:
        if key in rendering:
            issues.append(f"[rendering] {key}={rendering[key]} is a REJECTED candidate pin; "
                          "re-run the verify-first gate before keeping it")
    for section in REJECTED_SECTIONS:
        if section in sections:
            issues.append(f"[{section}] section present: stretch pins were REJECTED (adding the "
                          "section changes get_viewport_rect() semantics under battle_view.gd's "
                          "manual integer scale); re-run the verify-first gate")
    return {"ok": not issues, "adopted": ADOPTED_PINS, "issues": issues}, (
        EXIT_PASS if not issues else EXIT_FAIL)


def cmd_cmp(dir_a: Path, dir_b: Path) -> tuple[dict, int]:
    for directory in (dir_a, dir_b):
        if not directory.is_dir():
            return {"ok": False, "errors": [f"not a directory: {directory}"]}, EXIT_ERROR
    names_b = {p.name for p in dir_b.glob("*.png")}
    files = {}
    for path in sorted(dir_a.glob("*.png")):
        if path.name not in names_b:
            files[path.name] = "missing-in-b"
        elif path.read_bytes() == (dir_b / path.name).read_bytes():
            files[path.name] = "identical"
        else:
            files[path.name] = "differ"
    only_b = sorted(names_b - set(files))
    differing = sorted(name for name, verdict in files.items() if verdict != "identical")
    ok = bool(files) and not differing and not only_b
    return {"ok": ok, "compared": len(files), "differing": differing, "only_in_b": only_b}, (
        EXIT_PASS if ok else EXIT_FAIL)


def cmd_canary(vd, shot: Path, x: int, y: int, w: int, h: int, k: int) -> tuple[dict, int]:
    try:
        width, height, buf = vd.decode_png_rgba(shot)
    except (vd.PngError, OSError) as exc:
        return {"ok": False, "errors": [str(exc)]}, EXIT_ERROR
    if x + w > width or y + h > height or w % k or h % k:
        return {"ok": False, "errors": [
            f"rect ({x},{y},{w},{h}) invalid for {width}x{height} at k={k}"]}, EXIT_ERROR
    blocks_total = blocks_uniform = transitions = off_grid = 0
    for bj in range(h // k):
        for bi in range(w // k):
            x0, y0 = x + bi * k, y + bj * k
            ref = buf[(y0 * width + x0) * 4:(y0 * width + x0) * 4 + 4]
            uniform = True
            for j in range(k):
                row = ((y0 + j) * width + x0) * 4
                for i in range(k):
                    if buf[row + i * 4:row + i * 4 + 4] != ref:
                        uniform = False
                        break
                if not uniform:
                    break
            blocks_total += 1
            blocks_uniform += 1 if uniform else 0
    for j in range(h):
        row = ((y + j) * width + x) * 4
        for i in range(w - 1):
            offset = row + i * 4
            if buf[offset:offset + 4] != buf[offset + 4:offset + 8]:
                transitions += 1
                if (i + 1) % k:
                    off_grid += 1
    result = {
        "ok": blocks_uniform == blocks_total and off_grid == 0,
        "shot": shot.name, "rect": [x, y, w, h], "k": k, "image_size": [width, height],
        "blocks_total": blocks_total, "blocks_uniform": blocks_uniform,
        "pct_uniform": round(blocks_uniform * 100.0 / blocks_total, 4) if blocks_total else 0.0,
        "x_transitions": transitions, "off_grid_transitions": off_grid,
    }
    return result, (EXIT_PASS if result["ok"] else EXIT_FAIL)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_pins = sub.add_parser("pins", help="assert adopted determinism pins in project.godot")
    p_pins.add_argument("--project", type=Path, default=ROOT / "project.godot")
    p_cmp = sub.add_parser("cmp", help="byte-compare two shot directories")
    p_cmp.add_argument("--a", required=True, type=Path)
    p_cmp.add_argument("--b", required=True, type=Path)
    p_canary = sub.add_parser("canary", help="DECIDUEYE-canary block uniformity of one shot")
    p_canary.add_argument("--shot", required=True, type=Path)
    p_canary.add_argument("--x", type=int, default=640)
    p_canary.add_argument("--y", type=int, default=68)
    p_canary.add_argument("--w", type=int, default=224)
    p_canary.add_argument("--h", type=int, default=224)
    p_canary.add_argument("--k", type=int, default=4)
    args = parser.parse_args()
    if args.cmd == "pins":
        result, code = cmd_pins(args.project)
    elif args.cmd == "cmp":
        result, code = cmd_cmp(args.a, args.b)
    else:
        result, code = cmd_canary(_load_visual_diff(), args.shot,
                                  args.x, args.y, args.w, args.h, args.k)
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
