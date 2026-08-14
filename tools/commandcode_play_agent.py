#!/usr/bin/env python3
"""Command Code play agent: second cmd invocation that drives the live game.

Transport: the WINDOWED-SUBPROCESS pattern the repo's playtest harness proves
(run_playtests.run_scenario_headless with windowed=True). The agent writes the
smoke request (smoketest.write_smoke_request -> .godot-smoke/scenario.json =
{"scenario": "play_agent"}), launches `godot --path <project>` WITHOUT
--headless, drains stdout/stderr on threads, and parses trace lines via
smoketest.parse_trace_lines through the run_playtests TraceCollector shape.
ALL driving happens in-engine: scripts/app/play_agent_scenario.gd injects real
input-phase events (SmokeTap.tap / Input.parse_input_event — the same
input_gate/new_game_flow latch the playtests exercise) to run title -> NEW
GAME -> creation (typed seed digits) -> GO -> world spawn, then one held-key
overworld step and the bag snapshot. The scenario quits the app itself via
get_tree().quit(); the wall-clock deadline here is only the backstop.

Save honesty: isolation comes from the scenario running inside the
dispatcher's save backup/restore guard (SmokeScenarioRunner.backup_save /
restore_save in smoke_scenarios.gd) — there is NO --user-dir temp and NO DAP
session, so the agent can never hijack a running editor or strand a temp
profile. Windowed-only like visual_sweep/temporal_flow (real pixels + input
phases), bounded at 180s (< REVIEWER_TIMEOUT 300).

Invocation pattern (mirrors vlm_reviewer lane):

  cmd -p --no-session --permission-mode plan --model gpt-5.6-luna --max-turns 12

Stdin JSON bundle (what the harness ships to the agent):
  {
    window: [w, h] | null,           // launch window from snapshot_captured or CANONICAL
    trace_tail: [ trace, ... ],       // tail of user://logs/agent_trace.jsonl (last ~40)
    available_scenarios: [ string ],  // SCENARIO_REQUIREMENTS keys the harness can dispatch
    prior_findings: [ finding, ... ]  // filtered prior vision-review findings for this window
  }

Stdout JSON (what the agent returns; also persisted as play_report.json):
  {
    steps: [ {action, at_s, ok} ],
    reached_states: [ string ],       // trace states observed: title_shown, creation_confirmed, world_rebuilt, overworld_step, inventory_checked, ...
    stuck_at?: string | null,         // launch_failed | scenario_failed | timeout | runtime_error | missing_events | inventory_missing
    inventory_checks: [ {item_id, have, need, ok} ],
    creation_confirmed?: bool,
    player_step?: {tile: [x,y], steps: int} | null,
    snapshot_captured?: bool
  }

Report file path: .godot-smoke/play_report.json (project-relative; --report
overrides it, and the legacy hyphen alias .godot-smoke/play-report.json is
written ONLY for the default path).

Transport honesty: under PLAYTEST_FORCE_HEADLESS the windowed-only lane is
reported skipped-with-reason (ok=True), never failed — live play needs a real
window and renderer. Trace parsing reuses godot_dap_smoketest primitives and
the run_playtests TraceCollector/drain helpers via the sanctioned importlib
pattern, never forked.

Stdlib-only.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent

DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
CANONICAL_WINDOW = [1152, 648]
PLAY_REPORT = ROOT / ".godot-smoke" / "play_report.json"
PLAY_REPORT_LEGACY = ROOT / ".godot-smoke" / "play-report.json"
REVIEWER_TIMEOUT = 300
PLAY_TIMEOUT = 180  # < REVIEWER_TIMEOUT by construction
WINDOWED_ONLY = True
TRACE_TAIL_LINES = 40
FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"
COMMAND_CODE_MODEL = "gpt-5.6-luna"
SCENARIO = "play_agent"
# Granular witness events the play_agent scenario drives, in drive order
# (boot + splash + title precede the scenario boundary; the rest are earned).
TRACKED_EVENTS = (
    "boot_started", "boot_ready", "splash_shown", "title_shown",
    "title_new_game_chosen", "creation_confirmed", "world_rebuilt",
    "overworld_step", "inventory_checked", "snapshot_captured",
    "play_agent_passed", "play_agent_failed",
)


def force_headless() -> bool:
    return os.environ.get(FORCE_HEADLESS_ENV, "").lower() not in ("", "0", "false", "no", "off")


def windowed_skip_reason() -> str:
    return (
        f"windowed-only play agent skipped under {FORCE_HEADLESS_ENV} "
        "(live play needs a real window and renderer)"
    )


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


smoketest = _load_module("godot_dap_smoketest", TOOLS / "godot_dap_smoketest.py")
playtests = _load_module("run_playtests", TOOLS / "run_playtests.py")
review_context = _load_module("review_context", TOOLS / "review_context.py")
_load_module("cloud_env", TOOLS / "cloud_env.py").load_cloud_env()

# Reuse the trace primitives from the sibling harnesses (single-sourced).
_parse_trace_lines = smoketest.parse_trace_lines


def _project_name(project: Path) -> str | None:
    try:
        text = (project / "project.godot").read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r'config/name\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None


def _user_trace_path(project: Path) -> Path | None:
    """Resolve user://logs/agent_trace.jsonl per OS (mirrors run_playtests._user_save_path)."""
    name = _project_name(project)
    if not name:
        return None
    if sys.platform == "darwin":
        base = Path.home() / "Library/Application Support/Godot/app_userdata"
    elif sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", "")) / "Godot/app_userdata"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "godot/app_userdata"
    return base / name / "logs" / "agent_trace.jsonl"


