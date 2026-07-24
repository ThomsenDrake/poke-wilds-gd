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

Concurrency: run this harness (and therefore verify_all.py, which orchestrates
it) with EXACTLY ONE writer against a given project at a time. Concurrent runs
collide on shared state — the per-scenario request file the app reads and
deletes at boot (res://.godot-smoke/scenario.json) and the appended trace log
(user://logs/agent_trace.jsonl that several scenarios assert against) — so a
second harness can consume another writer's request and produce intermittent
scenario failures that pass in isolation. Serialize pre-push gate runs.
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
# Both sweep scenario names. The compare-side post-steps (region gate,
# contrast/CVD, vision review) guard on "visual_sweep" alone — they are
# meaningless right after a baseline rewrite. The anchor gate is the ONE
# post-step that MUST also run for "visual_sweep_update": policing that rewrite
# is its entire reason to exist (the update-mode baseline-regeneration
# refusal), so both its snapshot (prepare_anchor_gate) and its verdict
# (apply_anchor_gate) cover both names.
VISUAL_SWEEP_SCENARIOS = ("visual_sweep", "visual_sweep_update")
FORCE_HEADLESS_ENV = smoketest.FORCE_HEADLESS_ENV
force_headless = smoketest.force_headless

PLAYTEST_SCENARIOS = ["playtest_journey", "playtest_soak", "nav_audit", "texture_audit", "data_audit", "layout_audit", "world_consistency_audit", "ui_render_audit", "battle_anim", "display_matrix", "harvest_flow", "placement_flow", "camp_survival", "craft_flow", "night_cycle", "time_evolution"]
SMOKE_SCENARIOS = [
    "boot",
    "overworld_step",
    "menu_save",
    "wild_battle",
    "biome_probe",
    "biome_traverse",
    "field_move",
    "save_migration",
    "visual_sweep",
    "visual_sweep_camping",
]
DEFAULT_SCENE = "res://scenes/app/Main.tscn"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 6006
DEFAULT_TIMEOUT = 90.0
DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
# Single-sourced in the sibling smoke harness so the DAP and headless/windowed
# transports treat the identical line set as an exception — including the
# "ERROR: " prefix push_error prints (the silent-fail class behind the
# nav_audit false-red; see miss-postmortems.json miss-002).
ERROR_MARKERS = smoketest.ERROR_MARKERS
CONNECT_TIMEOUT_S = 3.0
NO_RESPONSE_GRACE_S = 10.0
SETTLE_S = 0.5
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


class TraceCollector:
    """Accumulates events, warnings, the *_passed payload, the *_failed
    reasons (symmetric failure contract), and snapshot stamps."""

    def __init__(self) -> None:
        self.events: set[str] = set()
        self.warnings: list[dict[str, Any]] = []
        self.passed_payload: Any = None
        self.failed_events: list[dict[str, Any]] = []
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
        entry = smoketest.failed_event_entry(trace)
        if entry is not None:
            self.failed_events.append(entry)


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
    result["failed_events"] = collector.failed_events
    result["stamp"] = project_stamp(collector.snapshot_payloads)
    result["duration_s"] = round(time.monotonic() - started, 2)
    # Total-run contract: a red ALWAYS names its cause — an exception (now
    # including captured push_error "ERROR: " lines) OR a missing required
    # event OR a structured <scenario>_failed trace carrying the reasons.
    result["ok"] = (
        not exceptions
        and not result["missing_all"]
        and not result["missing_any"]
        and not collector.failed_events
    )
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


_REGION_DIFF_PATH = Path(__file__).resolve().with_name("visual_region_diff.py")
_region_diff_module: Any = None


def _load_region_diff() -> Any:
    """Lazy importlib load of the region diff (same pattern as the smoke harness
    import above); loaded once, only when a visual_sweep compare actually runs."""
    global _region_diff_module
    if _region_diff_module is None:
        spec = importlib.util.spec_from_file_location("visual_region_diff", _REGION_DIFF_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load visual_region_diff from {_REGION_DIFF_PATH}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _region_diff_module = module
    return _region_diff_module


def apply_region_gate(project: Path, result: dict[str, Any]) -> None:
    """Runner-recorded explainable region gate for the visual_sweep scenario.

    visual_diff.py's in-engine global gate (0.5% / tolerance 8, exit 0/1/2) stays
    the untouched backstop; this post-step layers the per-region verdict on top,
    joining committed baseline sidecars against the fresh shots. Invocation-point
    decision: the verdict fields are recorded into the scenario entry of
    playtest-report.json -- NEVER the JSONL trace, because the engine never runs
    the region diff. Red-tier region failures flip result["ok"] so the run exits
    nonzero; non-red drift lands in region_quarantine (kind region_drift, or
    sidecar_absent when a baseline sidecar is locally missing and the shot's gate
    degrades to the global backstop) without
    failing the run. Skipped on transport-skip and in update mode (baselines were
    just rewritten, so the compare is trivially green).
    """
    if result.get("scenario") != "visual_sweep":
        return
    if result.get("transport") == "skipped-headless":
        return  # transport honesty: nothing was captured to gate
    payload = result.get("passed_payload")
    if not isinstance(payload, dict):
        payload = {}
    if payload.get("mode") == "update" or payload.get("auto_update"):
        return
    try:
        verdict = _load_region_diff().run_region_diff(
            project / ".godot-smoke" / "shots",
            project / "docs" / "generated" / "visual-baselines",
            project / ".godot-smoke" / "region-diff",
        )
    except Exception as exc:  # a broken region tool must not silently pass
        result.setdefault("exceptions", []).append(f"region diff failed: {exc}")
        result["ok"] = False
        return
    result["region_failures"] = verdict["region_failures"]
    result["region_quarantine"] = verdict["quarantine"]
    result["clusters_explained"] = verdict["clusters_explained"]
    result["clusters_unexplained"] = verdict["clusters_unexplained"]
    result["region_artifacts"] = verdict["artifacts"]
    result["region_global_backstop"] = verdict["global_backstop"]
    # sidecar_paths arrive on the in-engine visual_sweep_passed payload; echo them
    # onto the scenario entry so the report's region section is self-describing.
    result["sidecar_paths"] = payload.get("sidecar_paths", [])
    if verdict["errors"]:
        result.setdefault("exceptions", []).extend(f"region diff: {e}" for e in verdict["errors"])
        result["ok"] = False
    if verdict["region_failures"]:
        result["ok"] = False


_TOOL_MODULES: dict[str, Any] = {}


def _load_tool_module(name: str) -> Any:
    """Lazy importlib load of a sibling tool, cached (same pattern as
    _load_region_diff); loaded only when the visual_sweep post-step runs."""
    if name not in _TOOL_MODULES:
        path = Path(__file__).resolve().with_name(f"{name}.py")
        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load {name} from {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _TOOL_MODULES[name] = module
    return _TOOL_MODULES[name]


# Slice-4 landing: the WCAG contrast check is deterministic (3-run proof on
# file) but its findings ship quarantine-tier; flip this True once the clean-run
# history graduates contrast_low to coded red. cvd_collapse NEVER graduates.
CONTRAST_GRADUATED = False

# Art-anchor live-respect (compare mode) ships quarantine-tier first; flip True
# once an anchor has the graduation proof (byte-stable findings across runs +
# clean streak + a recorded seeded plant — the exit4_proof pattern). The
# baseline-REGENERATION refusal in update mode is ALWAYS armed regardless of this
# flag, because a wrong baseline frozen green is worse than a missing baseline —
# that half is what structurally closes the 3-days-green HP-bar hole. The HP
# tracks (battle/enemy_hp_track, battle/player_hp_track) are the first candidates
# to graduate.
ANCHOR_DRIFT_GRADUATED = False


def apply_contrast_cvd(project: Path, result: dict[str, Any]) -> None:
    """Runner-recorded WCAG contrast + CVD evidence for the visual_sweep scenario.

    Mirrors apply_region_gate's invocation-point decision: verdicts are recorded
    onto the scenario entry of playtest-report.json -- NEVER the JSONL trace --
    as quarantine-section kinds contrast_low / cvd_collapse. Contrast runs on the
    FRESH shots + fresh sidecar label rects, able to catch text-over-battle-effect
    contrast loss the committed baseline cannot show once a mid-effect shot is
    captured (visual_sweep's current states are static -- none mid-effect); CVD
    simulates the fresh canary palettes plus the hardcoded HP-bar triple. Routing at landing:
    contrast_low flips result['ok'] only when CONTRAST_GRADUATED (not yet);
    cvd_collapse never flips it (accessibility evidence, quarantine-forever).
    Skipped on transport-skip and in update mode (baselines just rewritten).
    """
    if result.get("scenario") != "visual_sweep":
        return
    if result.get("transport") == "skipped-headless":
        return
    payload = result.get("passed_payload")
    if not isinstance(payload, dict):
        payload = {}
    if payload.get("mode") == "update" or payload.get("auto_update"):
        return
    shots_dir = project / ".godot-smoke" / "shots"
    try:
        contrast_verdict = _load_tool_module("contrast_check").run_contrast(shots_dir)
        cvd_verdict = _load_tool_module("cvd_sim").run_cvd(shots_dir)
    except Exception as exc:  # a broken tool must not silently pass
        result.setdefault("exceptions", []).append(f"contrast/cvd check failed: {exc}")
        result["ok"] = False
        return
    result["contrast_findings"] = contrast_verdict["findings"]
    result["contrast_images_checked"] = contrast_verdict.get("images_checked", 0)
    result["cvd_findings"] = cvd_verdict["findings"]
    if contrast_verdict.get("errors"):
        result.setdefault("exceptions", []).extend(f"contrast: {e}" for e in contrast_verdict["errors"])
        result["ok"] = False
    if cvd_verdict.get("errors"):
        result.setdefault("exceptions", []).extend(f"cvd: {e}" for e in cvd_verdict["errors"])
        result["ok"] = False
    if CONTRAST_GRADUATED and result["contrast_findings"]:
        result["ok"] = False


def _record_vision_review(result: dict[str, Any], doc: dict[str, Any], review_path: Path) -> dict[str, Any]:
    """Merge a freshly-written vision-review doc into the scenario entry.

    Every emitted finding becomes a kind=vision_review quarantine entry (it already
    carries its finding_id join key for the Slice-6 graduation ledger); findings are
    report-tier and never flip ok. vision_review_written {path, shots_reviewed,
    shots_changed, findings, grounded, dropped, reviewer} is the Slice-1-plan report
    field: shots_reviewed counts the shots COVERED by the review manifest (every
    baselined shot, changed or not — the manifest is the freshness authority), while
    shots_changed counts the subset whose fresh bytes differed from baseline (the
    shots actually re-reviewed)."""
    grounding = doc.get("grounding") if isinstance(doc.get("grounding"), dict) else {}
    reviewer = doc.get("reviewer") if isinstance(doc.get("reviewer"), dict) else {}
    manifest = doc.get("manifest") if isinstance(doc.get("manifest"), dict) else {}
    covered = manifest.get("shots_covered") or []
    covered_list = covered if isinstance(covered, list) else []
    quarantine: list[dict[str, Any]] = []
    for shot_entry in doc.get("shots", []) or []:
        if not isinstance(shot_entry, dict):
            continue
        for finding in shot_entry.get("findings", []) or []:
            if isinstance(finding, dict):
                quarantine.append({**finding, "kind": "vision_review"})
    written = {
        "path": str(review_path),
        "shots_reviewed": len(covered_list),
        "shots_changed": sum(1 for e in covered_list if isinstance(e, dict) and e.get("changed")),
        "findings": int(grounding.get("emitted", 0) or 0),
        "grounded": int(grounding.get("grounded", 0) or 0),
        "dropped": int(grounding.get("dropped", 0) or 0),
        "reviewer": reviewer.get("kind"),
    }
    result["vision_review_written"] = written
    result["vision_review_quarantine"] = quarantine
    notes = list(doc.get("warnings", []) or []) + list(reviewer.get("notes", []) or [])
    if notes:
        result["vision_review_warnings"] = notes
    return written


def apply_vision_review(project: Path, result: dict[str, Any]) -> None:
    """Runner-recorded Lane-4 vision review for the visual_sweep scenario.

    Mirrors apply_region_gate/apply_contrast_cvd's invocation-point decision:
    verdicts are recorded onto the scenario entry of playtest-report.json -- NEVER
    the JSONL trace -- as a quarantine-section kind vision_review (report-tier,
    never flips result['ok']; Lane 4 is quarantine-tier). The post-step regenerates
    .godot-smoke/vision-review.json on EVERY visual_sweep compare run (even 0 changed
    shots -- full manifest, zero findings), so any sweep whose shots change has a
    current file and the manifest is the complete freshness authority. The default
    reviewer is deterministic (no model); the OPT-IN model lane rides the
    VISION_REVIEWER_CMD env var (e.g. "python3 tools/vlm_reviewer.py"), passed
    through to tools/vision_review.py's --reviewer-cmd plugin socket. Default
    unset => the deterministic lane; CI NEVER sets it. The plugin owns its own
    degrade (composite: always runs the deterministic pass, adds the model only
    when POSITIVELY available), so an absent model records a degrade and exits 0
    — never a silent fallback, never a red run. Only a tool ERROR (bad PNG
    decode, unwritable output, broken plugin) fails red via the exception path
    (fail-closed); dropped/ungrounded findings are counted, never errors. Skipped
    on transport-skip and in update mode; a
    transport-skipped run that leaves a stale review file on disk REFUSES it (warn,
    not recorded, never red). It runs after apply_region_gate so region-diff's
    clusters.json exists; if that step erred, vision_review degrades to
    sidecar-delta-only findings with a recorded warning rather than crashing."""
    if result.get("scenario") != "visual_sweep":
        return
    shots_dir = project / ".godot-smoke" / "shots"
    baseline_dir = project / "docs" / "generated" / "visual-baselines"
    output_dir = project / ".godot-smoke"
    review_path = output_dir / "vision-review.json"
    if result.get("transport") == "skipped-headless":
        # Transport honesty: nothing was captured, so no review is attempted. Record
        # null so the report is explicit that no review was written (the skip reason
        # is already on the scenario entry); then, if a previous run left a review
        # file that no longer matches the shots on disk, refuse it (warn only, never
        # red) so a later verifier cannot trust a stale review. An unreadable/
        # unverifiable file is treated as stale.
        result["vision_review_written"] = None
        if review_path.exists():
            stale = True
            try:
                existing = json.loads(review_path.read_text(encoding="utf-8"))
                stale = not _load_tool_module("vision_review").review_is_fresh(existing, shots_dir, baseline_dir)
            except Exception:
                stale = True
            if stale:
                print("  visual_sweep: refusing stale vision-review.json (transport-skipped; not recorded)")
        return
    payload = result.get("passed_payload")
    if not isinstance(payload, dict):
        payload = {}
    if payload.get("mode") == "update" or payload.get("auto_update"):
        result["vision_review_written"] = None  # baselines just rewritten; compare trivially green
        return
    try:
        vision_review = _load_tool_module("vision_review")
        # OPT-IN model lane: VISION_REVIEWER_CMD wires a --reviewer-cmd plugin
        # (e.g. "python3 tools/vlm_reviewer.py") into this post-step. Default
        # unset => the deterministic default reviewer; CI NEVER sets it. The
        # plugin owns its degrade (composite: the deterministic pass always
        # runs, the model only when positively available), so an absent model
        # is a RECORDED degrade with exit 0, never a silent fallback and never
        # a red run; a broken plugin stays fail-closed via the exception path.
        reviewer_cmd = os.environ.get("VISION_REVIEWER_CMD") or None
        doc = vision_review.run_vision_review(
            shots_dir, baseline_dir, output_dir,
            clusters_path=output_dir / "region-diff" / "clusters.json",
            reviewer_cmd=reviewer_cmd)
    except Exception as exc:  # a broken review tool must not silently pass
        result.setdefault("exceptions", []).append(f"vision review failed: {exc}")
        result["ok"] = False
        return
    # Defense in depth: the file was just regenerated, so it must be fresh; a
    # mismatch here indicates a broken manifest. Refuse (warn, not recorded), never
    # red -- staleness is quarantine-tier, the next sweep regenerates.
    if not isinstance(doc, dict) or not vision_review.review_is_fresh(doc, shots_dir, baseline_dir):
        print("  visual_sweep: refusing vision-review.json (manifest does not match current shots; not recorded)")
        return
    written = _record_vision_review(result, doc, review_path)
    print(f"  visual_sweep: vision-review {written['findings']} finding(s) "
          f"({written['grounded']} grounded, {written['dropped']} dropped), "
          f"{written['shots_changed']} changed of {written['shots_reviewed']} covered shot(s), "
          f"reviewer={written['reviewer']}")


def _baseline_dir(project: Path) -> Path:
    return project / "docs" / "generated" / "visual-baselines"


def prepare_anchor_gate(project: Path, scenario: str) -> dict[str, bytes]:
    """Snapshot the committed baseline bytes BEFORE a visual_sweep run so the
    baseline-regeneration refusal gate (apply_anchor_gate) can restore them if an
    anchored element drifts. Called in the scenario loop ahead of dispatch --
    post-steps run AFTER the sweep rewrites baselines, so the prior bytes must be
    captured here. Returns {} for any non-sweep scenario (nothing to police).
    Covers BOTH sweep names — the snapshot must exist for visual_sweep_update,
    the scenario that actually rewrites baselines (an empty snapshot would make
    a refusal unlink every baseline and restore nothing). The snapshot is the
    whole baseline dir (PNG + sidecar), so a refusal reverts the update
    completely -- a wrong baseline is worse than a missing one.
    """
    if scenario not in VISUAL_SWEEP_SCENARIOS:
        return {}
    baseline_dir = _baseline_dir(project)
    if not baseline_dir.is_dir():
        return {}
    snapshot: dict[str, bytes] = {}
    for path in sorted(baseline_dir.iterdir()):
        if path.is_file():
            try:
                snapshot[path.name] = path.read_bytes()
            except OSError:
                pass
    return snapshot


def _anchor_sidecar_violations(checker, sidecar_dir: Path, project: Path) -> tuple[list[dict], list[dict]]:
    """Run live-respect across every sidecar in a dir. Returns (violations,
    unverifiable) aggregated; each carries the shot name."""
    violations: list[dict] = []
    unverifiable: list[dict] = []
    if not sidecar_dir.is_dir():
        return violations, unverifiable
    for sidecar_path in sorted(sidecar_dir.glob("*.sidecar.json")):
        try:
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(sidecar, dict):
            continue
        shot = sidecar_path.name[: -len(".png.sidecar.json")]
        v, u = checker.live_violations(sidecar, project)
        for item in v:
            item["shot"] = shot
        for item in u:
            item["shot"] = shot
        violations.extend(v)
        unverifiable.extend(u)
    return violations, unverifiable


def apply_anchor_gate(project: Path, result: dict[str, Any], snapshot: dict[str, bytes]) -> None:
    """Source-art anchor gate for the visual_sweep / visual_sweep_update
    scenarios (spec: docs/product-specs/vision-fidelity.md § Source-art anchor
    registry). The ONLY sweep post-step that ALSO runs in update/auto_update mode
    -- the others skip because baselines were just rewritten; this one exists
    precisely to police that rewrite. Both sweep scenario names are covered
    (VISUAL_SWEEP_SCENARIOS): visual_sweep_update is the scenario that actually
    rewrites baselines, so a guard on "visual_sweep" alone would leave the
    refusal branch unreachable -- the exact hole the gate closes.

    Two tiers, both keyed off the SAME stage-to-stage comparison (a sidecar
    draw_order rect vs the registry stage_rect -- NO stage->display mapping):

      update/auto_update (REFUSAL, blocks baseline regeneration): read each
        JUST-WRITTEN baseline sidecar's anchored draw_order rects; on ANY anchor
        violation, RESTORE the snapshotted prior baseline bytes and fail RED
        ("fix the alignment, not the baseline"). This closes the hole that froze
        the 11px HP-bar defect green for 3+ days: a drifted element can no longer
        be baked into a baseline. Fires regardless of graduation tier.

      compare mode (quarantine, pre-graduation): read the FRESH shots' sidecars
        and record anchor_drift quarantine findings (reported, never failing ok)
        -- the arming path; flips to coded red via the graduation ledger once an
        anchor has a determinism proof + clean streak + seeded plant.

    Anchored nodes the sidecar does not expose (a nested node before
    render_introspection collects it) are recorded UNVERIFIABLE, never silently
    passed. An empty registry is a no-op (the gate arms once >=1 anchor exists).
    """
    if result.get("scenario") not in VISUAL_SWEEP_SCENARIOS:
        return
    if result.get("transport") == "skipped-headless":
        return  # nothing captured to gate
    try:
        checker = _load_tool_module("check_art_anchors")
        geometry = _load_tool_module("art_geometry")
    except Exception as exc:  # a broken anchor tool must not silently pass
        result.setdefault("exceptions", []).append(f"art-anchor gate failed to load: {exc}")
        result["ok"] = False
        return
    registry = geometry.load_registry(project)
    if not registry:
        return  # not armed: no anchors registered yet

    payload = result.get("passed_payload")
    if not isinstance(payload, dict):
        payload = {}
    update_mode = payload.get("mode") == "update" or payload.get("auto_update")

    if update_mode:
        # The baselines were JUST rewritten (fresh captures copied onto the
        # committed dir). Police that rewrite against the art anchors.
        violations, unverifiable = _anchor_sidecar_violations(checker, _baseline_dir(project), project)
        result["anchor_unverifiable"] = unverifiable
        if violations:
            # RESTORE the prior baseline bytes so the tree is never left with a
            # drifted baseline on disk (the exact 3-days-green fossilization).
            baseline_dir = _baseline_dir(project)
            restored = 0
            try:
                for current in sorted(baseline_dir.iterdir()):
                    if current.is_file() and current.name not in snapshot:
                        current.unlink()  # file the update added; remove to revert
                for name, data in snapshot.items():
                    (baseline_dir / name).write_bytes(data)
                    restored += 1
            except OSError as exc:
                result.setdefault("exceptions", []).append(f"anchor gate: baseline restore failed: {exc}")
            result["anchor_refusals"] = violations
            result["anchor_restored_files"] = restored
            for item in violations:
                print(f"  visual_sweep: baseline regeneration REFUSED — anchor {item['id']} ({item['node']}): "
                      f"{item['shot']} live {item['live_rect']} violates art anchor {item['stage_rect']} "
                      f"(tol {item['tol_px']}px). Restored {restored} prior baseline file(s); "
                      f"fix the alignment, not the baseline.")
            result["ok"] = False
        else:
            result["anchor_gate"] = {"mode": "update", "violations": 0,
                                     "unverifiable": len(unverifiable)}
        return

    # compare mode: quarantine anchor_drift over the FRESH shots (never flips ok
    # pre-graduation; the baseline-refusal above is the hard, always-armed half).
    violations, unverifiable = _anchor_sidecar_violations(
        checker, project / ".godot-smoke" / "shots", project)
    result["anchor_unverifiable"] = unverifiable
    if violations:
        if ANCHOR_DRIFT_GRADUATED:
            result["anchor_drift_failures"] = violations
            result["ok"] = False  # graduated: anchor drift is coded red
        quarantine = result.setdefault("anchor_drift_quarantine", [])
        for item in violations:
            quarantine.append({"kind": "anchor_drift", "shot": item["shot"],
                               "anchor_id": item["id"], "node": item["node"],
                               "stage_rect": item["stage_rect"], "live_rect": item["live_rect"],
                               "detail": f"{item['node']} live {item['live_rect']} off art anchor "
                                         f"{item['stage_rect']} (tol {item['tol_px']}px)"})
        for item in violations:
            print(f"  visual_sweep: anchor_drift [quarantine] {item['shot']} {item['node']}: "
                  f"live {item['live_rect']} vs art anchor {item['stage_rect']}")


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
        # Snapshot committed baselines BEFORE the sweep so apply_anchor_gate can
        # restore them if a regenerated baseline freezes an anchored misalignment
        # (the ONLY post-step that also runs in update mode). {} for other shots.
        anchor_snapshot = prepare_anchor_gate(project, scenario)
        if scenario in WINDOWED_ONLY_SCENARIOS and force_headless():
            result = skip_windowed_scenario(scenario)
        elif scenario in WINDOWED_SUBPROCESS_SCENARIOS and not force_headless():
            result = run_scenario_headless(project, scenario, args.timeout, args.godot_bin, windowed=True)
        elif transport == "dap":
            result = run_scenario_dap(project, scenario, args.timeout, args.host, args.port)
        else:
            result = run_scenario_headless(project, scenario, args.timeout, args.godot_bin)
        results.append(result)
        apply_region_gate(project, result)
        apply_contrast_cvd(project, result)
        apply_vision_review(project, result)
        apply_anchor_gate(project, result, anchor_snapshot)
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
            for failure in result.get("failed_events", [])[:5]:
                print(f"  {name}: failed event {failure['event']}: {failure['payload']}")
            for failure in result.get("region_failures", [])[:8]:
                print(f"  {name}: region [{failure['kind']}] {failure['shot']}: {failure['detail']}")
            for finding in result.get("region_quarantine", [])[:4]:
                print(f"  {name}: quarantine [{finding['kind']}] {finding['shot']}: {finding['detail']}")
            for finding in result.get("contrast_findings", [])[:4]:
                print(f"  {name}: contrast_low {finding.get('shot', '')}: "
                      f"\"{finding.get('label_text', '')}\" ratio {finding.get('ratio')} < {finding.get('need')}")
            for finding in result.get("cvd_findings", [])[:4]:
                print(f"  {name}: cvd_collapse [{finding.get('deficiency')}] {finding.get('source')}: {finding.get('pair')}")
            for finding in result.get("vision_review_quarantine", [])[:4]:
                print(f"  {name}: vision_review [{finding.get('class', '')}] {finding.get('shot', '')} "
                      f"{finding.get('region_id', '')}: {finding.get('note', '')}")
            for refusal in result.get("anchor_refusals", [])[:4]:
                print(f"  {name}: anchor REFUSED {refusal.get('shot', '')} {refusal.get('node', '')}: "
                      f"live {refusal.get('live_rect')} off art anchor {refusal.get('stage_rect')}")
            for finding in result.get("anchor_drift_quarantine", [])[:4]:
                print(f"  {name}: anchor_drift [quarantine] {finding.get('shot', '')} "
                      f"{finding.get('node', '')}: {finding.get('detail', '')}")
            if result.get("clusters_unexplained"):
                print(f"  {name}: {result['clusters_unexplained']} unexplained cluster(s) "
                      "(see region-diff/clusters.json — guards false closure)")

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
