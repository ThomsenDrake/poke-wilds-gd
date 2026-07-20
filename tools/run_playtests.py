#!/usr/bin/env python3
"""Run automated playtest scenarios sequentially and emit a JSON report.

Transport selection: when the Godot editor's DAP endpoint is listening the
scenarios run through the DAP flow (reusing the client from
godot_dap_smoketest.py); otherwise the runner falls back to launching the
Godot binary headless and parsing trace lines from stdout. Set
PLAYTEST_FORCE_HEADLESS=1 to force the headless path even when DAP is up.

Transport honesty: under PLAYTEST_FORCE_HEADLESS the windowed-only scenarios
(smoketest.WINDOWED_ONLY_SCENARIOS) are reported skipped-with-reason — never
failed — because captures need a real window and renderer; the exit code stays
0 when only transport-skips occurred. The report carries stamps (head_sha from
git plus godot_version/window/renderer harvested from snapshot_captured trace
payloads; null when unavailable, never faked) so a later verifier can refuse
stale reports.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import sys
import threading
import time
from typing import Any

# Single-source the DAP client primitives and the scenario requirements table
# from the sibling smoke harness instead of duplicating them here.
_SMOKE_PATH = Path(__file__).resolve().with_name("godot_dap_smoketest.py")
_spec = importlib.util.spec_from_file_location("godot_dap_smoketest", _SMOKE_PATH)
if _spec is None or _spec.loader is None:
    raise SystemExit(f"Cannot load the DAP smoke harness from {_SMOKE_PATH}")
smoketest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoketest)

SCENARIO_REQUIREMENTS = smoketest.SCENARIO_REQUIREMENTS
# The windowed scenario sets and the force-headless semantics are
# single-sourced in the sibling smoke harness (see the note there).
WINDOWED_SUBPROCESS_SCENARIOS = smoketest.WINDOWED_SUBPROCESS_SCENARIOS
WINDOWED_ONLY_SCENARIOS = smoketest.WINDOWED_ONLY_SCENARIOS
FORCE_HEADLESS_ENV = smoketest.FORCE_HEADLESS_ENV
force_headless = smoketest.force_headless

PLAYTEST_SCENARIOS = ["playtest_journey", "playtest_soak", "nav_audit", "texture_audit", "data_audit", "layout_audit", "world_consistency_audit", "ui_render_audit", "battle_anim", "display_matrix", "harvest_flow"]
SMOKE_SCENARIOS = [
    "boot",
    "overworld_step",
    "menu_save",
    "wild_battle",
    "biome_probe",
    "biome_traverse",
    "field_move",
    "visual_sweep",
]
DEFAULT_SCENE = "res://scenes/app/Main.tscn"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 6006
DEFAULT_TIMEOUT = 90.0
DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
ERROR_MARKERS = ("SCRIPT ERROR", "Parse Error")
CONNECT_TIMEOUT_S = 3.0
NO_RESPONSE_GRACE_S = 10.0
SETTLE_S = 0.5
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


class TraceCollector:
    """Accumulates events, warnings, the *_passed payload, and snapshot stamps."""

    def __init__(self) -> None:
        self.events: set[str] = set()
        self.warnings: list[dict[str, Any]] = []
        self.passed_payload: Any = None
        self.snapshot_payloads: list[dict[str, Any]] = []

    def add(self, trace: dict[str, Any]) -> None:
        event = str(trace.get("event", ""))
        if not event:
            return
        self.events.add(event)
        payload = trace.get("payload", {})
        if not isinstance(payload, dict):
            payload = {"value": payload}
        if event == "warning":
            self.warnings.append(
                {
                    "source": str(trace.get("source", "")),
                    "message": str(payload.get("message", "")),
                    "payload": payload,
                }
            )
        if event == "snapshot_captured":
            self.snapshot_payloads.append(payload)
        if event.endswith("_passed"):
            self.passed_payload = payload


def project_stamp(payloads: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Project the last snapshot_captured payload into report-stamp fields.

    Headless runs never emit snapshot_captured, so an empty list yields None
    and the report records nulls — stamps are harvested, never faked.
    """
    if not payloads:
        return None
    payload = payloads[-1]
    window = payload.get("window")
    if not (isinstance(window, (list, tuple)) and len(window) == 2):
        window = None
    return {
        "godot_version": payload.get("godot_version"),
        "window": window,
        "renderer": payload.get("renderer"),
    }


