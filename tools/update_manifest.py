#!/usr/bin/env python3
"""Pure shared-update manifest parse and newer-than comparison."""

from __future__ import annotations

import re

SCHEMA_VERSION = 1
OS_KEYS = ("linux", "windows", "macos")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHANNEL_RE = re.compile(r"^[a-z0-9-]{1,40}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
BUILD_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
PUBLISHED_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


def os_key(os_name: str) -> str:
    return {"Linux": "linux", "Windows": "windows", "macOS": "macos"}.get(os_name, "")


def parse(value: object) -> dict:
    if not isinstance(value, dict) or int(value.get("schema_version", 0)) != SCHEMA_VERSION:
        return {}
    channel = str(value.get("channel", ""))
    published = str(value.get("published_at", ""))
    build_id = str(value.get("build_id", ""))
    commit = str(value.get("commit_sha", "")).lower()
    if not CHANNEL_RE.fullmatch(channel) or not PUBLISHED_RE.fullmatch(published):
        return {}
    if not BUILD_ID_RE.fullmatch(build_id) or not COMMIT_RE.fullmatch(commit):
        return {}
    try:
        min_save = int(value.get("min_save_version", 0))
    except (TypeError, ValueError):
        return {}
    if min_save < 1 or not isinstance(value.get("builds"), dict):
        return {}
    builds = {}
    for key in OS_KEYS:
        entry = _parse_build(value["builds"].get(key))
        if not entry:
            return {}
        builds[key] = entry
    return {
        "schema_version": SCHEMA_VERSION,
        "channel": channel,
        "published_at": published,
        "build_id": build_id,
        "commit_sha": commit,
        "min_save_version": min_save,
        "builds": builds,
    }


def is_newer(latest: dict, current: dict, applied: dict | None = None) -> bool:
    applied = applied or {}
    latest_id = str(latest.get("build_id", ""))
    if not latest or not latest_id:
        return False
    if latest_id == str(current.get("build_id", "")) or latest_id == str(applied.get("build_id", "")):
        return False
    latest_ts = stamp_of(latest)
    if not latest_ts:
        return False
    if not _is_newer_stamp(latest_ts, latest_id, stamp_of(applied), str(applied.get("build_id", ""))):
        return False
    return _is_newer_stamp(latest_ts, latest_id, stamp_of(current), str(current.get("build_id", "")))


def stamp_of(value: dict) -> str:
    published = str(value.get("published_at", ""))
    if PUBLISHED_RE.fullmatch(published):
        return published
    return _stamp_from_build_id(str(value.get("build_id", "")))


def artifact_key(channel: str, build_id: str, os_name: str) -> str:
    return f"updates/{channel}/{build_id}/{os_name}"


def _parse_build(value: object) -> dict:
    if not isinstance(value, dict):
        return {}
    url = str(value.get("url", "")).strip()
    digest = str(value.get("sha256", "")).lower()
    filename = str(value.get("filename", ""))
    try:
        size = int(value.get("bytes", 0))
    except (TypeError, ValueError):
        return {}
    if size < 1 or not filename or "/" in filename or "\\" in filename:
        return {}
    if not SHA256_RE.fullmatch(digest) or not url.lower().startswith("https://"):
        return {}
    if any(token in url for token in ("?", "#", "@", "\\")):
        return {}
    return {"url": url, "sha256": digest, "bytes": size, "filename": filename}


def _stamp_from_build_id(build_id: str) -> str:
    tail = build_id.rsplit("-", 1)[-1]
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", tail):
        return ""
    return f"{tail[0:4]}-{tail[4:6]}-{tail[6:8]}T{tail[9:11]}:{tail[11:13]}:{tail[13:15]}Z"


def _is_newer_stamp(latest_ts: str, latest_id: str, baseline_ts: str, baseline_id: str) -> bool:
    if not baseline_ts and not baseline_id:
        return True
    if not baseline_ts or not latest_ts:
        return False
    if latest_ts != baseline_ts:
        return latest_ts > baseline_ts
    return latest_id > baseline_id
