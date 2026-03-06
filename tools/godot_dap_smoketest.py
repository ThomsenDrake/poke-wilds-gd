#!/usr/bin/env python3
"""Run named Godot DAP smoke scenarios and assert required trace events."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import socket
import sys
import time
from typing import Any

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
        "all": ["encounter_started", "battle_finished"],
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


def write_smoke_request(project_path: Path, scenario: str) -> Path:
    request_path = project_path / ".godot-smoke" / "scenario.json"
    request_path.parent.mkdir(parents=True, exist_ok=True)
    request_path.write_text(json.dumps({"scenario": scenario}), encoding="utf-8")
    return request_path


def result_summary(scenario: str, events: set[str], had_exception: bool) -> dict[str, Any]:
    requirements = SCENARIO_REQUIREMENTS[scenario]
    missing_all = sorted(event for event in requirements["all"] if event not in events)
    missing_any = [group for group in requirements["any"] if not any(event in events for event in group)]
    return {
        "scenario": scenario,
        "events_seen": sorted(events),
        "missing_all": missing_all,
        "missing_any": missing_any,
        "had_exception": had_exception,
        "ok": not had_exception and not missing_all and not missing_any,
    }


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
    request_path = write_smoke_request(project_path, args.scenario)
    result_file = Path(args.result_file) if args.result_file else project_path / ".godot-smoke" / f"result-{args.scenario}.json"

    had_exception = False
    events_seen: set[str] = set()
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
                        for trace in parse_trace_lines(output):
                            events_seen.add(str(trace.get("event", "")))
                    elif event == "stopped" and body.get("reason") == "exception":
                        had_exception = True
                        print(f"Exception: {body.get('text', 'Unknown debugger exception')}")
                    elif event == "terminated":
                        end = min(end, time.time() + 0.2)

                summary = result_summary(args.scenario, events_seen, had_exception)
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

    summary = result_summary(args.scenario, events_seen, had_exception)
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
    return 1


if __name__ == "__main__":
    sys.exit(main())