def clean_line(line: str) -> str:
    return _ANSI_RE.sub("", line).strip()


def new_result(scenario: str, transport: str) -> dict[str, Any]:
    return {
        "scenario": scenario,
        "ok": False,
        "transport": transport,
        "duration_s": 0.0,
        "events_seen": [],
        "missing_all": [],
        "missing_any": [],
        "exceptions": [],
        "warnings": [],
        "passed_payload": None,
    }


def requirements_met(scenario: str, events: set[str]) -> bool:
    requirements = SCENARIO_REQUIREMENTS[scenario]
    return all(event in events for event in requirements["all"]) and all(
        any(event in events for event in group) for group in requirements["any"]
    )


def finalize(
    result: dict[str, Any],
    collector: TraceCollector,
    exceptions: list[str],
    started: float,
) -> dict[str, Any]:
    requirements = SCENARIO_REQUIREMENTS[result["scenario"]]
    result["events_seen"] = sorted(collector.events)
    result["missing_all"] = sorted(event for event in requirements["all"] if event not in collector.events)
    result["missing_any"] = [
        group for group in requirements["any"] if not any(event in collector.events for event in group)
    ]
    result["exceptions"] = exceptions
    result["warnings"] = collector.warnings
    result["passed_payload"] = collector.passed_payload
    result["stamp"] = project_stamp(collector.snapshot_payloads)
    result["duration_s"] = round(time.monotonic() - started, 2)
    result["ok"] = not exceptions and not result["missing_all"] and not result["missing_any"]
    return result


def run_scenario_dap(project: Path, scenario: str, timeout: float, host: str, port: int) -> dict[str, Any]:
    started = time.monotonic()
    result = new_result(scenario, "dap")
    collector = TraceCollector()
    exceptions: list[str] = []
    request_path = smoketest.write_smoke_request(project, scenario)
    try:
        try:
            sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT_S)
        except OSError as exc:
            exceptions.append(f"Could not connect to the DAP endpoint at {host}:{port}: {exc}")
            return finalize(result, collector, exceptions, started)
        with sock:
            seq = 1
            handshake = [
                (
                    "initialize",
                    {
                        "clientID": "playtest-runner",
                        "clientName": "playtest-runner",
                        "adapterID": "godot",
                        "pathFormat": "path",
                        "linesStartAt1": True,
                        "columnsStartAt1": True,
                        "supportsVariableType": True,
                        "supportsVariablePaging": True,
                        "supportsRunInTerminalRequest": False,
                    },
                ),
                ("launch", {"project": str(project), "scene": DEFAULT_SCENE}),
                ("configurationDone", {}),
            ]
            try:
                for command, arguments in handshake:
                    smoketest.send(sock, {"seq": seq, "type": "request", "command": command, "arguments": arguments})
                    seq += 1
            except OSError as exc:
                exceptions.append(f"DAP handshake failed (editor busy or refusing): {exc}")
                return finalize(result, collector, exceptions, started)

            got_any_message = False
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                try:
                    messages = smoketest.recv_messages(sock, timeout=0.6)
                except OSError as exc:
                    exceptions.append(f"DAP connection dropped mid-run: {exc}")
                    break
                for msg in messages:
                    got_any_message = True
                    if msg.get("type") != "event":
                        continue
                    event = msg.get("event")
                    body = msg.get("body", {})
                    if not isinstance(body, dict):
                        body = {}
                    if event == "output":
                        for trace in smoketest.parse_trace_lines(str(body.get("output", ""))):
                            collector.add(trace)
                    elif event == "stopped" and body.get("reason") == "exception":
                        exceptions.append(str(body.get("text", "Unknown debugger exception")))
                    elif event == "terminated":
                        end = min(end, time.monotonic() + 0.2)
                now = time.monotonic()
                if not got_any_message and now - started > NO_RESPONSE_GRACE_S:
                    exceptions.append(
                        "DAP endpoint accepted the connection but never responded "
                        "(editor busy or already debugging another session)."
                    )
                    break
                if requirements_met(scenario, collector.events):
                    end = min(end, now + SETTLE_S)
                time.sleep(0.05)
            try:
                smoketest.send(
                    sock,
                    {
                        "seq": seq,
                        "type": "request",
                        "command": "disconnect",
                        "arguments": {"terminateDebuggee": True},
                    },
                )
            except OSError:
                pass
    finally:
        if request_path.exists():
            request_path.unlink()
    return finalize(result, collector, exceptions, started)


