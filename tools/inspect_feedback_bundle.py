#!/usr/bin/env python3
"""Validate and safely extract a playtest feedback ZIP using stdlib only."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import stat
import shutil
import tempfile
import sys
import struct
import zipfile

REQUIRED = {
    "README.txt", "engine.log", "report.json", "save.json", "trace.jsonl", "ui-tree.json"
}
OPTIONAL = {"screenshot.png"}
MAX_UNCOMPRESSED = 24 * 1024 * 1024
MAX_COMPRESSED = 16 * 1024 * 1024
REPORT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CREATED_AT_UTC = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:\.\d+)?Z?$")


def inspect_bundle(path: Path) -> dict:
    if path.stat().st_size > MAX_COMPRESSED:
        raise ValueError("bundle exceeds the compressed size limit")
    with zipfile.ZipFile(path) as archive:
        raw = path.read_bytes()
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ValueError("duplicate bundle entry")
        name_set = set(names)
        if not REQUIRED <= name_set or not name_set <= REQUIRED | OPTIONAL:
            raise ValueError(f"unexpected entry set: {sorted(name_set)}")
        for info in infos:
            if Path(info.filename).name != info.filename or ".." in info.filename or info.is_dir():
                raise ValueError("unsafe bundle path")
            mode = info.external_attr >> 16
            if info.external_attr & 0x10 or stat.S_IFMT(mode) and not stat.S_ISREG(mode):
                raise ValueError("unsafe bundle entry type")
            _validate_local_header(raw, info)
        if sum(info.file_size for info in infos) > MAX_UNCOMPRESSED:
            raise ValueError("bundle exceeds the uncompressed size limit")
        report = json.loads(archive.read("report.json"))
        _validate_manifest(report, name_set)
        artifacts = {entry["path"]: entry for entry in report["artifacts"]}
        expected_artifacts = name_set - {"report.json"}
        if set(artifacts) != expected_artifacts or len(artifacts) != len(report.get("artifacts", [])):
            raise ValueError("artifact manifest does not match ZIP entries")
        for name, entry in artifacts.items():
            if name not in names:
                raise ValueError(f"manifest artifact missing from ZIP: {name}")
            payload = archive.read(name)
            if len(payload) != entry.get("bytes"):
                raise ValueError(f"size mismatch: {name}")
            if hashlib.sha256(payload).hexdigest() != entry.get("sha256"):
                raise ValueError(f"checksum mismatch: {name}")
        return report


def _validate_manifest(report: object, names: set[str]) -> None:
    if not isinstance(report, dict):
        raise ValueError("report is not an object")
    if type(report.get("schema_version")) is not int or report["schema_version"] != 1:
        raise ValueError("unsupported report schema")
    if not _matches(REPORT_ID, report.get("report_id")):
        raise ValueError("invalid report ID")
    created_at = report.get("created_at_utc")
    if not isinstance(created_at, str) or not created_at.strip() or len(created_at) > 64 or not CREATED_AT_UTC.fullmatch(created_at):
        raise ValueError("invalid created_at_utc")
    message = report.get("message")
    if not isinstance(message, str) or not message.strip() or len(message) > 1000:
        raise ValueError("invalid message")
    if not _matches(re.compile(r"^[A-Z0-9-]{3,24}$"), report.get("tester_id")):
        raise ValueError("invalid tester ID")
    if not _matches(re.compile(r"^[0-9a-f]{32}$"), report.get("install_id")):
        raise ValueError("invalid install ID")
    _validate_build(report.get("build"))
    _validate_runtime(report.get("runtime"))
    _validate_game(report.get("game"))
    _validate_capture(report.get("capture"), report["game"], names)
    artifacts = report.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("invalid artifacts")
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str) or \
                not _is_safe_name(artifact["path"]) or type(artifact.get("bytes")) is not int or \
                artifact["bytes"] < 0 or not _matches(SHA256, artifact.get("sha256")) or \
                type(artifact.get("truncated")) is not bool:
            raise ValueError("invalid artifact")


def _validate_build(value: object) -> None:
    if not isinstance(value, dict) or not isinstance(value.get("version"), str) or \
            not value["version"] or len(value["version"]) > 128 or \
            not _matches(re.compile(r"^[A-Za-z0-9._-]{1,128}$"), value.get("build_id")) or \
            not _matches(re.compile(r"^[a-z0-9-]{1,40}$"), value.get("channel")) or \
            not _matches(re.compile(r"^(unknown|[0-9a-f]{7,64})$"), value.get("commit_sha")):
        raise ValueError("invalid build")


def _validate_runtime(value: object) -> None:
    if not isinstance(value, dict) or not _is_integer_pair(value.get("window_size")):
        raise ValueError("invalid runtime")
    for field in ("godot_version", "os_name", "os_version", "architecture", "locale", "renderer", "adapter"):
        if not isinstance(value.get(field), str) or len(value[field]) > 256:
            raise ValueError("invalid runtime")


def _validate_game(value: object) -> None:
    if not isinstance(value, dict) or not isinstance(value.get("current_screen"), str) or \
            not value["current_screen"].strip() or len(value["current_screen"]) > 128 or \
            type(value.get("world_seed")) is not int or not _is_integer_pair(value.get("player_tile")) or \
            not isinstance(value.get("active_area"), str) or not _is_finite_number(value.get("time_of_day_minutes")) or \
            type(value.get("total_steps")) is not int or not isinstance(value.get("party"), list) or \
            not isinstance(value.get("bag"), dict) or type(value.get("battle_active")) is not bool:
        raise ValueError("invalid game")


def _validate_capture(value: object, game: object, names: set[str]) -> None:
    if not isinstance(value, dict) or not isinstance(game, dict) or \
            type(value.get("screenshot_available")) is not bool or not isinstance(value.get("screen"), str) or \
            not value["screen"].strip() or len(value["screen"]) > 128 or value["screen"] != game.get("current_screen") or \
            value["screenshot_available"] != ("screenshot.png" in names):
        raise ValueError("invalid capture")


def _matches(pattern: re.Pattern[str], value: object) -> bool:
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def _is_integer_pair(value: object) -> bool:
    return isinstance(value, list) and len(value) == 2 and all(type(item) is int for item in value)


def _is_finite_number(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _is_safe_name(name: str) -> bool:
    return bool(name) and "/" not in name and "\\" not in name and ".." not in name and not name.endswith("/")


def _validate_local_header(raw: bytes, info: zipfile.ZipInfo) -> None:
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        raise ValueError("unsupported bundle compression method")
    if info.flag_bits & ~0x800:
        raise ValueError("unsupported bundle flags")
    if info.header_offset < 0 or info.header_offset + 30 > len(raw):
        raise ValueError("invalid local header")
    signature, _version, flags, method, _time, _date, crc, compressed, uncompressed, name_size, extra_size = \
        struct.unpack_from("<IHHHHHIIIHH", raw, info.header_offset)
    if signature != 0x04034B50:
        raise ValueError("invalid local header")
    name_start = info.header_offset + 30
    name_end = name_start + name_size
    if name_end + extra_size > len(raw):
        raise ValueError("invalid local header")
    encoding = "utf-8" if flags & 0x800 else "cp437"
    try:
        name = raw[name_start:name_end].decode(encoding)
    except UnicodeDecodeError as exc:
        raise ValueError("invalid local filename") from exc
    if flags != info.flag_bits or method != info.compress_type or crc != info.CRC or \
            compressed != info.compress_size or uncompressed != info.file_size or name != info.filename:
        raise ValueError("local header mismatch")


def extract_bundle(path: Path, destination: Path, *, write_bytes=None, replace=None) -> dict:
    report = inspect_bundle(path)
    if destination.exists() or destination.is_symlink():
        raise ValueError("extraction destination already exists")
    writer = write_bytes or Path.write_bytes
    rename = replace or Path.replace
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{destination.name}.extracting-", dir=destination.parent))
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                writer(temporary / info.filename, archive.read(info))
        rename(temporary, destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--extract", type=Path)
    args = parser.parse_args()
    report = extract_bundle(args.bundle, args.extract) if args.extract else inspect_bundle(args.bundle)
    print(json.dumps({"ok": True, "report_id": report["report_id"],
                      "message": report["message"], "artifacts": len(report.get("artifacts", []))}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print(f"feedback bundle invalid: {exc}", file=sys.stderr)
        raise SystemExit(1)
