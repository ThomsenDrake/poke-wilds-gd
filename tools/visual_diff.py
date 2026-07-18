#!/usr/bin/env python3
"""Diff visual-sweep captures against committed baselines.

Compares every PNG in --shots-dir with the same-named PNG in --baseline-dir
(docs/generated/visual-baselines). PNGs are decoded with zlib+struct only
(8-bit RGB/RGBA, non-interlaced); a pixel counts as changed when any channel
moves by more than --tolerance (0-255, default 8). A shot fails when its
changed-pixel share exceeds --threshold-pct (default 0.5%). Byte-identical
files short-circuit the decode, so clean runs cost a memcmp per shot.

Stdout carries a single JSON verdict consumed by
scripts/app/visual_sweep_baselines.gd; human-readable lines go to stderr.
Exit 0 = all shots within threshold, 1 = drift or missing files,
2 = usage/decode error. CI can run this without Godot.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"
DEFAULT_THRESHOLD_PCT = 0.5
DEFAULT_TOLERANCE = 8
EXIT_PASS = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2


class PngError(ValueError):
    """Raised when a PNG cannot be decoded by the stdlib-only reader."""


def read_png_header(path: Path) -> tuple[int, int, int]:
    """Cheap IHDR-only read: (width, height, bytes-per-pixel)."""
    with path.open("rb") as handle:
        head = handle.read(33)
    if len(head) < 33 or head[:8] != PNG_SIG or head[12:16] != b"IHDR":
        raise PngError(f"{path.name}: not a PNG file")
    width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
        ">IIBBBBB", head[16:29]
    )
    _validate_format(path.name, bit_depth, color_type, interlace)
    return width, height, 3 if color_type == 2 else 4


def decode_png_rgba(path: Path) -> tuple[int, int, bytes]:
    """Full decode to an RGBA8 buffer; raises PngError on anything exotic."""
    data = path.read_bytes()
    if data[:8] != PNG_SIG:
        raise PngError(f"{path.name}: not a PNG file")
    width = height = 0
    bit_depth = color_type = interlace = -1
    idat = bytearray()
    offset = 8
    while offset + 8 <= len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        chunk_type = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif chunk_type == b"IDAT":
            idat += body
        elif chunk_type == b"IEND":
            break
    if not width or not height:
        raise PngError(f"{path.name}: missing IHDR")
    _validate_format(path.name, bit_depth, color_type, interlace)
    bpp = 3 if color_type == 2 else 4
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise PngError(f"{path.name}: corrupt IDAT stream ({exc})") from exc
    pixels = _unfilter(path.name, raw, width, height, bpp)
    if bpp == 4:
        return width, height, pixels
    rgba = bytearray(width * height * 4)
    rgba[0::4] = pixels[0::3]
    rgba[1::4] = pixels[1::3]
    rgba[2::4] = pixels[2::3]
    rgba[3::4] = b"\xff" * (width * height)
    return width, height, bytes(rgba)


def _validate_format(name: str, bit_depth: int, color_type: int, interlace: int) -> None:
    if bit_depth != 8:
        raise PngError(f"{name}: unsupported bit depth {bit_depth} (need 8)")
    if color_type not in (2, 6):
        raise PngError(f"{name}: unsupported color type {color_type} (need RGB/RGBA)")
    if interlace != 0:
        raise PngError(f"{name}: interlaced PNGs are not supported")


def _unfilter(name: str, raw: bytes, width: int, height: int, bpp: int) -> bytes:
    stride = width * bpp
    if len(raw) < (stride + 1) * height:
        raise PngError(f"{name}: truncated image data")
    out = bytearray(height * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos : pos + stride])
        pos += stride
        if filter_type == 1:  # Sub
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa = abs(p - a)
                pb = abs(p - b)
                pc = abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 0xFF
        elif filter_type != 0:
            raise PngError(f"{name}: unknown scanline filter {filter_type}")
        out[y * stride : (y + 1) * stride] = row
        prev = row
    return bytes(out)


def changed_pixel_count(buf_a: bytes, buf_b: bytes, tolerance: int) -> int:
    """Pixels whose per-channel delta exceeds tolerance, across all channels."""
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
    return len(changed)


def compare_pair(shot_path: Path, base_path: Path, tolerance: int) -> dict:
    record: dict = {"pct_changed": 0.0, "changed_pixels": 0, "pixels": 0, "note": ""}
    if shot_path.read_bytes() == base_path.read_bytes():
        width, height, _bpp = read_png_header(shot_path)
        record["pixels"] = width * height
        record["note"] = "byte-identical"
        return record
    shot_w, shot_h, shot_pixels = decode_png_rgba(shot_path)
    base_w, base_h, base_pixels = decode_png_rgba(base_path)
    if (shot_w, shot_h) != (base_w, base_h):
        record["pct_changed"] = 100.0
        record["pixels"] = max(shot_w * shot_h, base_w * base_h)
        record["note"] = f"size mismatch: shot {shot_w}x{shot_h} vs baseline {base_w}x{base_h}"
        return record
    changed = changed_pixel_count(shot_pixels, base_pixels, tolerance)
    total = shot_w * shot_h
    record["changed_pixels"] = changed
    record["pixels"] = total
    record["pct_changed"] = round(changed * 100.0 / total, 4) if total else 0.0
    return record


def run_diff(shots_dir: Path, baseline_dir: Path, threshold_pct: float, tolerance: int) -> dict:
    if not shots_dir.is_dir():
        return {"ok": False, "errors": [f"shots directory missing: {shots_dir}"]}
    if not baseline_dir.is_dir():
        return {"ok": False, "errors": [f"baseline directory missing: {baseline_dir}"]}
    shot_names = sorted(path.name for path in shots_dir.glob("*.png"))
    baseline_names = sorted(path.name for path in baseline_dir.glob("*.png"))
    missing_baselines = [name for name in shot_names if name not in baseline_names]
    uncaptured_baselines = [name for name in baseline_names if name not in shot_names]

    per_shot: dict[str, float] = {}
    records: dict[str, dict] = {}
    errors: list[str] = []
    for name in shot_names:
        if name in missing_baselines:
            continue
        try:
            record = compare_pair(shots_dir / name, baseline_dir / name, tolerance)
        except (PngError, OSError) as exc:
            errors.append(f"{name}: {exc}")
            continue
        records[name] = record
        per_shot[name] = record["pct_changed"]

    mismatched = sorted(name for name, pct in per_shot.items() if pct > threshold_pct)
    max_drift = max(per_shot.values(), default=0.0)
    compared = len(per_shot)
    ok = not errors and not missing_baselines and not uncaptured_baselines and not mismatched
    return {
        "ok": ok,
        "compared": compared,
        "mismatched": mismatched,
        "missing_baselines": missing_baselines,
        "uncaptured_baselines": uncaptured_baselines,
        "max_drift_pct": max_drift,
        "per_shot": per_shot,
        "errors": errors,
        "threshold_pct": threshold_pct,
        "tolerance": tolerance,
        "_records": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots-dir", type=Path, required=True, help="directory of freshly captured PNGs")
    parser.add_argument("--baseline-dir", type=Path, required=True, help="directory of committed baseline PNGs")
    parser.add_argument("--threshold-pct", type=float, default=DEFAULT_THRESHOLD_PCT,
                        help="max allowed changed-pixel share per shot (default: %(default)s)")
    parser.add_argument("--tolerance", type=int, default=DEFAULT_TOLERANCE,
                        help="per-channel delta (0-255) below which a pixel is unchanged (default: %(default)s)")
    args = parser.parse_args()

    result = run_diff(args.shots_dir, args.baseline_dir, args.threshold_pct, args.tolerance)
    records = result.pop("_records")
    for name in sorted(records):
        record = records[name]
        detail = record["note"] or f"{record['changed_pixels']}/{record['pixels']} pixels"
        print(f"{name}: {record['pct_changed']:.4f}% changed ({detail})", file=sys.stderr)
    for name in result["missing_baselines"]:
        print(f"{name}: no baseline", file=sys.stderr)
    for name in result["uncaptured_baselines"]:
        print(f"{name}: baseline has no matching capture", file=sys.stderr)
    for error in result["errors"]:
        print(f"error: {error}", file=sys.stderr)
    print(json.dumps(result, sort_keys=True))

    if result["errors"]:
        return EXIT_ERROR
    return EXIT_PASS if result["ok"] else EXIT_DRIFT


if __name__ == "__main__":
    sys.exit(main())