def headless_quit_after_frames(timeout: float) -> int:
    # Godot's --quit-after counts main-loop iterations, not wall time, and a
    # headless loop is uncapped, so this is only a generous backstop. The real
    # bound is the wall-clock deadline in run_scenario_headless, which also
    # stops the process early once the required events have been observed.
    return max(600, int(timeout * 1000))


def _drain_stdout(stream: Any, out_queue: "queue.Queue[str]") -> None:
    try:
        for line in iter(stream.readline, ""):
            out_queue.put(line)
    except (ValueError, OSError):
        pass


def _drain_stderr(stream: Any, out_lines: list[str]) -> None:
    try:
        for line in iter(stream.readline, ""):
            out_lines.append(line)
    except (ValueError, OSError):
        pass


def handle_output_line(line: str, collector: TraceCollector, exceptions: list[str]) -> None:
    cleaned = clean_line(line)
    if not cleaned:
        return
    if any(marker in cleaned for marker in ERROR_MARKERS):
        exceptions.append(cleaned)
    for trace in smoketest.parse_trace_lines(cleaned):
        collector.add(trace)


def _stop_process(proc: subprocess.Popen, sig: str) -> None:
    try:
        if sig == "kill":
            proc.kill()
        else:
            proc.terminate()
    except OSError:
        pass


def run_scenario_headless(project: Path, scenario: str, timeout: float, godot_bin: str, windowed: bool = False) -> dict[str, Any]:
    started = time.monotonic()
    result = new_result(scenario, "windowed" if windowed else "headless")
    collector = TraceCollector()
    exceptions: list[str] = []
    # write_smoke_request truncates, so a leftover scenario.json from a crashed
    # run is overwritten rather than merged.
    request_path = smoketest.write_smoke_request(project, scenario)
    if windowed:
        # No --headless/--quit-after: the scenario quits the app itself; the
        # wall-clock deadline below is the backstop.
        cmd = [godot_bin, "--path", str(project)]
    else:
        cmd = [godot_bin, "--headless", "--path", str(project), "--quit-after", str(headless_quit_after_frames(timeout))]
    try:
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(project),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                bufsize=1,
            )
        except OSError as exc:
            exceptions.append(f"Could not launch the Godot binary at {godot_bin}: {exc}")
            return finalize(result, collector, exceptions, started)

        stdout_lines: "queue.Queue[str]" = queue.Queue()
        stderr_lines: list[str] = []
        threads = [
            threading.Thread(target=_drain_stdout, args=(proc.stdout, stdout_lines), daemon=True),
            threading.Thread(target=_drain_stderr, args=(proc.stderr, stderr_lines), daemon=True),
        ]
        for thread in threads:
            thread.start()

        def drain_stdout() -> None:
            while True:
                try:
                    handle_output_line(stdout_lines.get_nowait(), collector, exceptions)
                except queue.Empty:
                    break

        settle_at: float | None = None
        timed_out = False
        deadline = started + timeout
        while True:
            drain_stdout()
            now = time.monotonic()
            if requirements_met(scenario, collector.events):
                if settle_at is None:
                    settle_at = now + SETTLE_S
                elif now >= settle_at:
                    _stop_process(proc, "terminate")
                    break
            if proc.poll() is not None:
                break
            if now >= deadline:
                timed_out = True
                _stop_process(proc, "kill")
                break
            time.sleep(0.05)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _stop_process(proc, "kill")
            proc.wait()
        for thread in threads:
            thread.join(timeout=2)
        drain_stdout()
        for line in stderr_lines:
            cleaned = clean_line(line)
            if any(marker in cleaned for marker in ERROR_MARKERS):
                exceptions.append(cleaned)
        if timed_out:
            exceptions.append(f"Headless run exceeded the {timeout:.0f}s wall-clock budget.")
    finally:
        if request_path.exists():
            request_path.unlink()
    return finalize(result, collector, exceptions, started)


