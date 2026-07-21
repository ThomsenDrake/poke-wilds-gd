#!/usr/bin/env python3
"""Stdlib-only PNG encoder + draw primitives (mirror of visual_diff's decoder).

Provides a tiny RGBA canvas with box/text/blit primitives and a from-scratch
PNG encoder (zlib + struct, color type 6, non-interlaced). Shared by the
region-diff triptychs and, later, the Lane-4 overlay writer; it exists so no
core tool needs a third-party imaging dependency. Encoded PNGs round-trip
through visual_diff.decode_png_rgba. Exit: n/a (library); the __main__ selftest
writes a scratch PNG and re-decodes it, 0 on success / 2 on mismatch.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import sys
import zlib

# 3x5 bitmap font: each glyph is 5 rows, each row a 3-bit int (bit2=left column,
# bit1=middle, bit0=right). Unknown characters render as a filled cell so missing
# glyphs are visible rather than silent.
FONT: dict[str, tuple[int, int, int, int, int]] = {
    " ": (0, 0, 0, 0, 0),
    "0": (7, 5, 5, 5, 7), "1": (2, 6, 2, 2, 7), "2": (7, 1, 7, 4, 7),
    "3": (7, 1, 3, 1, 7), "4": (5, 5, 7, 1, 1), "5": (7, 4, 7, 1, 7),
    "6": (7, 4, 7, 5, 7), "7": (7, 1, 1, 2, 2), "8": (7, 5, 7, 5, 7),
    "9": (7, 5, 7, 1, 7),
    "A": (2, 5, 7, 5, 5), "B": (6, 5, 6, 5, 6), "C": (3, 4, 4, 4, 3),
    "D": (6, 5, 5, 5, 6), "E": (7, 4, 6, 4, 7), "F": (7, 4, 6, 4, 4),
    "G": (3, 4, 5, 5, 3), "H": (5, 5, 7, 5, 5), "I": (7, 2, 2, 2, 7),
    "J": (1, 1, 1, 5, 2), "K": (5, 5, 6, 5, 5), "L": (4, 4, 4, 4, 7),
    "M": (5, 7, 7, 5, 5), "N": (5, 7, 7, 7, 5), "O": (2, 5, 5, 5, 2),
    "P": (6, 5, 6, 4, 4), "Q": (2, 5, 5, 6, 3), "R": (6, 5, 6, 5, 5),
    "S": (3, 4, 2, 1, 6), "T": (7, 2, 2, 2, 2), "U": (5, 5, 5, 5, 7),
    "V": (5, 5, 5, 5, 2), "W": (5, 5, 7, 7, 5), "X": (5, 5, 2, 5, 5),
    "Y": (5, 5, 2, 2, 2), "Z": (7, 1, 2, 4, 7),
    ":": (0, 2, 0, 2, 0), ".": (0, 0, 0, 0, 2), "-": (0, 0, 7, 0, 0),
    "_": (0, 0, 0, 0, 7), "/": (1, 1, 2, 4, 4), "(": (1, 2, 2, 2, 1),
    ")": (4, 2, 2, 2, 4), ">": (4, 2, 1, 2, 4), "=": (0, 7, 0, 7, 0),
    "+": (0, 2, 7, 2, 0), "%": (5, 1, 2, 4, 5),
}
GLYPH_W, GLYPH_H, GLYPH_GAP = 3, 5, 1


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data)) + tag + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def encode_png(width: int, height: int, rgba: bytes | bytearray) -> bytes:
    """Encode an RGBA8 buffer as a non-interlaced color-type-6 PNG."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # scanline filter: None
        raw += rgba[y * stride:(y + 1) * stride]
    return (
        b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
        + _chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _chunk(b"IEND", b"")
    )


class Canvas:
    """Minimal RGBA8 raster with draw primitives; .png() serializes."""

    def __init__(self, width: int, height: int, bg: tuple[int, int, int, int] = (16, 16, 16, 255)):
        self.w, self.h = width, height
        self.buf = bytearray(width * height * 4)
        for i in range(width * height):
            self.buf[i * 4:i * 4 + 4] = bytes(bg)

    def set_pixel(self, x: int, y: int, color: tuple[int, int, int, int]) -> None:
        if 0 <= x < self.w and 0 <= y < self.h:
            o = (y * self.w + x) * 4
            self.buf[o:o + 4] = bytes(color)

    def blit(self, x: int, y: int, sw: int, sh: int, sbuf: bytes | bytearray) -> None:
        """Copy an RGBA buffer (sw x sh) onto the canvas at (x, y), clipped."""
        for j in range(sh):
            dy = y + j
            if not 0 <= dy < self.h:
                continue
            for i in range(sw):
                dx = x + i
                if 0 <= dx < self.w:
                    so = (j * sw + i) * 4
                    do = (dy * self.w + dx) * 4
                    self.buf[do:do + 4] = sbuf[so:so + 4]

    def box(self, x: int, y: int, w: int, h: int, color: tuple[int, int, int, int]) -> None:
        """1px rectangle outline (w/h are in pixels, inclusive of the origin)."""
        for i in range(w):
            self.set_pixel(x + i, y, color)
            self.set_pixel(x + i, y + h - 1, color)
        for j in range(h):
            self.set_pixel(x, y + j, color)
            self.set_pixel(x + w - 1, y + j, color)

    def text(self, x: int, y: int, s: str, color: tuple[int, int, int, int]) -> None:
        """Render uppercase text in the 3x5 font; input is upper-cased."""
        cx = x
        for ch in s.upper():
            glyph = FONT.get(ch, (7, 7, 7, 7, 7))
            for row in range(GLYPH_H):
                bits = glyph[row]
                for col in range(GLYPH_W):
                    if bits & (1 << (GLYPH_W - 1 - col)):
                        self.set_pixel(cx + col, y + row, color)
            cx += GLYPH_W + GLYPH_GAP

    def png(self) -> bytes:
        return encode_png(self.w, self.h, self.buf)

    def save(self, path: Path) -> None:
        path.write_bytes(self.png())


def downscale(buf: bytes | bytearray, width: int, height: int, factor: int) -> tuple[int, int, bytes]:
    """Nearest-neighbour downsample by an integer factor (RGBA)."""
    nw, nh = max(1, width // factor), max(1, height // factor)
    out = bytearray(nw * nh * 4)
    for j in range(nh):
        sy = min(j * factor, height - 1)
        for i in range(nw):
            sx = min(i * factor, width - 1)
            so = (sy * width + sx) * 4
            do = (j * nw + i) * 4
            out[do:do + 4] = buf[so:so + 4]
    return nw, nh, bytes(out)


def _selftest() -> int:
    spec = importlib.util.spec_from_file_location(
        "visual_diff", Path(__file__).resolve().with_name("visual_diff.py"))
    if spec is None or spec.loader is None:
        return 2
    vd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vd)
    canvas = Canvas(24, 12, (0, 0, 0, 255))
    canvas.box(1, 1, 22, 10, (255, 0, 0, 255))
    canvas.text(4, 4, "OK", (0, 255, 0, 255))
    # Round-trip through visual_diff's decoder (it reads from a path, so write a
    # scratch sibling and remove it) to prove the encoder is decoder-compatible.
    tmp = Path(__file__).resolve().with_name("__png_canvas_selftest.png")
    canvas.save(tmp)
    try:
        w, h, back = vd.decode_png_rgba(tmp)
    finally:
        tmp.unlink(missing_ok=True)
    return 0 if (w, h) == (24, 12) and back == bytes(canvas.buf) else 2


if __name__ == "__main__":
    sys.exit(_selftest())
