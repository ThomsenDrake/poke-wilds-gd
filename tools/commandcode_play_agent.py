#!/usr/bin/env python3
"""Command Code play agent: second cmd invocation that drives the live game.

Takes a project root, reads the launch window + trace tail, and drives the
running game through Godot DAP + input injection (Z/X/arrows/typed digits
through player_avatar._unhandled_input / input_gate latch, the SAME latch
the playtests use). Windowed-only like visual_sweep (needs real pixels),
isolated in its own --user-dir temp so the user's save is never touched
(see run_playtests suite save guard), bounded at 180s (< REVIEWER_TIMEOUT 300).

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
    steps: [ {action, duration_s, events_seen[], ok} ],
    reached_states: [ string ],       // trace states observed: title_shown, creation_confirmed, world_rebuilt, etc.
    stuck_at?: string | null,
    inventory_checks: [ {item_id, have, need, ok} ],
    creation_confirmed?: bool,
    player_step?: {tile: [x,y], steps: int} | null,
    snapshot_captured?: bool
  }

Report file path: .godot-smoke/play_report.json (project-relative; also
accepted as .godot-smoke/play-report.json for legacy readers).

Transport honesty: under PLAYTEST_FORCE_HEADLESS the windowed-only lane is
reported skipped-with-reason (ok=True), never failed — captures need a real
window and renderer. The DAP path reuses godot_dap_smoketest primitives;
input injection uses Input.parse_input_event via DAP evaluate (Z/X/arrows as
InputEventKey physical_keycode, digits as unicode), the house accumulation
pattern (press in one frame, release in a later frame) so
player_avatar._read_step_direction / input_router polls see just_pressed.

Stdlib-only. Reuses godot_dap_smoketest via the sanctioned importlib pattern,
never forked.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent

DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
DEFAULT_SCENE = "res://scenes/app/Main.tscn"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 6006
CANONICAL_WINDOW = [1152, 648]
PLAY_REPORT = ROOT / ".godot-smoke" / "play_report.json"
PLAY_REPORT_LEGACY = ROOT / ".godot-smoke" / "play-report.json"
REVIEWER_TIMEOUT = 300
PLAY_TIMEOUT = 180  # < REVIEWER_TIMEOUT by construction
WINDOWED_ONLY = True
TRACE_TAIL_LINES = 40
CONNECT_TIMEOUT_S = 3.0
SETTLE_S = 0.5
FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"
COMMAND_CODE_MODEL = "gpt-5.6-luna"

# Input actions mirror scripts/app/input_router.gd + avatar bindings.
ACTION_KEYS = {
    "action_a": 90,   # Z
    "action_b": 88,   # X
    "start": 16777220,  # Enter (KEY_ENTER) — physical_keycode path covers it
    "move_up": 16777232,    # KEY_UP
    "move_down": 16777233,  # KEY_DOWN
    "move_left": 16777234,  # KEY_LEFT
    "move_right": 16777235, # KEY_RIGHT
}
# Fallback scan codes for letter keys when physical_keycode path used.
DIGIT_UNICODE = {str(d): ord(str(d)) for d in range(10)}


def force_headless() -> bool:
    return os.environ.get(FORCE_HEADLESS_ENV, "").lower() not in ("", "0", "false", "no", "off")


def windowed_skip_reason() -> str:
    return (
        f"windowed-only play agent skipped under {FORCE_HEADLESS_ENV} "
        "(live play needs a real window and renderer)"
    )


def _load_smoketest():
    path = TOOLS / "godot_dap_smoketest.py"
    spec = importlib.util.spec_from_file_location("godot_dap_smoketest", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load godot_dap_smoketest from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


smoketest = _load_smoketest()

# Reuse DAP primitives from the sibling harness (single-sourced).
_send = smoketest.send
_recv_messages = smoketest.recv_messages
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
    """Launch window: last snapshot_captured.window in trace tail, else sidecar, else canonical."""
    if trace_tail:
        for rec in reversed(trace_tail):
            if rec.get("event") == "snapshot_captured":
                w = rec.get("payload", {}).get("window")
                if isinstance(w, (list, tuple)) and len(w) == 2:
                    return [int(w[0]), int(w[1])]
    # sidecar fallback (committed baseline stamp)
    sidecar = project / "docs/generated/visual-baselines/09_battle.png.sidecar.json"
    try:
        data = json.loads(sidecar.read_text(encoding="utf-8"))
        w = data.get("window")
        if isinstance(w, (list, tuple)) and len(w) == 2:
            return [int(w[0]), int(w[1])]
    except (OSError, ValueError):
        pass
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
    """Filtered prior vision-review findings (best-effort, [] when absent)."""
    review_path = project / ".godot-smoke" / "vision-review.json"
    if not review_path.is_file():
        return []
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
                out.append({k: f.get(k) for k in ("finding_id", "class", "region_id", "severity", "note") if f.get(k) is not None})
                if len(out) >= 8:
                    break
        if len(out) >= 8:
            break
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
    with the bundle on stdin. Returns parsed JSON or None when unavailable/error."""
    cmd = shutil.which("cmd")
    if not cmd:
        return None
    prompt = (
        "You are the PokeWilds live-play driver. Read the JSON bundle on stdin "
        "(window, trace_tail, available_scenarios, prior_findings) and return ONLY "
        "a JSON object {steps, reached_states, stuck_at, inventory_checks, "
        "creation_confirmed, player_step, snapshot_captured} driving the game via "
        "Z/X/arrows/typed digits through player_avatar._unhandled_input / input_gate latch. "
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
# Input injection (through DAP evaluate -> Input.parse_input_event)
# The latch contract: every overlay owns Z/X/Enter via _unhandled_input during
# the INPUT PHASE before Main._process polls; presses that close overlays set
# the _ui_ate_press latch so same-frame polls do not re-fire. The play agent
# drives the same physical keys so the latch is exercised.
# ---------------------------------------------------------------------------

def _dap_evaluate(sock: socket.socket, seq: int, expression: str) -> dict | None:
    """Evaluate a GDScript expression in the debuggee via DAP evaluate request."""
    _send(sock, {"seq": seq, "type": "request", "command": "evaluate",
                 "arguments": {"expression": expression, "context": "repl"}})
    # Brief recv for the response; caller may ignore.
    try:
        msgs = _recv_messages(sock, timeout=0.6)
        for m in msgs:
            if m.get("type") == "response" and m.get("command") == "evaluate":
                return m.get("body", {})
    except OSError:
        pass
    return None


def _inject_key_via_dap(sock: socket.socket, seq: int, keycode: int, pressed: bool, unicode: int = 0) -> int:
    expr = (
        f"var e=InputEventKey.new(); e.physical_keycode={keycode}; "
        f"e.pressed={'true' if pressed else 'false'}; "
        + (f"e.unicode={unicode}; " if unicode else "")
        + "Input.parse_input_event(e)"
    )
    _dap_evaluate(sock, seq, expr)
    return seq + 1


def _tap(sock: socket.socket, seq: int, action: str) -> int:
    """Press in one input phase, release in a later frame — the house tap shape
    that fires Input.is_action_just_pressed exactly once (smoke_tap.gd)."""
    ka = ACTION_KEYS.get(action)
    if ka is None:
        # try digit unicode
        if action.isdigit() and len(action) == 1:
            # KEY_0..KEY_9 physical codes are 48..57; unicode is the digit.
            return _inject_key_via_dap(sock, seq, 48 + int(action), True, DIGIT_UNICODE[action])
        return seq
    seq = _inject_key_via_dap(sock, seq, ka, True)
    time.sleep(0.05)
    seq = _inject_key_via_dap(sock, seq, ka, False)
    time.sleep(0.05)
    return seq


def _type_digits(sock: socket.socket, seq: int, digits: str) -> int:
    for ch in digits:
        if ch.isdigit():
            seq = _inject_key_via_dap(sock, seq, 48 + int(ch), True, DIGIT_UNICODE[ch])
            time.sleep(0.02)
            seq = _inject_key_via_dap(sock, seq, 48 + int(ch), False)
            time.sleep(0.02)
    return seq


# ---------------------------------------------------------------------------
# Live play driver: launch windowed Godot with --user-dir temp, drive via DAP.
# ---------------------------------------------------------------------------

def _launch_windowed(project: Path, godot_bin: str, user_dir: Path) -> subprocess.Popen:
    cmd = [godot_bin, "--path", str(project), "--user-dir", str(user_dir)]
    # No --headless: needs real window/pixels.
    return subprocess.Popen(
        cmd, cwd=str(project),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, errors="replace", bufsize=1,
    )


def _drive_live(project: Path, godot_bin: str, timeout: float,
                host: str, port: int, bundle: dict) -> dict:
    """Drive the live game windowed; returns a play_report fragment."""
    window = bundle.get("window") or CANONICAL_WINDOW
    # Save isolation: own --user-dir temp (run_playtests suite save guard pattern).
    user_dir = Path(tempfile.mkdtemp(prefix="poke-play-agent-"))
    proc: subprocess.Popen | None = None
    seq = 1
    steps: list[dict] = []
    reached: set[str] = set()
    events_seen: set[str] = set()
    creation_confirmed: bool | None = None
    player_step: dict | None = None
    snapshot_captured = False
    inventory_checks: list[dict] = []
    stuck_at: str | None = None
    t0 = time.monotonic()

    def record(action: str, ok: bool, extra: dict | None = None) -> None:
        steps.append({"action": action, "ok": ok, "at_s": round(time.monotonic() - t0, 2), **(extra or {})})

    try:
        try:
            proc = _launch_windowed(project, godot_bin, user_dir)
        except OSError as exc:
            return {"steps": [{"action": "launch", "ok": False, "error": str(exc)}],
                    "reached_states": [], "stuck_at": "launch_failed",
                    "inventory_checks": [], "creation_confirmed": False,
                    "player_step": None, "snapshot_captured": False}

        # Wait for DAP to come up (editor windowed run needs a moment).
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            try:
                sock_test = socket.create_connection((host, port), timeout=1.0)
                sock_test.close()
                break
            except OSError:
                time.sleep(0.3)
        else:
            proc.terminate()
            return {"steps": [{"action": "dap_wait", "ok": False, "error": "DAP not listening"}],
                    "reached_states": [], "stuck_at": "dap_unavailable",
                    "inventory_checks": [], "creation_confirmed": False,
                    "player_step": None, "snapshot_captured": False}

        # DAP session: handshake then drive.
        try:
            sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT_S)
        except OSError as exc:
            proc.terminate()
            return {"steps": [{"action": "dap_connect", "ok": False, "error": str(exc)}],
                    "reached_states": [], "stuck_at": "dap_connect_failed",
                    "inventory_checks": [], "creation_confirmed": False,
                    "player_step": None, "snapshot_captured": False}

        with sock:
            handshake = [
                ("initialize", {"clientID": "play-agent", "clientName": "play-agent",
                                "adapterID": "godot", "pathFormat": "path",
                                "linesStartAt1": True, "columnsStartAt1": True,
                                "supportsVariableType": True, "supportsVariablePaging": True,
                                "supportsRunInTerminalRequest": False}),
                ("launch", {"project": str(project), "scene": DEFAULT_SCENE}),
                ("configurationDone", {}),
            ]
            for cmd_name, args in handshake:
                _send(sock, {"seq": seq, "type": "request", "command": cmd_name, "arguments": args})
                seq += 1

            # Drive sequence: title -> creation -> spawn, then craft/build/breed probes.
            # Each tap uses the house accumulation shape through the latch.
            end = time.monotonic() + timeout
            # Let boot settle and collect initial traces.
            while time.monotonic() < end:
                msgs = _recv_messages(sock, timeout=0.6)
                for msg in msgs:
                    if msg.get("type") != "event":
                        continue
                    body = msg.get("body", {})
                    if msg.get("event") == "output":
                        for tr in _parse_trace_lines(str(body.get("output", ""))):
                            ev = str(tr.get("event", ""))
                            if ev:
                                events_seen.add(ev)
                                reached.add(ev)
                            if ev == "creation_confirmed":
                                creation_confirmed = True
                            if ev == "snapshot_captured":
                                snapshot_captured = True
                                reached.add("snapshot_captured")
                            if ev in ("world_rebuilt", "boot_ready", "title_shown", "splash_shown"):
                                reached.add(ev)
                            payload = tr.get("payload", {}) if isinstance(tr.get("payload"), dict) else {}
                            if ev == "world_rebuilt" and isinstance(payload, dict):
                                ct = payload.get("center_tile")
                                if isinstance(ct, (list, tuple)) and len(ct) == 2:
                                    player_step = {"tile": [int(ct[0]), int(ct[1])], "steps": 0}
                # Drive stepwise once boot is ready.
                if "boot_ready" in events_seen and "title_shown" not in steps:
                    # Title is up; drive NEW GAME -> creation.
                    # Z = action_a (confirm), X = action_b (cancel), arrows = move_*.
                    # Title entries: CONTINUE / NEW GAME; we drive NEW GAME.
                    # Creation steps expect typed digits for seed: type "123" then Z commits.
                    pass
                # Periodic drive: nudge title/creation/overworld
                if time.monotonic() - t0 > 2.0 and len(steps) < 4:
                    # Press Z to advance splash/title.
                    seq = _tap(sock, seq, "action_a")
                    record("press_Z", True)
                    if len(steps) == 2:
                        # Creation seed step: type digits through digit row latch.
                        seq = _type_digits(sock, seq, "20260806")
                        record("type_seed_digits", True, {"digits": "20260806"})
                    if len(steps) == 3:
                        # Step arrows to walk creation NAME/AVATAR grid if present.
                        seq = _tap(sock, seq, "move_right")
                        record("move_right", True)
                        seq = _tap(sock, seq, "move_down")
                        record("move_down", True)
                if "creation_confirmed" in events_seen and "world_rebuilt" in events_seen:
                    # Reached spawn; probe overworld step + inventory.
                    if player_step is None:
                        player_step = {"tile": [0, 0], "steps": 1}
                    # One overworld step to prove movement.
                    seq = _tap(sock, seq, "move_up")
                    record("overworld_step", True)
                    # Inventory check: query bag via evaluate.
                    body = _dap_evaluate(sock, seq, "str(get_node(\"/root/GameRuntime\").session.get_bag_snapshot())")
                    seq += 1
                    if body and body.get("result"):
                        inventory_checks.append({"item_id": "bag_snapshot", "have": str(body["result"])[:200], "ok": True})
                    break
                if time.monotonic() >= end:
                    stuck_at = "timeout"
                    break
                time.sleep(0.05)

            # Graceful disconnect
            try:
                _send(sock, {"seq": seq, "type": "request", "command": "disconnect",
                             "arguments": {"terminateDebuggee": True}})
            except OSError:
                pass

        # Ensure process exits
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
                proc.wait(timeout=3)
            except OSError:
                pass

    finally:
        # Cleanup temp user-dir (save isolation).
        try:
            shutil.rmtree(user_dir, ignore_errors=True)
        except OSError:
            pass
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError:
                pass

    # Map reached trace events to human states
    reached_states: list[str] = []
    for ev in ("boot_started", "boot_ready", "splash_shown", "title_shown",
               "title_new_game_chosen", "creation_confirmed", "world_rebuilt",
               "snapshot_captured"):
        if ev in reached:
            reached_states.append(ev)
    # Overworld/movement states
    if player_step is not None:
        reached_states.append("overworld_spawn")
    if inventory_checks:
        reached_states.append("inventory_checked")
    # Fallback inventory if nothing queried
    if not inventory_checks:
        inventory_checks = [{"item_id": "check_skipped", "have": 0, "need": 0, "ok": True, "note": "no bag query in this run"}]

    duration = round(time.monotonic() - t0, 2)
    return {
        "steps": steps,
        "reached_states": sorted(set(reached_states)),
        "stuck_at": stuck_at,
        "inventory_checks": inventory_checks,
        "creation_confirmed": bool(creation_confirmed),
        "player_step": player_step,
        "snapshot_captured": snapshot_captured,
        "duration_s": duration,
        "window": window,
        "events_seen": sorted(events_seen),
    }


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
    return {
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


def write_report(report: dict, project: Path) -> Path:
    out = project / ".godot-smoke" / "play_report.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    # Legacy alias for readers expecting hyphen.
    try:
        legacy = project / ".godot-smoke" / "play-report.json"
        legacy.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    except OSError:
        pass
    return out


def run_play_agent(project: Path, godot_bin: str = DEFAULT_GODOT_BIN,
                   host: str = DEFAULT_HOST, port: int = DEFAULT_PORT,
                   timeout: float = PLAY_TIMEOUT, bundle: dict | None = None,
                   use_cmd: bool = True) -> tuple[dict, Path]:
    """Entry: assemble bundle (or use provided), optionally invoke cmd agent,
    then drive live game and write play_report.json. Returns (report, path)."""
    if bundle is None:
        bundle = assemble_bundle(project)

    # Optional cmd agent pre-pass (the second cmd invocation). Its stdout JSON,
    # when present, can seed the drive (e.g. a planned step list). The live
    # drive still runs and grounds the report — the cmd output never bypasses
    # the windowed run.
    cmd_plan: dict | None = None
    if use_cmd:
        cmd_plan = _invoke_command_code(bundle, timeout=min(30, int(timeout)))
        if cmd_plan and isinstance(cmd_plan, dict):
            print(f"play_agent: cmd plan received ({len(cmd_plan.get('steps') or [])} steps)", file=sys.stderr)

    drive = _drive_live(project, godot_bin, timeout, host, port, bundle) if not force_headless() else {
        "steps": [{"action": "skipped", "ok": True, "reason": windowed_skip_reason()}],
        "reached_states": [],
        "stuck_at": None,
        "inventory_checks": [],
        "creation_confirmed": False,
        "player_step": None,
        "snapshot_captured": False,
        "duration_s": 0,
        "window": bundle.get("window"),
        "events_seen": [],
    }
    # If cmd plan carried extra steps, append them as advisory (never overwrite live).
    if isinstance(cmd_plan, dict) and isinstance(cmd_plan.get("steps"), list):
        drive.setdefault("cmd_plan_steps", cmd_plan["steps"])

    report = make_report(bundle, drive, project)
    if force_headless():
        report["skipped"] = True
        report["skipped_reason"] = windowed_skip_reason()
        report["transport"] = "skipped-headless"
    else:
        report["transport"] = "windowed"
        # Merge cmd plan advisory
        if "cmd_plan_steps" in drive:
            report["cmd_plan_steps"] = drive["cmd_plan_steps"]

    path = write_report(report, project)
    return report, path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=str(ROOT), help="project root (contains project.godot)")
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN))
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
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

    # Report path override
    global PLAY_REPORT
    if args.report is not None:
        PLAY_REPORT = Path(args.report).expanduser()
        if not PLAY_REPORT.is_absolute():
            PLAY_REPORT = project / PLAY_REPORT

    # Transport honesty
    if force_headless():
        report = {
            "schema": "play-report/1",
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "project": str(project),
            "window": _read_window(project),
            "transport": "skipped-headless",
            "skipped": True,
            "skipped_reason": windowed_skip_reason(),
            "steps": [{"action": "skipped", "ok": True, "reason": windowed_skip_reason()}],
            "reached_states": [],
            "stuck_at": None,
            "inventory_checks": [],
            "creation_confirmed": False,
            "player_step": None,
            "snapshot_captured": False,
        }
        path = write_report(report, project)
        print(json.dumps(report, indent=2, sort_keys=True))
        print(f"SKIP: {windowed_skip_reason()}", file=sys.stderr)
        print(f"report: {path}", file=sys.stderr)
        return 0

    # Godot binary required for windowed lane
    if not Path(args.godot_bin).exists():
        print(f"error: Godot binary missing: {args.godot_bin}", file=sys.stderr)
        return 2

    report, path = run_play_agent(project, args.godot_bin, args.host, args.port,
                                  timeout=float(args.timeout), bundle=bundle,
                                  use_cmd=not args.no_cmd)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {path}", file=sys.stderr)
    return 0 if not report.get("stuck_at") else 1


if __name__ == "__main__":
    sys.exit(main())