def dap_endpoint_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return True
    except OSError:
        return False


def select_transport(host: str, port: int) -> str:
    if force_headless():
        return "headless"
    return "dap" if dap_endpoint_open(host, port) else "headless"


def skip_windowed_scenario(scenario: str) -> dict[str, Any]:
    """Transport honesty: a windowed-only scenario asked to run headless is a
    skip-with-reason (ok=True), never a failure for missing pass events."""
    result = new_result(scenario, "skipped-headless")
    result["ok"] = True
    result["skipped_reason"] = smoketest.windowed_skip_reason()
    return result


def git_head_sha(project: Path) -> str | None:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(project),
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = proc.stdout.strip()
    return sha if proc.returncode == 0 and sha else None


def first_stamp(results: list[dict[str, Any]]) -> dict[str, Any] | None:
    for result in results:
        if result.get("stamp"):
            return result["stamp"]
    return None


def sweep_stale_results(project: Path, run_start: float) -> int:
    """Delete result-*.json older than this run so stale reds cannot
    contradict the fresh report."""
    smoke_dir = project / ".godot-smoke"
    if not smoke_dir.is_dir():
        return 0
    removed = 0
    for path in smoke_dir.glob("result-*.json"):
        try:
            if path.stat().st_mtime < run_start:
                path.unlink()
                removed += 1
        except OSError:
            pass
    return removed