def _read_window(project: Path, trace_tail: list[dict] | None = None) -> list[int] | None:
    """Report window stamp: last snapshot_captured.window in the trace tail, else
    canonical. (Informational only — the windowed subprocess launches at the
    game's own default window; all baselines share the canonical window, so a
    sidecar fallback could never disagree.)"""
    if trace_tail:
        for rec in reversed(trace_tail):
            if rec.get("event") == "snapshot_captured":
                w = rec.get("payload", {}).get("window")
                if isinstance(w, (list, tuple)) and len(w) == 2:
                    return [int(w[0]), int(w[1])]
    return list(CANONICAL_WINDOW)


def _read_trace_tail(project: Path, lines: int = TRACE_TAIL_LINES) -> list[dict]:
    """Tail of user://logs/agent_trace.jsonl (last `lines` valid JSON lines)."""
    trace_path = _user_trace_path(project)
    if trace_path is None or not trace_path.is_file():
        # fallback: .godot-smoke trace or no tail
        alt = project / ".godot-smoke" / "agent_trace.jsonl"
        trace_path = alt if alt.is_file() else None
        if trace_path is None:
            return []
    try:
        raw = trace_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out: list[dict] = []
    for line in raw[-lines:]:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and "event" in rec:
            out.append(rec)
    return out


def _available_scenarios() -> list[str]:
    return sorted(smoketest.SCENARIO_REQUIREMENTS.keys())


