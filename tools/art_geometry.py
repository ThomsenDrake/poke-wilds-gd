#!/usr/bin/env python3
"""Art-anchor geometry: source-art-truth rects for programmatic-on-baked elements.

The anchor registry (docs/registry/art-anchors.toml) records, for every
programmatic node overlaid on baked GSC art, the rect where the art FEATURE it
belongs to lives -- in the 160x144 STAGE-px space (the SAME space as sidecar
draw_order rects, so live-respect compares stage-to-stage with NO stage->display
mapping -- immune to the duplicated-mapper 11px re-entry risk).

Truth here is a pure integer function of the art BYTES (read through the suite's
own stdlib decoder visual_diff.decode_png_rgba via the sanctioned importlib load)
plus pinned per-art calibration params -- never the code under test (scene
offsets, layout constants, baselines, or a human transcription). That is the
inversion the 11px HP-bar escape demanded: pixel baselines and sidecar diffs are
CHANGE DETECTORS and are structurally disqualified from being the art-fidelity
authority. A fresh checkout with zero baselines still yields the same rects.

Derivation methods (pinned params live in the registry entry, not here):
  dark-run     per scan-row maximal runs of lum<lum_max with length>=min_run;
               bbox across the pinned row_ys. Verified to reproduce the fixed HP
               tracks (32,18,48,4)/(96,74,48,4) from battle_screen2.png and to
               EXCLUDE the misaligned 43/107 positions.
  dark-cluster connected dark components (lum<lum_max, area>=min_area) within a
               pinned search window [x0,y0,x1,y1]; bbox of the union.
  attested     human feature choice (no auto-derivation); the pin is art_sha256
               + attestation block. The freshness gate still asserts the sha.

Stdlib-only CORE tool (tomllib + the importlib-loaded decoder). It never gates CI
on its own: art_anchor_issues() in tools/check_art_anchors.py folds into
check_repo_contracts.run() as the RED static half, and live-respect rides the
runner's baseline-regeneration refusal gate (tools/run_playtests.py
apply_anchor_gate). The __main__ selftest re-derives the two HP tracks from the
committed art bytes and asserts the exact rects -- the proof that the oracle is a
function of art the code under test cannot influence.
"""

from __future__ import annotations

import hashlib
import importlib.util
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_RELPATH = "docs/registry/art-anchors.toml"
STAGE_W, STAGE_H = 160, 144

# Derivation methods that recompute a rect from the art bytes (the freshness
# gate recomputes and asserts equality). `attested` has no recompute -- its pin
# is the art sha + the attestation block + reverify_by cadence.
RECOMPUTABLE = ("dark-run", "dark-cluster")
KNOWN_DERIVATIONS = ("dark-run", "dark-cluster", "template", "attested")
KNOWN_ELEMENT_KINDS = (
    "bar-track", "bar-fill", "number-plate", "glyph-cover",
    "status-tag", "name-level-plate", "cursor-row", "box-interior",
)

_DECODER = None


