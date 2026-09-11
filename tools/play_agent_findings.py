#!/usr/bin/env python3
"""Novelty and anomaly classification for play_agent_loop.

Pure functions over observation JSON. No Godot. Optional gh search is
best-effort and skipped when the binary is missing.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any

SIGNATURE_PARTS = 5
FINDING_SCHEMA = "play_agent_finding/1"
MESSAGE_PREFIX = "[agent-play]"
MESSAGE_MAX = 1000
BATTLE_STALL_TURNS = 24
IGNORE_SCREEN_IDS = {"", "loop"}
WIPE_EVENTS = frozenset({
    "title_new_game_chosen", "game_reset", "creation_confirmed",
})
SAFE_PARTY_SCREENS = frozenset({"title", "creation", "feedback"})
HARVEST_MOVES = frozenset({"cut", "smash", "dig"})
OVERLAY_SCREENS = frozenset({
    "menu", "party", "bag", "camp", "storage", "waystone",
})
IGNORE_GAMEPLAY_EVENTS = frozenset({
    "play_agent_step_applied", "play_agent_anomaly_observed",
})
ACTIONS = (
    "boot_new_game", "press", "hold", "observe", "file_feedback", "quit",
)
_COMPACT_OBS_KEYS = (
    "command_id", "screen", "monitors", "tile", "facing", "faced_action",
    "nearby", "harvest_near", "trace_tail", "exceptions", "stuck", "feedback",
)


def _as_int(value: Any, default: int | None = None) -> int | None:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _event_name(record: dict[str, Any]) -> str:
    return str(record.get("event") or record.get("name") or "")


def _payload(record: dict[str, Any]) -> dict[str, Any]:
    raw = record.get("payload")
    return raw if isinstance(raw, dict) else {}


def _trace_key(record: dict[str, Any]) -> tuple[Any, ...]:
    payload = record.get("payload")
    payload_s = json.dumps(payload, sort_keys=True, default=str) if isinstance(payload, dict) else ""
    return (_event_name(record), record.get("ts_msec"), payload_s)


def _new_events(
    observation: dict[str, Any],
    previous: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    if not isinstance(previous, dict):
        return []
    seen = {
        _trace_key(record)
        for record in (previous.get("trace_tail") or [])
        if isinstance(record, dict)
    }
    out: list[dict[str, Any]] = []
    for record in observation.get("trace_tail") or []:
        if isinstance(record, dict) and _trace_key(record) not in seen:
            out.append(record)
    return out


def _monitor_int(observation: dict[str, Any], key: str) -> int | None:
    monitors = observation.get("monitors")
    if not isinstance(monitors, dict) or key not in monitors:
        return None
    return _as_int(monitors.get(key))


def _screen_labels(observation: dict[str, Any]) -> dict[str, str]:
    labels: dict[str, str] = {}
    screen = str(observation.get("screen") or "").strip()
    if screen not in IGNORE_SCREEN_IDS:
        labels["obs"] = screen
    monitors = observation.get("monitors") if isinstance(observation.get("monitors"), dict) else {}
    monitor = str(monitors.get("game/current_screen") or "").strip()
    if monitor not in IGNORE_SCREEN_IDS:
        labels["mon"] = monitor
    tree = observation.get("ui_tree") if isinstance(observation.get("ui_tree"), dict) else {}
    tree_screen = str(tree.get("screen") or "").strip()
    if tree_screen not in IGNORE_SCREEN_IDS:
        labels["tree"] = tree_screen
    return labels


def _command_input(command: dict[str, Any] | None) -> tuple[str, str]:
    if not isinstance(command, dict):
        return "", ""
    payload = command.get("payload") if isinstance(command.get("payload"), dict) else {}
    return str(command.get("action") or ""), str(payload.get("input") or "")


def _harvest_token(near: Any) -> tuple[str, str] | None:
    if not isinstance(near, dict):
        return None
    action = str(near.get("action") or "")
    if not action:
        return None
    return action, _tile_token(near.get("tile"))


def _nearby_hits(observation: dict[str, Any], species: str, tile: Any) -> bool:
    want_tile = _tile_token(tile) if tile is not None else ""
    for row in observation.get("nearby") or []:
        if not isinstance(row, dict):
            continue
        if species and str(row.get("species_id") or "") != species:
            continue
        if want_tile and _tile_token(row.get("tile")) != want_tile:
            continue
        return True
    return False


def detect_anomalies(
    observation: dict[str, Any] | None,
    *,
    previous: dict[str, Any] | None = None,
    last_command: dict[str, Any] | None = None,
    session: dict[str, Any] | None = None,
) -> list[str]:
    if not isinstance(observation, dict) or not observation:
        return []
    found: list[str] = []
    exceptions = observation.get("exceptions") or []
    if isinstance(exceptions, list):
        for item in exceptions:
            text = str(item).strip()
            if not text:
                continue
            if "injection" in text.lower():
                found.append(f"injection_failed:{text}")
            else:
                found.append(f"exception:{text}")
    if observation.get("stuck") is True:
        found.append("stuck")
    for record in observation.get("trace_tail") or []:
        if not isinstance(record, dict):
            continue
        event = _event_name(record)
        if event.endswith("_failed"):
            found.append(f"failed:{event}")
    labels = _screen_labels(observation)
    if len(set(labels.values())) > 1:
        found.append("screen_disagree:" + ",".join(sorted(set(labels.values()))))
    screen = str(observation.get("screen") or "")
    party = _monitor_int(observation, "game/party_size")
    if party == 0 and screen not in SAFE_PARTY_SCREENS:
        names = {
            _event_name(record)
            for record in (observation.get("trace_tail") or [])
            if isinstance(record, dict)
        }
        if not names.intersection(WIPE_EVENTS):
            found.append("party_wiped")
    if session is not None:
        if screen == "battle":
            session["battle_streak"] = int(session.get("battle_streak") or 0) + 1
        else:
            session["battle_streak"] = 0
        if int(session.get("battle_streak") or 0) >= BATTLE_STALL_TURNS:
            found.append("battle_stalled")
    new_events = _new_events(observation, previous)
    if previous is not None:
        prev_party = _monitor_int(previous, "game/party_size")
        for record in new_events:
            event = _event_name(record)
            payload = _payload(record)
            if event == "battle_finished" and str(payload.get("outcome") or "") == "caught":
                if party is not None and prev_party is not None and party <= prev_party:
                    found.append("catch_uncommitted")
            if event == "overworld_mon_despawned" and str(payload.get("reason") or "") in {"ko", "caught"}:
                species = str(payload.get("species_id") or "")
                if species and _nearby_hits(observation, species, payload.get("tile")):
                    found.append(f"despawn_uncommitted:{species}")
            if event == "field_move_used":
                move_id = str(payload.get("move_id") or payload.get("action") or "")
                if move_id in HARVEST_MOVES:
                    token = _harvest_token(observation.get("harvest_near"))
                    if token is not None and token[0] == move_id:
                        move_tile = _tile_token(payload.get("tile"))
                        if not move_tile or token[1] == move_tile:
                            found.append(f"world_unchanged:{move_id}")
        action, button = _command_input(last_command)
        if action == "press" and button == "action_a" and screen != "battle":
            prev_faced = str((previous or {}).get("faced_action") or "")
            expect = screen in OVERLAY_SCREENS or prev_faced in HARVEST_MOVES
            if expect:
                gameplay = [
                    _event_name(record) for record in new_events
                    if _event_name(record) not in IGNORE_GAMEPLAY_EVENTS
                ]
                if not gameplay:
                    found.append("input_swallowed:action_a")
    return found


def is_quarantine_finding(item: Any) -> bool:
    if isinstance(item, str):
        return item.startswith("vision:")
    return _is_quarantine(item)


def hard_anomalies(anomalies: list[Any] | None) -> list[str]:
    out: list[str] = []
    for item in anomalies or []:
        if isinstance(item, str) and item and not is_quarantine_finding(item):
            out.append(item)
    return out


def vision_finding_ids(vision_review: dict[str, Any] | None) -> list[str]:
    if not isinstance(vision_review, dict):
        return []
    out: list[str] = []
    for item in vision_review.get("findings") or []:
        if isinstance(item, str) and item.strip():
            text = item.strip()
            if not text.startswith("vision:"):
                text = f"vision:{text}"
            if text not in out:
                out.append(text)
        elif isinstance(item, dict):
            ident = str(item.get("id") or item.get("finding_id") or "advisory").strip()
            text = ident if ident.startswith("vision:") else f"vision:{ident}"
            if text not in out:
                out.append(text)
    return out


def maybe_review_anomaly_frame(
    png_path: Path | None,
    *,
    allow_model: bool | None = None,
) -> dict[str, Any]:
    """Advisory Lane-4 of one anomaly PNG. Never files. Never writes the sweep sidecar."""
    result: dict[str, Any] = {
        "tier": "quarantine",
        "source": "vlm",
        "quarantine": True,
        "status": "skipped",
        "reason": "no_frame",
        "findings": [],
        "png": "",
    }
    if png_path is None or not Path(png_path).is_file():
        return result
    result["png"] = str(png_path)
    if allow_model is None:
        raw = os.environ.get("PLAY_AGENT_ANOMALY_VLM", "1").strip().lower()
        allow_model = raw not in {"0", "false", "no", "off"}
    if not allow_model:
        result["reason"] = "disabled"
        return result
    if shutil.which("cmd") is None or not os.environ.get("COMMAND_CODE_API_KEY"):
        result["reason"] = "no_model"
        return result
    cmd = shutil.which("cmd")
    prompt = (
        "Advisory visual review of one play-agent anomaly frame. "
        "Quarantine-forever. Do not file a GitHub issue. Do not fail a gate. "
        f"Image path: {png_path}. "
        'Return JSON {"findings":["short-id"]} for visual bugs, or {"findings":[]}.'
    )
    try:
        proc = subprocess.run(
            [cmd, "-p", "--no-session", "--permission-mode", "plan", prompt],
            capture_output=True, text=True, check=False, timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        result["reason"] = f"review_error:{type(exc).__name__}"
        return result
    text = (proc.stdout or "").strip()
    parsed = None
    try:
        parsed = json.loads(text)
    except ValueError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                parsed = json.loads(text[start:end + 1])
            except ValueError:
                parsed = None
    if not isinstance(parsed, dict):
        result["reason"] = "unparsed"
        return result
    result["status"] = "reviewed"
    result["reason"] = ""
    result["findings"] = vision_finding_ids({"findings": parsed.get("findings") or []})
    return result


def biomes_from_observation(observation: dict[str, Any] | None) -> list[str]:
    out: list[str] = []
    if not isinstance(observation, dict):
        return out
    for record in observation.get("trace_tail") or []:
        if not isinstance(record, dict) or _event_name(record) != "biome_entered":
            continue
        biome = str(_payload(record).get("biome") or "").strip()
        if biome and biome not in out:
            out.append(biome)
    return out


def merge_biomes(existing: list[str] | None, observation: dict[str, Any] | None) -> list[str]:
    out = [item for item in (existing or []) if item]
    for biome in biomes_from_observation(observation):
        if biome not in out:
            out.append(biome)
    return out


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


def _github_duplicate(
    sig: str,
    observation: dict[str, Any],
    issues: list[Any],
    anomalies: list[str] | None = None,
) -> bool:
    screen = str(observation.get("screen") or "")
    exc = _exception_class(observation)
    token = str((anomalies or [""])[0])[:40] if anomalies else ""
    for issue in issues:
        blob = issue if isinstance(issue, str) else json.dumps(issue, sort_keys=True)
        if "[agent-play]" not in blob:
            continue
        if sig and sig in blob:
            return True
        if token and token in blob and screen and screen in blob:
            return True
        if screen and exc and screen in blob and exc in blob:
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
    *,
    previous: dict[str, Any] | None = None,
    last_command: dict[str, Any] | None = None,
    session: dict[str, Any] | None = None,
    vision_review: dict[str, Any] | None = None,
) -> dict[str, Any]:
    session_signatures = list(session_signatures or [])
    prior_findings = list(prior_findings or [])
    sig = signature(observation)
    anomalies = detect_anomalies(
        observation, previous=previous, last_command=last_command, session=session,
    )
    for item in vision_finding_ids(vision_review):
        if item not in anomalies:
            anomalies.append(item)
    hard = hard_anomalies(anomalies)
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
    if not hard:
        result["reason"] = "quarantine_only"
        return result
    known = set(session_signatures) | set(_prior_signatures(prior_findings))
    issues = github_issues if github_issues is not None else []
    if sig in known or _github_duplicate(sig, observation or {}, issues, hard):
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


def coverage_from_turns(
    turns: list[Any] | None,
    biomes: list[str] | None = None,
) -> dict[str, list[str]]:
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
    biome_ids: list[str] = []
    for biome in biomes or []:
        text = str(biome or "").strip()
        if text and text not in biome_ids:
            biome_ids.append(text)
    return {"screens": screens, "verbs": verbs, "biomes": biome_ids}


def signature_slug(sig: str) -> str:
    text = str(sig or "unknown")
    cleaned = "".join(ch if ch.isalnum() else "-" for ch in text)
    cleaned = "-".join(part for part in cleaned.split("-") if part) or "unknown"
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]
    return f"{cleaned[:48]}-{digest}"


def replay_relpath(signature_text: str) -> str:
    return f".godot-smoke/play_agent_findings/{signature_slug(signature_text)}.json"


def build_finding_pack(
    observation: dict[str, Any] | None,
    commands: list[Any] | None,
    *,
    signature_text: str = "",
    anomalies: list[str] | None = None,
    video: str = "",
    report: str = "",
    vision_review: dict[str, Any] | None = None,
) -> dict[str, Any]:
    observation = observation if isinstance(observation, dict) else {}
    sig = signature_text or signature(observation)
    pack: dict[str, Any] = {
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
        "replay": f"python3 tools/play_agent_loop.py --replay {replay_relpath(sig)}",
    }
    if isinstance(vision_review, dict) and vision_review:
        pack["vision_review"] = {
            "tier": "quarantine",
            "source": "vlm",
            "quarantine": True,
            "status": str(vision_review.get("status") or "skipped"),
            "reason": str(vision_review.get("reason") or ""),
            "png": str(vision_review.get("png") or ""),
            "findings": list(vision_review.get("findings") or []),
        }
    return pack


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
    anomalies: list[str] | None = None,
    replay_rel: str = "",
) -> str:
    observation = observation if isinstance(observation, dict) else {}
    screen = str(observation.get("screen") or "unknown")
    tile = observation.get("tile")
    tile_s = f"{tile[0]},{tile[1]}" if isinstance(tile, list) and len(tile) == 2 else ""
    extra = "stuck" if observation.get("stuck") else "anomaly"
    hard = hard_anomalies(anomalies)
    if hard:
        extra = hard[0].replace("/home/", "")[:80]
    else:
        exceptions = observation.get("exceptions") or []
        if isinstance(exceptions, list) and exceptions:
            extra = str(exceptions[0])[:80].replace("/home/", "")
    sig = signature_text or signature(observation)
    sig_short = "/".join(sig.split("|")[:4])
    tokens = [_command_token(item) for item in (commands or []) if isinstance(item, dict)]
    cmds = ",".join(token for token in tokens[-6:] if token)
    seed = world_seed_of(observation)
    replay = replay_rel or replay_relpath(sig)
    parts = [MESSAGE_PREFIX, extra, "on", screen]
    if tile_s:
        parts.extend(["tile", tile_s])
    if seed:
        parts.extend(["seed", str(seed)])
    if sig_short:
        parts.extend(["sig", sig_short])
    if cmds:
        parts.extend(["cmds", cmds])
    parts.extend(["replay:", f"python3 tools/play_agent_loop.py --replay {replay}"])
    return " ".join(parts).replace("/home/", "")[:MESSAGE_MAX]