def _prior_findings(project: Path, window: list[int] | None = None) -> list[dict]:
    """Project-wide prior vision-review findings for the planner bundle (the
    bundle is not shot-scoped, so no stem filter). Shares the compact-key shape
    with the review pipeline via review_context.PRIOR_FINDING_KEYS. Best-effort,
    [] when absent."""
    review_path = project / ".godot-smoke" / "vision-review.json"
    try:
        doc = json.loads(review_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(doc, dict):
        return []
    out: list[dict] = []
    for entry in doc.get("shots") or []:
        if not isinstance(entry, dict):
            continue
        for f in entry.get("findings") or []:
            if isinstance(f, dict):
                out.append({k: f[k] for k in review_context.PRIOR_FINDING_KEYS if f.get(k) is not None})
                if len(out) >= 8:
                    return out
    return out


def _command_code_available() -> tuple[bool, str]:
    cmd = shutil.which("cmd")
    if not cmd:
        return False, "cmd CLI not found"
    try:
        proc = subprocess.run([cmd, "--version"], capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"cmd probe failed: {type(exc).__name__}"
    if proc.returncode != 0:
        return False, f"cmd probe exit {proc.returncode}"
    return True, "cmd CLI available"


def _invoke_command_code(bundle: dict, timeout: int = PLAY_TIMEOUT) -> dict | None:
    """Invoke `cmd -p --no-session --permission-mode plan --model gpt-5.6-luna --max-turns 12`
    with the bundle on stdin. Returns parsed JSON or None when unavailable/error.
    ADVISORY ONLY: the plan is appended to the report as cmd_plan_steps; the
    in-engine play_agent scenario always grounds the live run."""
    cmd = shutil.which("cmd")
    if not cmd:
        return None
    prompt = (
        "You are the PokeWilds live-play planner. Read the JSON bundle on stdin "
        "(window, trace_tail, available_scenarios, prior_findings) and return ONLY "
        "a JSON object {steps, reached_states, stuck_at, inventory_checks, "
        "creation_confirmed, player_step, snapshot_captured} planning the drive the "
        "in-engine play_agent scenario performs: title -> NEW GAME -> creation "
        "(typed seed digits) -> GO -> world spawn -> one overworld step -> bag check. "
        "Keep steps bounded; report stuck_at when blocked. No prose outside JSON."
    )
    # Mirror vlm_reviewer _call_command_code shape: prompt as -p arg, bundle on stdin.
    try:
        proc = subprocess.run(
            [cmd, "-p", prompt, "--no-session", "--permission-mode", "plan",
             "--model", COMMAND_CODE_MODEL, "--max-turns", "12",
             "--output-format", "text", "--add-dir", str(ROOT)],
            input=json.dumps(bundle),
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"commandcode_play_agent: cmd invocation failed: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(f"commandcode_play_agent: cmd exit {proc.returncode}: {proc.stderr.strip()[:400]}", file=sys.stderr)
        return None
    text = proc.stdout.strip()
    if not text:
        return None
    # Extract first balanced JSON object (strip fences).
    if text.startswith("```"):
        parts = text.split("```", 2)
        if len(parts) >= 2:
            text = parts[1]
            if text.startswith("json"):
                text = text[4:]
            text = text.rsplit("```", 1)[0]
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        print("commandcode_play_agent: cmd output has no JSON object", file=sys.stderr)
        return None
    try:
        doc = json.loads(text[start:end + 1])
    except ValueError as exc:
        print(f"commandcode_play_agent: cmd JSON parse failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(doc, dict):
        return None
    return doc


# ---------------------------------------------------------------------------
# Live play driver: write the smoke request, launch the WINDOWED subprocess
# (no --headless; the play_agent scenario quits the app itself), drain stdout
# on threads, and match traces against SCENARIO_REQUIREMENTS["play_agent"].
# Save isolation is the in-engine backup/restore guard, not a --user-dir temp.
# ---------------------------------------------------------------------------

def _empty_drive(window: list[int] | None, stuck_at: str, action: str, error: str | None = None) -> dict:
    step: dict = {"action": action, "ok": False}
    if error:
        step["error"] = error
    return {"steps": [step], "reached_states": [], "stuck_at": stuck_at,
            "inventory_checks": [], "creation_confirmed": False,
            "player_step": None, "snapshot_captured": False,
            "duration_s": 0.0, "window": window, "events_seen": []}


def _last_payload(collector, event_name: str) -> dict | None:
    """Newest payload for an event from the captured raw trace stream."""
    for trace in reversed(collector.raw_traces or []):
        if trace.get("event") == event_name:
            payload = trace.get("payload", {})
            return payload if isinstance(payload, dict) else {"value": payload}
    return None


def _drive_live(project: Path, godot_bin: str, timeout: float, bundle: dict) -> dict:
    """Drive the live game via the windowed-subprocess play_agent scenario;
    returns a play_report fragment grounded in observed trace events."""
    window = bundle.get("window") or CANONICAL_WINDOW
    t0 = time.monotonic()
    steps: list[dict] = []
    # write_smoke_request truncates, so a leftover scenario.json from a crashed
    # run is overwritten rather than merged.
    request_path = smoketest.write_smoke_request(project, SCENARIO)
    collector = playtests.TraceCollector(capture_raw=True)
    exceptions: list[str] = []
    proc: subprocess.Popen | None = None
    timed_out = False
    try:
        try:
            # No --headless/--quit-after: the scenario quits the app itself; the
            # wall-clock deadline below is the backstop.
            proc = subprocess.Popen(
                [godot_bin, "--path", str(project)], cwd=str(project),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, errors="replace", bufsize=1,
            )
        except OSError as exc:
            return _empty_drive(window, "launch_failed", "launch", str(exc))
        steps.append({"action": "launch", "ok": True, "at_s": 0.0,
                      "cmd": [godot_bin, "--path", str(project)]})

        stdout_lines: "queue.Queue[str]" = queue.Queue()
        stderr_lines: list[str] = []
        threads = [
            threading.Thread(target=playtests._drain_stdout, args=(proc.stdout, stdout_lines), daemon=True),
            threading.Thread(target=playtests._drain_stderr, args=(proc.stderr, stderr_lines), daemon=True),
        ]
        for thread in threads:
            thread.start()

        seen: set[str] = set()

        def drain_stdout() -> None:
            while True:
                try:
                    line = stdout_lines.get_nowait()
                except queue.Empty:
                    break
                playtests.handle_output_line(line, collector, exceptions)
                for event in sorted(collector.events - seen):
                    if event in TRACKED_EVENTS:
                        steps.append({"action": f"event:{event}", "ok": True,
                                      "at_s": round(time.monotonic() - t0, 2)})
                seen.update(collector.events)

        settle_at: float | None = None
        deadline = t0 + timeout
        while True:
            drain_stdout()
            now = time.monotonic()
            if playtests.requirements_met(SCENARIO, collector.events):
                if settle_at is None:
                    settle_at = now + playtests.SETTLE_S
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
            cleaned = playtests.clean_line(line)
            if any(marker in cleaned for marker in smoketest.ERROR_MARKERS):
                exceptions.append(cleaned)
        if timed_out:
            exceptions.append(f"Windowed run exceeded the {timeout:.0f}s wall-clock budget.")
    finally:
        if request_path.exists():
            request_path.unlink()
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError:
                pass

    events = collector.events
    requirements = smoketest.SCENARIO_REQUIREMENTS[SCENARIO]
    missing_all = sorted(event for event in requirements["all"] if event not in events)
    failed_events = collector.failed_events  # carries play_agent_failed reasons

    # Honest stuck_at: a red ALWAYS names its cause (the run_playtests contract).
    stuck_at: str | None = None
    if failed_events:
        stuck_at = "scenario_failed"
        steps.append({"action": "scenario_failed", "ok": False,
                      "at_s": round(time.monotonic() - t0, 2),
                      "failed_events": failed_events})
    elif timed_out and missing_all:
        stuck_at = "timeout"
    elif exceptions:
        stuck_at = "runtime_error"
    elif missing_all:
        stuck_at = "missing_events"

    creation_confirmed = "creation_confirmed" in events
    snapshot_captured = "snapshot_captured" in events
    player_step: dict | None = None
    step_payload = _last_payload(collector, "overworld_step")
    if step_payload is not None:
        tile = step_payload.get("tile")
        if isinstance(tile, (list, tuple)) and len(tile) == 2:
            player_step = {"tile": [int(tile[0]), int(tile[1])],
                           "steps": int(step_payload.get("steps", 1))}

    # Inventory honesty: the scenario emits inventory_checked pass OR fail, so
    # a run that reached the check always maps to real entries; a run that
    # never produced the event can NOT silently pass the lane.
    inventory_checks: list[dict] = []
    inv_payload = _last_payload(collector, "inventory_checked")
    if inv_payload is not None:
        inv_ok = bool(inv_payload.get("ok", False))
        items = inv_payload.get("items")
        for item in items if isinstance(items, list) else []:
            if isinstance(item, dict):
                inventory_checks.append({"item_id": str(item.get("item_id", "")),
                                         "have": int(item.get("count", 0)),
                                         "need": 0, "ok": inv_ok})
        if not inventory_checks:
            inventory_checks.append({"item_id": "bag_snapshot", "have": 0, "need": 0,
                                     "ok": inv_ok, "note": "bag snapshot empty"})
    else:
        inventory_checks.append({"item_id": "inventory_checked", "have": 0, "need": 0,
                                 "ok": False,
                                 "note": "scenario produced no inventory_checked event"})
        if stuck_at is None:
            stuck_at = "inventory_missing"

    reached_states = [event for event in TRACKED_EVENTS if event in events]
    if player_step is not None:
        reached_states.append("overworld_spawn")
    return {
        "steps": steps,
        "reached_states": reached_states,
        "stuck_at": stuck_at,
        "inventory_checks": inventory_checks,
        "creation_confirmed": creation_confirmed,
        "player_step": player_step,
        "snapshot_captured": snapshot_captured,
        "duration_s": round(time.monotonic() - t0, 2),
        "window": window,
        "events_seen": sorted(events),
        "missing_all": missing_all,
        "exceptions": exceptions,
        "failed_events": failed_events,
    }


def _stop_process(proc: subprocess.Popen, sig: str) -> None:
    try:
        if sig == "kill":
            proc.kill()
        else:
            proc.terminate()
    except OSError:
        pass


def assemble_bundle(project: Path) -> dict:
    """Build the stdin bundle {window, trace_tail, available_scenarios, prior_findings}."""
    trace_tail = _read_trace_tail(project)
    window = _read_window(project, trace_tail)
    return {
        "window": window,
        "trace_tail": trace_tail,
        "available_scenarios": _available_scenarios(),
        "prior_findings": _prior_findings(project, window),
    }


def make_report(bundle: dict, drive: dict, project: Path) -> dict:
    """Merge bundle context into a structured play_report.json body."""
    report = {
        "schema": "play-report/1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "project": str(project),
        "window": bundle.get("window"),
        "trace_tail_lines": len(bundle.get("trace_tail") or []),
        "available_scenarios": bundle.get("available_scenarios") or [],
        "prior_findings_count": len(bundle.get("prior_findings") or []),
        "steps": drive.get("steps") or [],
        "reached_states": drive.get("reached_states") or [],
        "stuck_at": drive.get("stuck_at"),
        "inventory_checks": drive.get("inventory_checks") or [],
        "creation_confirmed": bool(drive.get("creation_confirmed")),
        "player_step": drive.get("player_step"),
        "snapshot_captured": bool(drive.get("snapshot_captured")),
        "duration_s": drive.get("duration_s", 0),
        "events_seen": drive.get("events_seen") or [],
    }
    for key in ("missing_all", "exceptions", "failed_events"):
        if drive.get(key):
            report[key] = drive[key]
    return report


def write_report(report: dict, project: Path, out_path: Path | None = None) -> Path:
    """Write play_report.json. Honors the --report override (threaded through
    as out_path / the PLAY_REPORT global); the legacy hyphen alias is written
    ONLY for the default project-relative path."""
    default_path = project / ".godot-smoke" / "play_report.json"
    out = Path(out_path) if out_path is not None else default_path
    out.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(report, indent=2, sort_keys=True)
    out.write_text(text, encoding="utf-8")
    if out == default_path:
        # Legacy alias for readers expecting the hyphen (default path only).
        try:
            (project / ".godot-smoke" / "play-report.json").write_text(text, encoding="utf-8")
        except OSError:
            pass
    return out


def _skipped_report(project: Path, window: list[int] | None) -> dict:
    """The windowed-only lane under PLAYTEST_FORCE_HEADLESS: skipped-with-reason
    (steps ok=True), never failed — live play needs a real window and renderer.
    Single construction shared by run_play_agent and main so the two headless
    exits can never drift on schema keys."""
    reason = windowed_skip_reason()
    return {
        "schema": "play-report/1",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "project": str(project),
        "window": window,
        "transport": "skipped-headless",
        "skipped": True,
        "skipped_reason": reason,
        "steps": [{"action": "skipped", "ok": True, "reason": reason}],
        "reached_states": [],
        "stuck_at": None,
        "inventory_checks": [],
        "creation_confirmed": False,
        "player_step": None,
        "snapshot_captured": False,
    }


def run_play_agent(project: Path, godot_bin: str = DEFAULT_GODOT_BIN,
                   timeout: float = PLAY_TIMEOUT, bundle: dict | None = None,
                   use_cmd: bool = True, report_path: Path | None = None) -> tuple[dict, Path]:
    """Entry: assemble bundle (or use provided), optionally invoke the advisory
    cmd agent, then run the windowed-subprocess drive and write play_report.json.
    Returns (report, path)."""
    if bundle is None:
        bundle = assemble_bundle(project)

    if force_headless():
        report = _skipped_report(project, bundle.get("window"))
        path = write_report(report, project, report_path)
        return report, path

    # Optional cmd agent pre-pass (the second cmd invocation). Its stdout JSON
    # is appended to the report as cmd_plan_steps — advisory only; it NEVER
    # bypasses the live windowed run that grounds the report.
    cmd_plan: dict | None = None
    if use_cmd:
        cmd_plan = _invoke_command_code(bundle, timeout=min(30, int(timeout)))
        if cmd_plan and isinstance(cmd_plan, dict):
            print(f"play_agent: cmd plan received ({len(cmd_plan.get('steps') or [])} steps)", file=sys.stderr)

    drive = _drive_live(project, godot_bin, timeout, bundle)
    # If cmd plan carried extra steps, append them as advisory (never overwrite live).
    if isinstance(cmd_plan, dict) and isinstance(cmd_plan.get("steps"), list):
        drive.setdefault("cmd_plan_steps", cmd_plan["steps"])

    report = make_report(bundle, drive, project)
    report["transport"] = "windowed-subprocess"
    # Merge cmd plan advisory
    if "cmd_plan_steps" in drive:
        report["cmd_plan_steps"] = drive["cmd_plan_steps"]

    path = write_report(report, project, report_path)
    return report, path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=str(ROOT), help="project root (contains project.godot)")
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN))
    parser.add_argument("--timeout", type=float, default=PLAY_TIMEOUT,
                        help=f"wall-clock budget s (default {PLAY_TIMEOUT}, must be < {REVIEWER_TIMEOUT})")
    parser.add_argument("--bundle", type=Path, default=None,
                        help="read bundle JSON from file instead of assembling")
    parser.add_argument("--report", type=Path, default=None,
                        help="report path (default: .godot-smoke/play_report.json)")
    parser.add_argument("--no-cmd", action="store_true",
                        help="skip the cmd -p agent pre-pass (deterministic drive only)")
    parser.add_argument("--windowed-only-check", action="store_true",
                        help="exit 0 after printing WINDOWED_ONLY guard status")
    args = parser.parse_args(argv)

    if args.timeout >= REVIEWER_TIMEOUT:
        print(f"error: --timeout {args.timeout} must be < REVIEWER_TIMEOUT {REVIEWER_TIMEOUT}",
              file=sys.stderr)
        return 2
    if args.windowed_only_check:
        print(f"WINDOWED_ONLY={WINDOWED_ONLY} PLAY_TIMEOUT={PLAY_TIMEOUT} REVIEWER_TIMEOUT={REVIEWER_TIMEOUT}")
        return 0

    project = Path(args.project).expanduser().resolve()
    if not (project / "project.godot").exists():
        print(f"error: no project.godot at {project}", file=sys.stderr)
        return 2

    # Stdin bundle path (the cmd wrapper ships bundle on stdin). File --bundle wins,
    # then stdin JSON object, then assembled.
    bundle: dict | None = None
    if args.bundle is not None:
        try:
            bundle = json.loads(args.bundle.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"error: cannot read --bundle {args.bundle}: {exc}", file=sys.stderr)
            return 2
    elif not sys.stdin.isatty():
        try:
            raw = sys.stdin.read()
            if raw.strip():
                maybe = json.loads(raw)
                if isinstance(maybe, dict) and any(k in maybe for k in ("window", "trace_tail", "available_scenarios")):
                    bundle = maybe
        except (OSError, ValueError):
            bundle = None

    # Report path override: thread it through (write_report honors out_path);
    # keep the PLAY_REPORT global in sync for legacy readers.
    global PLAY_REPORT
    report_path: Path | None = None
    if args.report is not None:
        report_path = Path(args.report).expanduser()
        if not report_path.is_absolute():
            report_path = project / report_path
        PLAY_REPORT = report_path

    # Transport honesty
    if force_headless():
        report = _skipped_report(project, _read_window(project))
        path = write_report(report, project, report_path)
        print(json.dumps(report, indent=2, sort_keys=True))
        print(f"SKIP: {windowed_skip_reason()}", file=sys.stderr)
        print(f"report: {path}", file=sys.stderr)
        return 0

    # Godot binary required for windowed lane
    if not Path(args.godot_bin).exists():
        print(f"error: Godot binary missing: {args.godot_bin}", file=sys.stderr)
        return 2

    report, path = run_play_agent(project, args.godot_bin,
                                  timeout=float(args.timeout), bundle=bundle,
                                  use_cmd=not args.no_cmd, report_path=report_path)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {path}", file=sys.stderr)
    return 0 if not report.get("stuck_at") else 1


if __name__ == "__main__":
    sys.exit(main())
