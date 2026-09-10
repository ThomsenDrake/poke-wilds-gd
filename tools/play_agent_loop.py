#!/usr/bin/env python3
"""Optional closed-loop play agent over the agent-step file bridge.

Launches windowed Godot with scenario play_agent_loop, publishes one
command per turn, reads one observation, and writes play_agent_loop.json.
Live F filing requires PLAY_AGENT_LIVE_FILE=1. Headless / FORCE_HEADLESS
writes a skip envelope and exits 0.

Stdlib-only. Reuses godot_dap_smoketest / run_playtests via importlib.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent

DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
PLAY_TIMEOUT = 180
TURN_BUDGET = 40
SCENARIO = "play_agent_loop"
FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"
LIVE_FILE_ENV = "PLAY_AGENT_LIVE_FILE"
PLANNER_CMD_ENV = "PLAY_AGENT_PLANNER_CMD"
REPORT_NAME = "play_agent_loop.json"
ACTIONS = (
    "boot_new_game", "press", "hold", "observe", "file_feedback", "quit",
)
INPUTS = (
    "move_up", "move_down", "move_left", "move_right",
    "action_a", "action_b", "menu",
)
MESSAGE_PREFIX = "[agent-play]"


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


smoketest = _load_module("godot_dap_smoketest", TOOLS / "godot_dap_smoketest.py")
playtests = _load_module("run_playtests", TOOLS / "run_playtests.py")


def force_headless() -> bool:
    return os.environ.get(FORCE_HEADLESS_ENV, "").lower() not in ("", "0", "false", "no", "off")


def skip_reason() -> str:
    return (
        f"windowed-only play_agent_loop skipped under {FORCE_HEADLESS_ENV} "
        "(live play needs a real window and renderer)"
    )


def live_file_enabled() -> bool:
    return os.environ.get(LIVE_FILE_ENV, "").lower() in ("1", "true", "yes", "on")


def skip_report(reason: str) -> dict[str, Any]:
    return {
        "ok": True,
        "skipped": True,
        "reason": reason,
        "turns": 0,
        "anomalies": 0,
        "filed": False,
        "skipped_duplicate": 0,
        "issue_number": 0,
        "errors": [],
    }


def session_report(**overrides: Any) -> dict[str, Any]:
    report = {
        "ok": True,
        "skipped": False,
        "reason": "",
        "turns": 0,
        "anomalies": 0,
        "filed": False,
        "skipped_duplicate": 0,
        "issue_number": 0,
        "errors": [],
    }
    report.update(overrides)
    return report


def apply_live_policy(command: dict[str, Any]) -> dict[str, Any]:
    out = json.loads(json.dumps(command))
    if out.get("action") == "file_feedback":
        payload = dict(out.get("payload") or {})
        payload["live"] = bool(payload.get("live")) and live_file_enabled()
        out["payload"] = payload
    return out


def explorer_plan() -> list[dict[str, Any]]:
    return [
        {"action": "boot_new_game", "payload": {}},
        {"action": "hold", "payload": {"input": "move_right"}},
        {"action": "hold", "payload": {"input": "move_down"}},
        {"action": "hold", "payload": {"input": "move_left"}},
        {"action": "hold", "payload": {"input": "move_up"}},
        {"action": "press", "payload": {"input": "menu"}},
        {"action": "observe", "payload": {}},
        {"action": "quit", "payload": {}},
    ]


def turn_budget_error() -> dict[str, str | bool]:
    return {
        "code": "turn_budget_exhausted",
        "retryable": False,
        "hint": "Inspect .godot-smoke/play_agent_loop.json and rerun with fewer turns.",
    }


def write_json_atomic(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc), encoding="utf-8")
    tmp.replace(path)


def write_report(project: Path, report: dict[str, Any], out_path: Path | None = None) -> Path:
    path = out_path or (project / ".godot-smoke" / REPORT_NAME)
    write_json_atomic(path, report)
    return path


def _evaluate_novelty(observation: dict[str, Any], session: list[str], prior: list[Any]) -> dict[str, Any]:
    findings_path = TOOLS / "play_agent_findings.py"
    if not findings_path.is_file():
        anomalies = bool(observation.get("exceptions") or observation.get("stuck"))
        return {
            "anomaly": anomalies,
            "novel": anomalies,
            "live_fileable": False,
            "signature": "",
            "reason": "novelty_helper_missing",
            "anomalies": [],
        }
    findings = _load_module("play_agent_findings", findings_path)
    return findings.evaluate_novelty(observation, session, prior)


def _file_message(observation: dict[str, Any]) -> str:
    screen = str(observation.get("screen") or "unknown")
    tile = observation.get("tile")
    tile_s = f"{tile[0]},{tile[1]}" if isinstance(tile, list) and len(tile) == 2 else ""
    extra = "stuck" if observation.get("stuck") else "anomaly"
    exceptions = observation.get("exceptions") or []
    if exceptions:
        extra = str(exceptions[0])[:80]
    return f"{MESSAGE_PREFIX} {extra} on {screen} tile {tile_s}".strip()[:1000]


def _planner_command(observation: dict[str, Any], cmd: str) -> dict[str, Any] | None:
    try:
        proc = subprocess.run(
            cmd, input=json.dumps(observation), text=True, capture_output=True,
            shell=True, timeout=20, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (proc.stdout or "").strip()
    if not text:
        return None
    try:
        doc = json.loads(text)
    except ValueError:
        return None
    return doc if isinstance(doc, dict) and doc.get("action") in ACTIONS else None


def _next_command(
    turn: int,
    observation: dict[str, Any] | None,
    explorer_i: int,
    file_once: bool,
    novelty: dict[str, Any] | None,
) -> tuple[dict[str, Any], int, bool]:
    planner = os.environ.get(PLANNER_CMD_ENV, "").strip()
    if planner and observation is not None:
        planned = _planner_command(observation, planner)
        if planned:
            planned.setdefault("id", f"t{turn}")
            return apply_live_policy(planned), explorer_i, file_once
    if (
        novelty
        and novelty.get("anomaly")
        and novelty.get("novel")
        and not file_once
        and (novelty.get("live_fileable") or not live_file_enabled())
    ):
        command = {
            "id": f"t{turn}",
            "action": "file_feedback",
            "payload": {
                "message": _file_message(observation or {}),
                "live": live_file_enabled() and bool(novelty.get("live_fileable")),
            },
        }
        return apply_live_policy(command), explorer_i, True
    plan = explorer_plan()
    step = plan[min(explorer_i, len(plan) - 1)]
    command = {"id": f"t{turn}", "action": step["action"], "payload": dict(step.get("payload") or {})}
    return apply_live_policy(command), explorer_i + 1, file_once


def _wait_observation(path: Path, command_id: str, proc: subprocess.Popen, deadline: float) -> dict[str, Any] | None:
    while time.monotonic() < deadline:
        if path.exists():
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                doc = None
            if isinstance(doc, dict) and doc.get("command_id") == command_id:
                try:
                    path.unlink()
                except OSError:
                    pass
                return doc
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    return None


def _stop_process(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        try:
            proc.kill()
            proc.wait()
        except OSError:
            pass


def _drive(project: Path, godot_bin: str, timeout: float, prior_findings: list[Any]) -> dict[str, Any]:
    request_path = smoketest.write_smoke_request(project, SCENARIO)
    command_path = project / ".godot-smoke" / "agent_command.json"
    observation_path = project / ".godot-smoke" / "agent_observation.json"
    for leftover in (command_path, observation_path):
        if leftover.exists():
            leftover.unlink()
    collector = playtests.TraceCollector(capture_raw=True)
    exceptions: list[str] = []
    proc: subprocess.Popen | None = None
    t0 = time.monotonic()
    deadline = t0 + timeout
    turns = 0
    anomalies = 0
    skipped_duplicate = 0
    filed: bool | str = False
    issue_number = 0
    errors: list[dict[str, Any]] = []
    session_sigs: list[str] = []
    explorer_i = 0
    file_once = False
    observation: dict[str, Any] | None = None
    try:
        proc = subprocess.Popen(
            [godot_bin, "--path", str(project)], cwd=str(project),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace", bufsize=1,
        )
        stdout_lines: "queue.Queue[str]" = queue.Queue()
        stderr_lines: list[str] = []
        threads = [
            threading.Thread(target=playtests._drain_stdout, args=(proc.stdout, stdout_lines), daemon=True),
            threading.Thread(target=playtests._drain_stderr, args=(proc.stderr, stderr_lines), daemon=True),
        ]
        for thread in threads:
            thread.start()

        def drain() -> None:
            while True:
                try:
                    line = stdout_lines.get_nowait()
                except queue.Empty:
                    break
                playtests.handle_output_line(line, collector, exceptions)

        novelty: dict[str, Any] | None = None
        while turns < TURN_BUDGET and time.monotonic() < deadline:
            drain()
            command, explorer_i, file_once = _next_command(
                turns + 1, observation, explorer_i, file_once, novelty,
            )
            if command["action"] == "file_feedback" and novelty and not novelty.get("novel"):
                skipped_duplicate += 1
                novelty = None
                continue
            write_json_atomic(command_path, command)
            observation = _wait_observation(observation_path, command["id"], proc, deadline)
            turns += 1
            if observation is None:
                errors.append({
                    "code": "observation_timeout",
                    "retryable": True,
                    "hint": "Confirm the windowed Godot process is still polling agent_command.json.",
                })
                break
            novelty = _evaluate_novelty(observation, session_sigs, prior_findings)
            if novelty.get("anomaly"):
                anomalies += 1
                session_sigs.append(str(novelty.get("signature") or ""))
                if not novelty.get("novel"):
                    skipped_duplicate += 1
            feedback = observation.get("feedback")
            if isinstance(feedback, dict) and str(feedback.get("status", "")) in {"sent", "queued"}:
                filed = "live" if live_file_enabled() and bool((command.get("payload") or {}).get("live")) else "dry"
                issue_number = int(feedback.get("issue_number") or 0)
            if command["action"] == "quit":
                break
            if proc.poll() is not None:
                break
        if turns >= TURN_BUDGET:
            errors.append(turn_budget_error())
        drain()
        for line in stderr_lines:
            cleaned = playtests.clean_line(line)
            if any(marker in cleaned for marker in smoketest.ERROR_MARKERS):
                exceptions.append(cleaned)
        for thread in threads:
            thread.join(timeout=2)
    except OSError as exc:
        errors.append({"code": "launch_failed", "retryable": True, "hint": str(exc)})
    finally:
        _stop_process(proc)
        if request_path.exists():
            request_path.unlink()
    failed = bool(errors) or "play_agent_loop_failed" in collector.events
    return session_report(
        ok=not failed,
        skipped=False,
        turns=turns,
        anomalies=anomalies,
        filed=filed,
        skipped_duplicate=skipped_duplicate,
        issue_number=issue_number,
        errors=errors,
        events_seen=sorted(collector.events),
        exceptions=exceptions,
    )


def run_loop(project: Path, godot_bin: str, timeout: float = PLAY_TIMEOUT,
             prior_findings: list[Any] | None = None,
             report_path: Path | None = None) -> tuple[dict[str, Any], Path]:
    if force_headless():
        report = skip_report(skip_reason())
        return report, write_report(project, report, report_path)
    report = _drive(project, godot_bin, timeout, prior_findings or [])
    return report, write_report(project, report, report_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=str(ROOT))
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN))
    parser.add_argument("--timeout", type=float, default=PLAY_TIMEOUT)
    parser.add_argument("--turns", type=int, default=TURN_BUDGET)
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--prior-findings", type=Path, default=None)
    args = parser.parse_args(argv)
    project = Path(args.project).expanduser().resolve()
    if not (project / "project.godot").exists():
        print(f"error: no project.godot at {project}", file=sys.stderr)
        return 2
    if force_headless():
        report = skip_report(skip_reason())
        path = write_report(project, report, args.report)
        print(json.dumps(report, indent=2, sort_keys=True))
        print(f"SKIP: {skip_reason()}", file=sys.stderr)
        print(f"report: {path}", file=sys.stderr)
        return 0
    if not Path(args.godot_bin).exists():
        print(f"error: Godot binary missing: {args.godot_bin}", file=sys.stderr)
        return 2
    prior: list[Any] = []
    if args.prior_findings and args.prior_findings.exists():
        try:
            loaded = json.loads(args.prior_findings.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                prior = loaded
        except (OSError, ValueError):
            prior = []
    global TURN_BUDGET
    if args.turns > 0:
        TURN_BUDGET = min(int(args.turns), TURN_BUDGET)
    report, path = run_loop(project, args.godot_bin, float(args.timeout), prior, args.report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {path}", file=sys.stderr)
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
