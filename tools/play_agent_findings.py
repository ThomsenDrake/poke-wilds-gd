#!/usr/bin/env python3
"""Novelty and anomaly classification for play_agent_loop.

Pure functions over observation JSON. No Godot. Optional gh search is
best-effort and skipped when the binary is missing.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from typing import Any

SIGNATURE_PARTS = 5
FINDING_SCHEMA = "play_agent_finding/1"
MESSAGE_PREFIX = "[agent-play]"
MESSAGE_MAX = 1000
ACTIONS = (
    "boot_new_game", "press", "hold", "observe", "file_feedback", "quit",
)
_COMPACT_OBS_KEYS = (
    "command_id", "screen", "monitors", "tile", "facing", "faced_action",
    "nearby", "harvest_near", "trace_tail", "exceptions", "stuck", "feedback",
)


def detect_anomalies(observation: dict[str, Any] | None) -> list[str]:
    if not isinstance(observation, dict) or not observation:
        return []
    found: list[str] = []
    exceptions = observation.get("exceptions") or []
    if isinstance(exceptions, list):
        for item in exceptions:
            text = str(item).strip()
            if text:
                found.append(f"exception:{text}")
    if observation.get("stuck") is True:
        found.append("stuck")
    for record in observation.get("trace_tail") or []:
        if not isinstance(record, dict):
            continue
        event = str(record.get("event", ""))
        if event.endswith("_failed"):
            found.append(f"failed:{event}")
    return found


def ui_tree_structure_hash(ui_tree: Any) -> str:
    nodes = []
    if isinstance(ui_tree, dict):
        raw = ui_tree.get("nodes") or []
        if isinstance(raw, list):
            nodes = raw
    parts: list[str] = []
    for node in nodes:
        if not isinstance(node, dict):
            continue
        parts.append(
            f"{node.get('path', '')}|{node.get('type', '')}|{node.get('text', '')}"
        )
    digest = hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()
    return digest[:16]


def _tile_token(tile: Any) -> str:
    if isinstance(tile, (list, tuple)) and len(tile) == 2:
        return f"{tile[0]},{tile[1]}"
    return ""


def _exception_class(observation: dict[str, Any]) -> str:
    exceptions = observation.get("exceptions") or []
    if not isinstance(exceptions, list) or not exceptions:
        return ""
    text = str(exceptions[0]).strip()
    if ":" in text:
        text = text.split(":", 1)[0]
    return text.replace("|", " ").split()[0] if text else ""


def _last_failed_event(observation: dict[str, Any]) -> str:
    last = ""
    for record in observation.get("trace_tail") or []:
        if isinstance(record, dict):
            event = str(record.get("event", ""))
            if event.endswith("_failed"):
                last = event
    return last


def signature(observation: dict[str, Any] | None) -> str:
    if not isinstance(observation, dict):
        observation = {}
    screen = str(observation.get("screen") or "")
    tile = _tile_token(observation.get("tile"))
    exc = _exception_class(observation)
    failed = _last_failed_event(observation)
    tree_hash = ui_tree_structure_hash(observation.get("ui_tree") or {})
    return f"{screen}|{tile}|{exc}|{failed}|{tree_hash}"


def _is_quarantine(item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    tier = str(item.get("tier") or item.get("severity") or "").lower()
    if item.get("quarantine") is True or tier == "quarantine":
        return True
    source = str(item.get("source") or item.get("kind") or "").lower()
    return "vision" in source or source in {"vlm", "lane-4", "lane4"}


def _prior_signatures(prior_findings: list[Any]) -> list[str]:
    out: list[str] = []
    for item in prior_findings:
        if isinstance(item, str) and item.count("|") == SIGNATURE_PARTS - 1:
            out.append(item)
        elif isinstance(item, dict):
            sig = item.get("signature")
            if isinstance(sig, str) and sig.count("|") == SIGNATURE_PARTS - 1:
                out.append(sig)
    return out


def _github_duplicate(sig: str, observation: dict[str, Any], issues: list[Any]) -> bool:
    screen = str(observation.get("screen") or "")
    exc = _exception_class(observation)
    for issue in issues:
        blob = issue if isinstance(issue, str) else json.dumps(issue, sort_keys=True)
        if "[agent-play]" not in blob:
            continue
        if screen and screen in blob and (not exc or exc in blob):
            return True
        if sig and sig in blob:
            return True
    return False


def search_open_issues() -> list[str]:
    if shutil.which("gh") is None:
        return []
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--search", "[agent-play]", "--state", "open",
             "--json", "title,body", "--limit", "50"],
            capture_output=True, text=True, check=False, timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    try:
        rows = json.loads(result.stdout)
    except ValueError:
        return []
    out: list[str] = []
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, dict):
            out.append(f"{row.get('title', '')}\n{row.get('body', '')}")
    return out


def evaluate_novelty(
    observation: dict[str, Any] | None,
    session_signatures: list[str] | None = None,
    prior_findings: list[Any] | None = None,
    github_issues: list[Any] | None = None,
) -> dict[str, Any]:
    session_signatures = list(session_signatures or [])
    prior_findings = list(prior_findings or [])
    sig = signature(observation)
    anomalies = detect_anomalies(observation)
    result = {
        "anomaly": bool(anomalies),
        "novel": False,
        "live_fileable": False,
        "signature": sig,
        "reason": "no_anomaly",
        "anomalies": anomalies,
    }
    if not anomalies:
        return result
    if any(_is_quarantine(item) for item in prior_findings) and not (
        observation.get("stuck") or observation.get("exceptions") or
        any(item.startswith("failed:") for item in anomalies)
    ):
        result["reason"] = "quarantine_only"
        return result
    known = set(session_signatures) | set(_prior_signatures(prior_findings))
    issues = github_issues
    if issues is None:
        issues = []
    if sig in known or _github_duplicate(sig, observation or {}, issues):
        result["reason"] = "duplicate"
        return result
    result["novel"] = True
    result["live_fileable"] = True
    result["reason"] = "novel"
    return result


def world_seed_of(observation: dict[str, Any] | None) -> int:
    if not isinstance(observation, dict):
        return 0
    monitors = observation.get("monitors") or {}
    if not isinstance(monitors, dict):
        return 0
    try:
        return int(monitors.get("game/world_seed") or 0)
    except (TypeError, ValueError):
        return 0


def compact_observation(observation: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(observation, dict):
        return {}
    out: dict[str, Any] = {}
    for key in _COMPACT_OBS_KEYS:
        if key in observation:
            out[key] = observation[key]
    ui_tree = observation.get("ui_tree")
    if isinstance(ui_tree, dict):
        out["ui_tree"] = {
            "screen": ui_tree.get("screen"),
            "node_count": ui_tree.get("node_count"),
        }
    return out


def compact_turn(
    command: dict[str, Any] | None,
    observation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    command = command if isinstance(command, dict) else {}
    observation = observation if isinstance(observation, dict) else {}
    payload = command.get("payload")
    exceptions = observation.get("exceptions") or []
    return {
        "id": str(command.get("id") or ""),
        "action": str(command.get("action") or ""),
        "payload": dict(payload) if isinstance(payload, dict) else {},
        "screen": str(observation.get("screen") or ""),
        "tile": observation.get("tile"),
        "stuck": bool(observation.get("stuck")),
        "exception_count": len(exceptions) if isinstance(exceptions, list) else 0,
    }


def coverage_from_turns(turns: list[Any] | None) -> dict[str, list[str]]:
    screens: list[str] = []
    verbs: list[str] = []
    for item in turns or []:
        if not isinstance(item, dict):
            continue
        screen = str(item.get("screen") or "")
        if screen and screen not in screens:
            screens.append(screen)
        action = str(item.get("action") or "")
        payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
        if action in {"press", "hold"}:
            token = f"{action}:{payload.get('input') or ''}"
        else:
            token = action
        if token and token not in verbs:
            verbs.append(token)
    return {"screens": screens, "verbs": verbs}


def signature_slug(sig: str) -> str:
    text = str(sig or "unknown")
    cleaned = "".join(ch if ch.isalnum() else "-" for ch in text)
    cleaned = "-".join(part for part in cleaned.split("-") if part) or "unknown"
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]
    return f"{cleaned[:48]}-{digest}"


def build_finding_pack(
    observation: dict[str, Any] | None,
    commands: list[Any] | None,
    *,
    signature_text: str = "",
    anomalies: list[str] | None = None,
    video: str = "",
    report: str = "",
) -> dict[str, Any]:
    observation = observation if isinstance(observation, dict) else {}
    sig = signature_text or signature(observation)
    return {
        "schema": FINDING_SCHEMA,
        "signature": sig,
        "anomalies": list(anomalies or detect_anomalies(observation)),
        "world_seed": world_seed_of(observation),
        "screen": str(observation.get("screen") or ""),
        "tile": observation.get("tile"),
        "commands": [item for item in (commands or []) if isinstance(item, dict)],
        "observation": compact_observation(observation),
        "video": video,
        "report": report,
    }


def write_finding_pack(directory: Path, pack: dict[str, Any]) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{signature_slug(str(pack.get('signature') or ''))}.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(pack, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)
    return path


def commands_from_source(doc: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(doc, dict) or not isinstance(doc.get("commands"), list):
        return []
    out: list[dict[str, Any]] = []
    for index, item in enumerate(doc["commands"], start=1):
        if not isinstance(item, dict):
            continue
        action = item.get("action")
        if action not in ACTIONS:
            continue
        payload = item.get("payload")
        out.append({
            "id": str(item.get("id") or f"t{index}"),
            "action": action,
            "payload": dict(payload) if isinstance(payload, dict) else {},
        })
    return out


def replay_commands(
    doc: dict[str, Any] | None,
    *,
    include_file: bool = False,
) -> list[dict[str, Any]]:
    commands = commands_from_source(doc)
    if include_file:
        return commands
    return [item for item in commands if item.get("action") != "file_feedback"]


def load_json_object(path: Path) -> dict[str, Any] | None:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def load_replay_source(path: Path) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    if not path.exists():
        return [], {
            "code": "replay_source_missing",
            "retryable": False,
            "hint": f"No replay pack at {path}; pass a finding JSON or session report.",
        }
    doc = load_json_object(path)
    if doc is None:
        return [], {
            "code": "replay_source_invalid",
            "retryable": False,
            "hint": f"Replay source {path} is not a JSON object.",
        }
    commands = replay_commands(doc)
    if not commands:
        return [], {
            "code": "replay_missing_commands",
            "retryable": False,
            "hint": "The pack or report has no replayable commands[]; record a session first.",
        }
    return commands, None


def load_prior_ledger(path: Path) -> list[Any]:
    if not path.exists():
        return []
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if isinstance(loaded, list):
        return loaded
    if isinstance(loaded, dict) and isinstance(loaded.get("findings"), list):
        return loaded["findings"]
    return []


def merge_prior_ledger(existing: list[Any], packs: list[Any]) -> list[Any]:
    known = set(_prior_signatures(existing))
    out = list(existing)
    for pack in packs:
        sig = ""
        screen = ""
        anomalies: list[Any] = []
        if isinstance(pack, str):
            sig = pack
        elif isinstance(pack, dict):
            sig = str(pack.get("signature") or "")
            screen = str(pack.get("screen") or "")
            raw = pack.get("anomalies") or []
            anomalies = list(raw) if isinstance(raw, list) else []
        if not sig or sig.count("|") != SIGNATURE_PARTS - 1 or sig in known:
            continue
        out.append({"signature": sig, "screen": screen, "anomalies": anomalies})
        known.add(sig)
    return out


def save_prior_ledger(path: Path, items: list[Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(items, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)
    return path


def _command_token(item: dict[str, Any]) -> str:
    action = str(item.get("action") or "")
    payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
    if action in {"press", "hold"} and payload.get("input"):
        return f"{action}:{payload.get('input')}"
    return action


def file_message(
    observation: dict[str, Any] | None,
    commands: list[Any] | None = None,
    signature_text: str = "",
) -> str:
    observation = observation if isinstance(observation, dict) else {}
    screen = str(observation.get("screen") or "unknown")
    tile = observation.get("tile")
    tile_s = f"{tile[0]},{tile[1]}" if isinstance(tile, list) and len(tile) == 2 else ""
    extra = "stuck" if observation.get("stuck") else "anomaly"
    exceptions = observation.get("exceptions") or []
    if isinstance(exceptions, list) and exceptions:
        extra = str(exceptions[0])[:80].replace("/home/", "")
    sig = signature_text or signature(observation)
    sig_short = "/".join(sig.split("|")[:4])
    tokens = [_command_token(item) for item in (commands or []) if isinstance(item, dict)]
    cmds = ",".join(token for token in tokens[-6:] if token)
    seed = world_seed_of(observation)
    parts = [MESSAGE_PREFIX, extra, "on", screen]
    if tile_s:
        parts.extend(["tile", tile_s])
    if seed:
        parts.extend(["seed", str(seed)])
    if sig_short:
        parts.extend(["sig", sig_short])
    if cmds:
        parts.extend(["cmds", cmds])
    return " ".join(parts)[:MESSAGE_MAX]