def _decoder():
    """Sanctioned importlib load of the suite's stdlib PNG decoder (the same
    pattern contrast_check.py / determinism_verify.py use) -- single decoder
    home, never re-implemented here."""
    global _DECODER
    if _DECODER is None:
        path = Path(__file__).resolve().with_name("visual_diff.py")
        spec = importlib.util.spec_from_file_location("visual_diff", path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load the PNG decoder from {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _DECODER = module
    return _DECODER


def sha256_hex(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_registry(root: Path = ROOT) -> list[dict]:
    """Parse docs/registry/art-anchors.toml -> list of [[anchors]] dicts.
    Absent registry = [] (the completeness gate arms only once >=1 anchor
    exists, mirroring region_coverage_issues' have_any_sidecar)."""
    path = Path(root) / REGISTRY_RELPATH
    if not path.exists():
        return []
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    anchors = data.get("anchors")
    return [a for a in anchors if isinstance(a, dict)] if isinstance(anchors, list) else []


def load_scenes(root: Path = ROOT) -> list[dict]:
    """Parse the [[scenes]] overlay-inventory declarations (the mechanical
    completeness scan's scope)."""
    path = Path(root) / REGISTRY_RELPATH
    if not path.exists():
        return []
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    scenes = data.get("scenes")
    return [s for s in scenes if isinstance(s, dict)] if isinstance(scenes, list) else []


def _lum(px: bytes, idx: int) -> int:
    """BT.601 luma of the RGBA pixel at byte index idx."""
    return (px[idx] * 299 + px[idx + 1] * 587 + px[idx + 2] * 114) // 1000


def _dark_runs_row(px: bytes, width: int, y: int, lum_max: int, min_run: int) -> list[tuple[int, int]]:
    """Maximal runs of lum<lum_max on scan-row y with length>=min_run -> [(x0, length)]."""
    runs: list[tuple[int, int]] = []
    x = 0
    while x < width:
        if _lum(px, (y * width + x) * 4) < lum_max:
            start = x
            while x < width and _lum(px, (y * width + x) * 4) < lum_max:
                x += 1
            if x - start >= min_run:
                runs.append((start, x - start))
        else:
            x += 1
    return runs


def dark_run_rect(px: bytes, width: int, height: int, params: dict) -> list[int] | None:
    """bbox across the pinned row_ys of the dark runs. Pure integer fn of bytes."""
    lum_max = int(params.get("lum_max", 95))
    min_run = int(params.get("min_run", 20))
    row_ys = [int(y) for y in params.get("row_ys", [])]
    if not row_ys:
        return None
    xs0: list[int] = []
    xs1: list[int] = []
    for y in row_ys:
        if not (0 <= y < height):
            return None
        for start, length in _dark_runs_row(px, width, y, lum_max, min_run):
            xs0.append(start)
            xs1.append(start + length)
    if not xs0:
        return None
    x0, x1 = min(xs0), max(xs1)
    y0, y1 = min(row_ys), max(row_ys)
    return [x0, y0, x1 - x0, y1 - y0 + 1]


def dark_cluster_rect(px: bytes, width: int, height: int, params: dict) -> list[int] | None:
    """bbox of the union of connected dark components (4-neighbour flood fill,
    lum<lum_max, area>=min_area) inside the pinned search window [x0,y0,x1,y1].
    Stdlib-only; the search window bounds the O(area) fill."""
    lum_max = int(params.get("lum_max", 95))
    min_area = int(params.get("min_area", 4))
    search = params.get("search")
    if not (isinstance(search, list) and len(search) == 4):
        return None
    sx0, sy0, sx1, sy1 = (int(v) for v in search)
    sx0, sy0 = max(0, sx0), max(0, sy0)
    sx1, sy1 = min(width, sx1), min(height, sy1)
    seen = bytearray((sx1 - sx0) * (sy1 - sy0))
    w_span = sx1 - sx0
    minx = miny = None
    maxx = maxy = None
    for sy in range(sy0, sy1):
        for sx in range(sx0, sx1):
            li = (sy - sy0) * w_span + (sx - sx0)
            if seen[li] or _lum(px, (sy * width + sx) * 4) >= lum_max:
                continue
            # flood fill this component
            stack = [(sx, sy)]
            area = 0
            comp_minx = comp_miny = 10 ** 9
            comp_maxx = comp_maxy = -1
            while stack:
                cx, cy = stack.pop()
                ci = (cy - sy0) * w_span + (cx - sx0)
                if seen[ci]:
                    continue
                if not (sx0 <= cx < sx1 and sy0 <= cy < sy1):
                    continue
                if _lum(px, (cy * width + cx) * 4) >= lum_max:
                    continue
                seen[ci] = 1
                area += 1
                comp_minx = min(comp_minx, cx)
                comp_miny = min(comp_miny, cy)
                comp_maxx = max(comp_maxx, cx)
                comp_maxy = max(comp_maxy, cy)
                stack.extend(((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)))
            if area >= min_area:
                minx = comp_minx if minx is None else min(minx, comp_minx)
                miny = comp_miny if miny is None else min(miny, comp_miny)
                maxx = comp_maxx if maxx is None else max(maxx, comp_maxx)
                maxy = comp_maxy if maxy is None else max(maxy, comp_maxy)
    if minx is None:
        return None
    return [minx, miny, maxx - minx + 1, maxy - miny + 1]


def derive_rect(art_path: Path, anchor: dict) -> list[int] | None:
    """Recompute an anchor's stage_rect from the CURRENT art bytes. Returns None
    for `attested` (no recompute) or when detection fails. Pure fn of bytes +
    pinned params."""
    method = anchor.get("derivation")
    if method not in RECOMPUTABLE:
        return None
    vd = _decoder()
    width, height, px = vd.decode_png_rgba(Path(art_path))
    params = anchor.get("derivation_params") or {}
    if method == "dark-run":
        return dark_run_rect(px, width, height, params)
    if method == "dark-cluster":
        return dark_cluster_rect(px, width, height, params)
    return None


def rects_close(a: list[int], b: list[int], tol: int) -> bool:
    """Two [x,y,w,h] rects agree within tol px on every edge."""
    if not (isinstance(a, list) and isinstance(b, list) and len(a) == 4 and len(b) == 4):
        return False
    return all(abs(int(a[i]) - int(b[i])) <= tol for i in range(4))


def art_path(root: Path, anchor: dict) -> Path:
    return Path(root) / str(anchor.get("source_art", ""))


# --------------------------------------------------------------------------
# scene overlay inventory (mechanical completeness scan)
# --------------------------------------------------------------------------
def parse_tscn_nodes(scene_path: Path) -> list[dict]:
    """Parse a .tscn into [{name, type, parent}] for every [node ...] block.
    `parent` is the raw parent= value ('.' for root-direct children; absent for
    the scene root)."""
    import re
    nodes: list[dict] = []
    node_re = re.compile(r'^\[node\s+name="(?P<name>[^"]+)"\s+type="(?P<type>[^"]+)"(?:\s+parent="(?P<parent>[^"]*)")?\]')
    for line in Path(scene_path).read_text(encoding="utf-8").splitlines():
        m = node_re.match(line.strip())
        if m:
            nodes.append({"name": m.group("name"), "type": m.group("type"),
                          "parent": m.group("parent")})
    return nodes


def node_relpath(node: dict) -> str | None:
    """Path of a node relative to the scene root node (root excluded).
    parent='.' -> the node is a direct child of root -> relpath == name.
    Returns None for the scene root (no parent key)."""
    parent = node.get("parent")
    if parent is None:
        return None  # scene root
    if parent == ".":
        return node["name"]
    return f"{parent}/{node['name']}"


def overlay_inventory(scene_path: Path, stage: str, overlay_types: list[str]) -> list[str]:
    """Stage-relative paths of every overlay-typed node living under `stage`.
    Mechanical: a node ADDED to a declared art scene appears here automatically,
    so an un-anchored future overlay is caught without anyone naming it."""
    kinds = set(overlay_types)
    prefix = stage.rstrip("/") + "/"
    out: list[str] = []
    for node in parse_tscn_nodes(scene_path):
        rel = node_relpath(node)
        if rel is None or node["type"] not in kinds:
            continue
        if rel.startswith(prefix):
            out.append(rel[len(prefix):])
    return sorted(out)


# --------------------------------------------------------------------------
# selftest: the oracle is a function of art the code cannot influence
# --------------------------------------------------------------------------
def _selftest() -> int:
    registry = load_registry(ROOT)
    hp = {a["id"]: a for a in registry if a.get("id", "").endswith("hp_track")}
    if len(hp) < 2:
        print("selftest: expected the two HP-track anchors in the registry")
        return 1
    failures = 0
    for aid, anchor in sorted(hp.items()):
        path = art_path(ROOT, anchor)
        if not path.exists():
            print(f"selftest: {aid}: source art missing: {path}")
            failures += 1
            continue
        derived = derive_rect(path, anchor)
        expected = anchor.get("stage_rect")
        ok = derived == expected
        print(f"selftest: {aid}: derive -> {derived} (registry {expected}) {'OK' if ok else 'MISMATCH'}")
        if not ok:
            failures += 1
    # the misaligned (pre-fix) positions must be EXCLUDED by the detector
    enemy = hp.get("battle/enemy_hp_track", {})
    derived = derive_rect(art_path(ROOT, enemy), enemy) if enemy else None
    if derived is not None and (derived[0] == 43 or derived == [43, 18, 48, 4]):
        print("selftest: detector reproduced the WRONG (misaligned 43) enemy track")
        failures += 1
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    import sys
    sys.exit(_selftest())
