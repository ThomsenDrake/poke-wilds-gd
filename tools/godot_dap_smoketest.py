#!/usr/bin/env python3
"""Run named Godot DAP smoke scenarios and assert required trace events."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
from typing import Any

FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"

# Error markers BOTH transports treat as a scenario exception. push_error prints
# "ERROR: <message>" (followed by an unmarked "at:" backtrace line), so the
# "ERROR: " prefix captures every scripted failure reason the old
# ("SCRIPT ERROR", "Parse Error") pair silently discarded — the silent-fail
# class behind the nav_audit false-red (miss-postmortems.json miss-002).
# Single-sourced here; run_playtests.py imports it so the transports agree.
ERROR_MARKERS = ("SCRIPT ERROR", "Parse Error", "ERROR: ")

# Scenarios that need a real resizable window (editor-managed DAP game windows
# reject programmatic resize) — the playtest runner launches them as standalone
# windowed subprocesses. Single-sourced here; run_playtests.py imports it.
WINDOWED_SUBPROCESS_SCENARIOS = {"display_matrix", "visual_sweep", "visual_sweep_update"}

# The windowed-only subset: these have no in-engine headless fallback, so under
# PLAYTEST_FORCE_HEADLESS both harnesses report them skipped-with-reason and
# exit 0 instead of failing them for missing pass events (transport honesty —
# captures need a real window and renderer). display_matrix is deliberately NOT
# here: it self-skips its pixel work in-engine when headless
# (display_matrix.gd:44-47) and still emits display_matrix_passed, so it stays
# runnable under force-headless.
WINDOWED_ONLY_SCENARIOS = {"visual_sweep", "visual_sweep_update"}


def force_headless() -> bool:
    return os.environ.get(FORCE_HEADLESS_ENV, "").lower() not in ("", "0", "false", "no", "off")


def windowed_skip_reason() -> str:
    return (
        f"windowed-only scenario skipped under {FORCE_HEADLESS_ENV} "
        "(captures need a real window and renderer)"
    )


SCENARIO_REQUIREMENTS = {
    "boot": {
        "all": ["boot_started", "boot_ready", "world_rebuilt"],
        "any": [["session_loaded", "session_created"]],
    },
    "overworld_step": {
        "all": ["boot_started", "boot_ready", "world_rebuilt", "save_written"],
        "any": [["session_loaded", "session_created"]],
    },
    "menu_save": {
        "all": ["menu_opened", "menu_closed", "save_written"],
        "any": [["session_loaded", "session_created"]],
    },
    "wild_battle": {
        "all": ["encounter_started", "battle_finished", "wild_battle_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "biome_probe": {
        "all": ["boot_started", "boot_ready", "world_rebuilt", "biome_probe_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "biome_traverse": {
        "all": ["boot_started", "boot_ready", "world_rebuilt", "encounter_started", "battle_finished"],
        "any": [["biome_entered", "traversal_blocked"], ["session_loaded", "session_created"]],
    },
    "field_move": {
        "all": ["boot_started", "boot_ready", "world_rebuilt", "field_move_used", "field_move_scenario_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "save_migration": {
        "all": ["boot_started", "boot_ready", "save_migration_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "playtest_journey": {
        "all": ["boot_started", "boot_ready", "playtest_journey_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "playtest_soak": {
        "all": ["boot_started", "boot_ready", "playtest_soak_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "visual_sweep": {
        "all": ["visual_sweep_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "visual_sweep_update": {
        "all": ["visual_sweep_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "nav_audit": {
        "all": ["nav_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "texture_audit": {
        "all": ["texture_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "data_audit": {
        "all": ["data_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "layout_audit": {
        "all": ["layout_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "world_consistency_audit": {
        "all": ["world_consistency_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "ui_render_audit": {
        "all": ["ui_render_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "battle_anim": {
        "all": ["battle_anim_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "display_matrix": {
        "all": ["display_matrix_passed"],
        "any": [["session_loaded", "session_created"]],
    },
    "harvest_flow": {
        "all": ["harvest_flow_passed"],
        "any": [["session_loaded", "session_created"]],
    },
}


def send(sock: socket.socket, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, separators=(",", ":"))
    packet = f"Content-Length: {len(body)}\r\n\r\n{body}".encode("utf-8")
    sock.sendall(packet)


def recv_messages(sock: socket.socket, timeout: float) -> list[dict[str, Any]]:
    sock.settimeout(timeout)
    data = b""
    messages: list[dict[str, Any]] = []
    end_time = time.time() + timeout

    while time.time() < end_time:
        try:
            chunk = sock.recv(8192)
            if not chunk:
                break
            data += chunk
            while True:
                split = data.find(b"\r\n\r\n")
                if split < 0:
                    break
                header = data[:split]
                match = re.search(rb"Content-Length:\s*(\d+)", header, re.IGNORECASE)
                if not match:
                    data = data[split + 4 :]
                    continue
                body_len = int(match.group(1))
                if len(data) < split + 4 + body_len:
                    break
                body = data[split + 4 : split + 4 + body_len]
                data = data[split + 4 + body_len :]
                messages.append(json.loads(body.decode("utf-8", "replace")))
        except socket.timeout:
            break

    return messages


def parse_trace_lines(output: str) -> list[dict[str, Any]]:
    traces: list[dict[str, Any]] = []
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "event" in parsed:
            traces.append(parsed)
    return traces


def failed_event_entry(trace: dict[str, Any]) -> dict[str, Any] | None:
    """Symmetric with the <scenario>_passed contract: any trace event ending in
    "_failed" is a structured scenario failure carrying its reasons payload, so
    a red can never surface as a blank 'missing required events' again. Both
    transports record these identically (run_playtests imports this helper)."""
    event = str(trace.get("event", ""))
    if not event.endswith("_failed"):
        return None
    payload = trace.get("payload", {})
    if not isinstance(payload, dict):
        payload = {"value": payload}
    return {"event": event, "payload": payload}


def write_smoke_request(project_path: Path, scenario: str) -> Path:
    request_path = project_path / ".godot-smoke" / "scenario.json"
    request_path.parent.mkdir(parents=True, exist_ok=True)
    request_path.write_text(json.dumps({"scenario": scenario}), encoding="utf-8")
    return request_path


def result_summary(
    scenario: str,
    events: set[str],
    had_exception: bool,
    failed_events: list[dict[str, Any]] | None = None,
    exceptions: list[str] | None = None,
) -> dict[str, Any]:
    """Total-run summary: a red ALWAYS names its cause — a missing required
    event, a DAP/ERROR exception, or a structured <scenario>_failed trace
    (failed_event_entry). The failed_events/exceptions fields mirror the
    run_playtests report so both transports report identically."""
    requirements = SCENARIO_REQUIREMENTS[scenario]
    missing_all = sorted(event for event in requirements["all"] if event not in events)
    missing_any = [group for group in requirements["any"] if not any(event in events for event in group)]
    failed_events = failed_events or []
    exceptions = exceptions or []
    return {
        "scenario": scenario,
        "events_seen": sorted(events),
        "missing_all": missing_all,
        "missing_any": missing_any,
        "had_exception": had_exception or bool(exceptions),
        "failed_events": failed_events,
        "exceptions": exceptions,
        "ok": not had_exception and not exceptions and not missing_all and not missing_any and not failed_events,
    }


def apply_region_step(project_path: Path, scenario: str, summary: dict[str, Any]) -> dict[str, Any]:
    """Mirror of run_playtests.apply_region_gate for the DAP transport.

    The canonical region gate lives in run_playtests.py (the windowed-subprocess
    transport); DAP is currently down. This mirror closes that documented gap so a
    revived DAP path cannot pass visual_sweep event-only (SCENARIO_REQUIREMENTS
    all=["visual_sweep_passed"]) without the explainable region gate. It is a
    no-op for every other scenario and under force-headless, loads the region diff
    lazily (run_playtests' import of this module is unaffected), and records the
    verdict into the result file only; red-tier failures flip ok.
    """
    if scenario != "visual_sweep" or force_headless():
        return summary
    try:
        spec = importlib.util.spec_from_file_location(
            "visual_region_diff", Path(__file__).resolve().with_name("visual_region_diff.py"))
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot locate visual_region_diff.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        verdict = module.run_region_diff(
            project_path / ".godot-smoke" / "shots",
            project_path / "docs" / "generated" / "visual-baselines",
            project_path / ".godot-smoke" / "region-diff",
        )
    except Exception as exc:  # a broken region tool must not silently pass
        summary["had_exception"] = True
        summary["ok"] = False
        summary["region_error"] = str(exc)
        return summary
    summary["region_failures"] = verdict["region_failures"]
    summary["region_quarantine"] = verdict["quarantine"]
    summary["clusters_explained"] = verdict["clusters_explained"]
    summary["clusters_unexplained"] = verdict["clusters_unexplained"]
    summary["region_artifacts"] = verdict["artifacts"]
    summary["region_global_backstop"] = verdict["global_backstop"]
    if verdict["errors"]:
        summary["had_exception"] = True
        summary["ok"] = False
        summary["region_errors"] = verdict["errors"]
    if verdict["region_failures"]:
        summary["ok"] = False
    return summary


# Follow-up (transport divergence): the QUARANTINE-TIER visual_sweep post-steps are
# intentionally NOT mirrored here -- Slice-4's apply_contrast_cvd and Slice-5's
# apply_vision_review both live only in run_playtests.py. apply_region_step exists
# because red-tier region failures can flip ok, so a revived DAP path must not skip
# them; contrast/CVD and Lane-4 vision-review findings are report-tier quarantine
# evidence that never flips ok, so skipping them on a (currently down) DAP path
# cannot hide a failure. DAP is down at landing; when it is revived, mirror
# apply_contrast_cvd and apply_vision_review here so a revived DAP visual_sweep
# produces the same quarantine evidence and .godot-smoke/vision-review.json as the
# windowed-subprocess transport.


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6006)
    parser.add_argument("--project", required=True)
    parser.add_argument("--scene", default="res://scenes/app/Main.tscn")
    parser.add_argument("--scenario", choices=sorted(SCENARIO_REQUIREMENTS), default="boot")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--result-file")
    args = parser.parse_args()

    project_path = Path(args.project).expanduser().resolve()
    result_file = Path(args.result_file) if args.result_file else project_path / ".godot-smoke" / f"result-{args.scenario}.json"

    # Transport honesty: a windowed-only scenario asked to run under
    # PLAYTEST_FORCE_HEADLESS is a skip-with-reason (exit 0), never red.
    if force_headless() and args.scenario in WINDOWED_ONLY_SCENARIOS:
        reason = windowed_skip_reason()
        print(f"SKIP: {args.scenario}: {reason}")
        summary = {
            "scenario": args.scenario,
            "events_seen": [],
            "missing_all": [],
            "missing_any": [],
            "had_exception": False,
            "ok": True,
            "skipped_reason": reason,
        }
        result_file.parent.mkdir(parents=True, exist_ok=True)
        result_file.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
        return 0

    request_path = write_smoke_request(project_path, args.scenario)
    had_exception = False
    events_seen: set[str] = set()
    failed_events: list[dict[str, Any]] = []
    exceptions: list[str] = []
    seq = 1

    try:
        with socket.create_connection((args.host, args.port), timeout=3) as sock:
            send(
                sock,
                {
                    "seq": seq,
                    "type": "request",
                    "command": "initialize",
                    "arguments": {
                        "clientID": "codex",
                        "clientName": "codex",
                        "adapterID": "godot",
                        "pathFormat": "path",
                        "linesStartAt1": True,
                        "columnsStartAt1": True,
                        "supportsVariableType": True,
                        "supportsVariablePaging": True,
                        "supportsRunInTerminalRequest": False,
                    },
                },
            )
            seq += 1
            send(
                sock,
                {
                    "seq": seq,
                    "type": "request",
                    "command": "launch",
                    "arguments": {"project": str(project_path), "scene": args.scene},
                },
            )
            seq += 1
            send(sock, {"seq": seq, "type": "request", "command": "configurationDone", "arguments": {}})
            seq += 1

            end = time.time() + args.timeout
            while time.time() < end:
                for msg in recv_messages(sock, timeout=0.6):
                    if msg.get("type") != "event":
                        continue
                    event = msg.get("event")
                    body = msg.get("body", {})
                    if event == "output":
                        output = body.get("output", "")
                        if output.strip():
                            print(output.strip())
                        for line in output.splitlines():
                            if any(marker in line for marker in ERROR_MARKERS):
                                exceptions.append(line.strip())
                        for trace in parse_trace_lines(output):
                            events_seen.add(str(trace.get("event", "")))
                            entry = failed_event_entry(trace)
                            if entry is not None:
                                failed_events.append(entry)
                    elif event == "stopped" and body.get("reason") == "exception":
                        had_exception = True
                        print(f"Exception: {body.get('text', 'Unknown debugger exception')}")
                    elif event == "terminated":
                        end = min(end, time.time() + 0.2)

                summary = result_summary(args.scenario, events_seen, had_exception, failed_events, exceptions)
                if summary["ok"]:
                    end = min(end, time.time() + 0.5)
                time.sleep(0.1)

            send(
                sock,
                {
                    "seq": seq,
                    "type": "request",
                    "command": "disconnect",
                    "arguments": {"terminateDebuggee": True},
                },
            )
    finally:
        if request_path.exists():
            request_path.unlink()

    summary = result_summary(args.scenario, events_seen, had_exception, failed_events, exceptions)
    summary = apply_region_step(project_path, args.scenario, summary)
    result_file.parent.mkdir(parents=True, exist_ok=True)
    result_file.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    if summary["ok"]:
        print("RESULT: OK")
        return 0

    print("RESULT: FAIL")
    if summary["missing_all"]:
        print("Missing required events:", ", ".join(summary["missing_all"]))
    if summary["missing_any"]:
        print("Missing alternative event groups:", summary["missing_any"])
    for failure in summary.get("failed_events", [])[:5]:
        print(f"Failed event {failure['event']}: {failure['payload']}")
    for exception in summary.get("exceptions", [])[:5]:
        print(f"Exception: {exception}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