def print_row(result: dict[str, Any]) -> None:
    if result["transport"] == "skipped-headless":
        status = "SKIP"
    else:
        status = "PASS" if result["ok"] else "FAIL"
    print(
        f"{result['scenario']:<18} {result['transport']:<16} {result['duration_s']:>7.2f} "
        f"{status:<6} {len(result['events_seen']):>6} "
        f"{len(result['warnings']):>5} {len(result['exceptions']):>4}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--include-smoke", action="store_true", help="also run the 7 smoke scenarios")
    parser.add_argument(
        "--scenario",
        action="append",
        choices=sorted(SCENARIO_REQUIREMENTS),
        metavar="NAME",
        help="run only the given scenario(s); repeatable, overrides the default playtest set",
    )
    parser.add_argument("--project", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="per-scenario wall-clock budget in seconds")
    parser.add_argument("--report", default=None, help="report path (default: .godot-smoke/playtest-report.json)")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN))
    args = parser.parse_args()

    project = Path(args.project).expanduser().resolve()
    if args.scenario:
        scenarios = list(dict.fromkeys(args.scenario))
    else:
        scenarios = list(PLAYTEST_SCENARIOS)
        if args.include_smoke:
            scenarios += SMOKE_SCENARIOS
    report_path = Path(args.report).expanduser() if args.report else project / ".godot-smoke" / "playtest-report.json"

    run_start = time.time()

    transport = select_transport(args.host, args.port)
    # The Godot binary is only needed when at least one selected scenario will
    # actually launch it. An all-transport-skip selection (every scenario
    # windowed-only under PLAYTEST_FORCE_HEADLESS) resolves to
    # skip_windowed_scenario() in the loop and never launches Godot, so it must
    # stay exit 0 per the transport-honesty contract rather than fail on a
    # missing binary.
    needs_binary = transport == "headless" and any(
        not (scenario in WINDOWED_ONLY_SCENARIOS and force_headless())
        for scenario in scenarios
    )
    if needs_binary and not Path(args.godot_bin).exists():
        print(f"error: headless transport selected but the Godot binary is missing: {args.godot_bin}", file=sys.stderr)
        return 2

    # Sweep stale results only after the run has confirmed it will proceed (the
    # missing-binary gate above is the sole pre-loop abort), so an aborting run
    # never deletes prior result-*.json evidence without writing a fresh report.
    swept = sweep_stale_results(project, run_start)

    forced = " (forced by $%s)" % FORCE_HEADLESS_ENV if transport == "headless" and force_headless() else ""
    print(f"project:   {project}")
    print(f"transport: {transport}{forced}")
    print(f"scenarios: {', '.join(scenarios)}")
    if swept:
        print(f"swept:     {swept} stale result-*.json")
    print(f"{'scenario':<18} {'transport':<16} {'dur_s':>7} {'result':<6} {'events':>6} {'warn':>5} {'exc':>4}")

    results: list[dict[str, Any]] = []
    for scenario in scenarios:
        if scenario in WINDOWED_ONLY_SCENARIOS and force_headless():
            result = skip_windowed_scenario(scenario)
        elif scenario in WINDOWED_SUBPROCESS_SCENARIOS and not force_headless():
            result = run_scenario_headless(project, scenario, args.timeout, args.godot_bin, windowed=True)
        elif transport == "dap":
            result = run_scenario_dap(project, scenario, args.timeout, args.host, args.port)
        else:
            result = run_scenario_headless(project, scenario, args.timeout, args.godot_bin)
        results.append(result)
        print_row(result)

    failed = [result for result in results if not result["ok"]]
    if failed:
        print("\nfailures:")
        for result in failed:
            name = result["scenario"]
            if result["missing_all"]:
                print(f"  {name}: missing required events: {', '.join(result['missing_all'])}")
            for group in result["missing_any"]:
                print(f"  {name}: missing alternative group: {' | '.join(group)}")
            for exception in result["exceptions"][:5]:
                print(f"  {name}: exception: {exception}")

    skipped = sum(1 for result in results if result["transport"] == "skipped-headless")
    summary = {
        "ok": not failed,
        "total": len(results),
        "passed": len(results) - len(failed),
        "failed": len(failed),
        "skipped_headless": skipped,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    # Report stamps: head_sha always from git; godot_version/window/renderer
    # harvested from snapshot_captured traces — null when no windowed capture
    # ran (e.g. headless-only runs), never faked. head_sha is the freshness
    # hook a later verify_all.py can refuse stale reports with.
    stamp = first_stamp(results) or {}
    report = {
        "head_sha": git_head_sha(project),
        "godot_version": stamp.get("godot_version"),
        "window": stamp.get("window"),
        "renderer": stamp.get("renderer"),
        "summary": summary,
        "scenarios": results,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    if skipped:
        line = f"\nsummary: {summary['passed']}/{summary['total']} ({skipped} skipped-headless)"
        if summary["failed"]:
            line += f", {summary['failed']} failed"
        print(line)
    else:
        print(f"\nsummary: {summary['passed']}/{summary['total']} passed, {summary['failed']} failed")
    print(f"stamps:  head={report['head_sha'] or 'unknown'} godot={report['godot_version'] or 'unknown'} "
          f"window={report['window']} renderer={report['renderer'] or 'unknown'}")
    print(f"report:  {report_path}")
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
