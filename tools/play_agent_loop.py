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
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent

DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
PLAY_TIMEOUT = 180
TURN_BUDGET = 96
SCENARIO = "play_agent_loop"
FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"
LIVE_FILE_ENV = "PLAY_AGENT_LIVE_FILE"
PLANNER_CMD_ENV = "PLAY_AGENT_PLANNER_CMD"
RECORD_VIDEO_ENV = "PLAY_AGENT_RECORD_VIDEO"
VIDEO_PATH_ENV = "PLAY_AGENT_VIDEO_PATH"
FFMPEG_ENV = "PLAY_AGENT_FFMPEG"
REPORT_NAME = "play_agent_loop.json"
VIDEO_NAME = "play_agent_loop.mp4"
CANONICAL_SIZE = (1152, 648)
ACTIONS = (
    "boot_new_game", "press", "hold", "observe", "file_feedback", "quit",
)
INPUTS = (
    "move_up", "move_down", "move_left", "move_right",
    "action_a", "action_b", "menu", "build_toggle",
)
MOVE_DELTA = {
    "move_right": (1, 0),
    "move_left": (-1, 0),
    "move_down": (0, 1),
    "move_up": (0, -1),
}
DIR_ORDER = ("move_right", "move_down", "move_left", "move_up")
MIN_BATTLE_PRESSES = 8
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
_load_module("cloud_env", TOOLS / "cloud_env.py").load_cloud_env()


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
        "video": "",
        "video_bytes": 0,
        "video_reason": "headless",
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
        "video": "",
        "video_bytes": 0,
        "video_reason": "",
    }
    report.update(overrides)
    return report


def video_enabled() -> bool:
    return os.environ.get(RECORD_VIDEO_ENV, "1").lower() not in (
        "0", "false", "no", "off",
    )


def ffmpeg_path() -> str:
    return os.environ.get(FFMPEG_ENV, "") or (shutil.which("ffmpeg") or "")


def video_path_for(project: Path) -> Path:
    override = os.environ.get(VIDEO_PATH_ENV, "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return project / ".godot-smoke" / VIDEO_NAME


def _x11_size() -> tuple[int, int]:
    try:
        output = subprocess.check_output(["xdpyinfo"], text=True, timeout=2)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return CANONICAL_SIZE
    for line in output.splitlines():
        if "dimensions:" not in line:
            continue
        token = line.split(":", 1)[1].strip().split()[0]
        if "x" in token:
            width, height = token.split("x", 1)
            if width.isdigit() and height.isdigit():
                return int(width), int(height)
    return CANONICAL_SIZE


def recorder_argv(out: Path) -> tuple[list[str] | None, str]:
    if not video_enabled():
        return None, "video_disabled"
    ffmpeg = ffmpeg_path()
    if not ffmpeg:
        return None, "ffmpeg_missing"
    display = os.environ.get("DISPLAY", "")
    if sys.platform.startswith("linux") and display:
        width, height = _x11_size()
        return [
            ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
            "-f", "x11grab", "-draw_mouse", "0",
            "-video_size", f"{width}x{height}", "-framerate", "30",
            "-i", display,
            "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-preset", "veryfast", "-crf", "23",
            str(out),
        ], ""
    return None, "no_capture_source"


def start_recorder(out: Path) -> tuple[subprocess.Popen | None, str]:
    argv, reason = recorder_argv(out)
    if argv is None:
        return None, reason
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True,
        )
    except OSError as exc:
        return None, f"recorder_launch_failed:{exc}"
    time.sleep(0.2)
    if proc.poll() is not None:
        err = ""
        if proc.stderr is not None:
            err = (proc.stderr.read() or "").strip()
        return None, (err or "recorder_exited")[:200]
    return proc, ""


def stop_recorder(proc: subprocess.Popen | None) -> str:
    if proc is None:
        return ""
    if proc.poll() is not None:
        if proc.stderr is None:
            return ""
        return (proc.stderr.read() or "").strip()[:200]
    try:
        if proc.stdin is not None:
            proc.stdin.write("q")
            proc.stdin.flush()
            proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    return ""


def video_report_fields(project: Path, recorder: subprocess.Popen | None,
                        reason: str) -> dict[str, Any]:
    path = video_path_for(project)
    if recorder is not None and path.is_file() and path.stat().st_size > 0:
        rel = path
        try:
            rel = path.relative_to(project)
        except ValueError:
            pass
        return {
            "video": str(rel),
            "video_bytes": int(path.stat().st_size),
            "video_reason": "",
        }
    return {"video": "", "video_bytes": 0, "video_reason": reason or "recorder_empty"}


def apply_live_policy(command: dict[str, Any]) -> dict[str, Any]:
    out = json.loads(json.dumps(command))
    if out.get("action") == "file_feedback":
        payload = dict(out.get("payload") or {})
        payload["live"] = bool(payload.get("live")) and live_file_enabled()
        out["payload"] = payload
    return out


def explorer_plan() -> list[dict[str, Any]]:
    """Verb mix the observation-driven explorer covers (tests + docs)."""
    return [
        {"action": "boot_new_game", "payload": {}},
        {"action": "hold", "payload": {"input": "move_right"}},
        {"action": "press", "payload": {"input": "action_a"}},
        {"action": "press", "payload": {"input": "build_toggle"}},
        {"action": "press", "payload": {"input": "action_a"}},
        {"action": "press", "payload": {"input": "build_toggle"}},
        {"action": "observe", "payload": {}},
        {"action": "quit", "payload": {}},
    ]


def new_explorer_state() -> dict[str, Any]:
    return {
        "booted": False,
        "harvest_tries": 0,
        "build_phase": 0,
        "battle_presses": 0,
        "dir": 0,
        "last_tile": None,
        "blocked": 0,
        "spiral_leg": 1,
        "spiral_left": 1,
        "saw_harvest": False,
        "saw_build": False,
        "saw_battle": False,
        "observed": False,
        "explore_steps": 0,
    }


def _as_tile(value: Any) -> tuple[int, int] | None:
    if isinstance(value, (list, tuple)) and len(value) == 2:
        try:
            return int(value[0]), int(value[1])
        except (TypeError, ValueError):
            return None
    return None


def _input_toward(here: tuple[int, int], dest: tuple[int, int]) -> str | None:
    dx = dest[0] - here[0]
    dy = dest[1] - here[1]
    if dx == 0 and dy == 0:
        return None
    if abs(dx) >= abs(dy):
        return "move_right" if dx > 0 else "move_left"
    return "move_down" if dy > 0 else "move_up"


def _facing_toward(facing: Any, here: tuple[int, int], dest: tuple[int, int]) -> bool:
    face = _as_tile(facing)
    needed = _input_toward(here, dest)
    if face is None or needed is None:
        return False
    return (face[0], face[1]) == MOVE_DELTA[needed]


def _note_tile(state: dict[str, Any], observation: dict[str, Any]) -> tuple[int, int] | None:
    tile = _as_tile(observation.get("tile"))
    if tile is None:
        return None
    if state.get("last_tile") == tile:
        state["blocked"] = int(state.get("blocked") or 0) + 1
    else:
        state["blocked"] = 0
        state["last_tile"] = tile
    return tile


def _spiral_hold(state: dict[str, Any]) -> dict[str, Any]:
    if int(state.get("blocked") or 0) >= 2:
        state["dir"] = (int(state.get("dir") or 0) + 1) % 4
        state["blocked"] = 0
        state["spiral_left"] = int(state.get("spiral_leg") or 1)
    else:
        left = int(state.get("spiral_left") or 1) - 1
        state["spiral_left"] = left
        if left <= 0:
            state["dir"] = (int(state.get("dir") or 0) + 1) % 4
            if int(state.get("dir") or 0) % 2 == 0:
                state["spiral_leg"] = int(state.get("spiral_leg") or 1) + 1
            state["spiral_left"] = int(state.get("spiral_leg") or 1)
    return {
        "action": "hold",
        "payload": {"input": DIR_ORDER[int(state.get("dir") or 0) % 4]},
    }


def _walk_or_face(
    state: dict[str, Any],
    here: tuple[int, int],
    dest: tuple[int, int],
    facing: Any,
    arrive_action: str,
) -> dict[str, Any]:
    if here == dest:
        if _facing_toward(facing, here, dest) or arrive_action != "action_a":
            return {"action": "press", "payload": {"input": arrive_action}}
        toward = _input_toward(here, dest)
        if toward:
            return {"action": "hold", "payload": {"input": toward}}
        return {"action": "press", "payload": {"input": arrive_action}}
    toward = _input_toward(here, dest)
    if toward is None:
        return _spiral_hold(state)
    if int(state.get("blocked") or 0) >= 2:
        return _spiral_hold(state)
    return {"action": "hold", "payload": {"input": toward}}


def _harvest_command(
    state: dict[str, Any],
    observation: dict[str, Any],
    here: tuple[int, int],
) -> dict[str, Any] | None:
    if int(state.get("harvest_tries") or 0) >= 2:
        return None
    faced = str(observation.get("faced_action") or "")
    if faced in {"cut", "smash", "dig"}:
        state["harvest_tries"] = int(state.get("harvest_tries") or 0) + 1
        state["saw_harvest"] = True
        return {"action": "press", "payload": {"input": "action_a"}}
    target = observation.get("harvest_near")
    if not isinstance(target, dict):
        return None
    stand = _as_tile(target.get("from_tile")) or _as_tile(target.get("tile"))
    harvest_tile = _as_tile(target.get("tile"))
    if stand is None or harvest_tile is None:
        return None
    if here == stand:
        if _facing_toward(observation.get("facing"), here, harvest_tile):
            state["harvest_tries"] = int(state.get("harvest_tries") or 0) + 1
            state["saw_harvest"] = True
            return {"action": "press", "payload": {"input": "action_a"}}
        toward = _input_toward(here, harvest_tile)
        if toward:
            return {"action": "hold", "payload": {"input": toward}}
    return _walk_or_face(state, here, stand, observation.get("facing"), "action_a")


def _build_command(state: dict[str, Any]) -> dict[str, Any] | None:
    phase = int(state.get("build_phase") or 0)
    if phase >= 3:
        return None
    if phase == 0:
        state["build_phase"] = 1
        state["saw_build"] = True
        return {"action": "press", "payload": {"input": "build_toggle"}}
    if phase == 1:
        state["build_phase"] = 2
        return {"action": "press", "payload": {"input": "action_a"}}
    state["build_phase"] = 3
    return {"action": "press", "payload": {"input": "build_toggle"}}


def _hunt_command(
    state: dict[str, Any],
    observation: dict[str, Any],
    here: tuple[int, int],
) -> dict[str, Any]:
    nearby = observation.get("nearby") or []
    best: tuple[int, int] | None = None
    best_dist = 10**9
    for entity in nearby:
        if not isinstance(entity, dict):
            continue
        tile = _as_tile(entity.get("tile"))
        if tile is None:
            continue
        dist = abs(tile[0] - here[0]) + abs(tile[1] - here[1])
        if dist < best_dist:
            best = tile
            best_dist = dist
    if best is None:
        return _spiral_hold(state)
    if best_dist == 0:
        return {"action": "press", "payload": {"input": "action_a"}}
    toward = _input_toward(here, best)
    if toward is None or int(state.get("blocked") or 0) >= 2:
        return _spiral_hold(state)
    return {"action": "hold", "payload": {"input": toward}}


def explorer_command(
    state: dict[str, Any],
    observation: dict[str, Any] | None,
) -> dict[str, Any]:
    if not state.get("booted"):
        state["booted"] = True
        return {"action": "boot_new_game", "payload": {}}
    obs = observation or {}
    screen = str(obs.get("screen") or "")
    if screen == "battle":
        state["saw_battle"] = True
        state["battle_presses"] = int(state.get("battle_presses") or 0) + 1
        return {"action": "press", "payload": {"input": "action_a"}}
    if screen in {"menu", "party", "bag", "feedback", "camp", "storage", "waystone"}:
        return {"action": "press", "payload": {"input": "action_b"}}
    if (
        state.get("saw_harvest")
        and state.get("saw_build")
        and state.get("saw_battle")
        and int(state.get("battle_presses") or 0) >= MIN_BATTLE_PRESSES
    ):
        if not state.get("observed"):
            state["observed"] = True
            return {"action": "observe", "payload": {}}
        return {"action": "quit", "payload": {}}
    here = _note_tile(state, obs)
    if screen != "overworld" or here is None:
        return {"action": "observe", "payload": {}}
    harvest = _harvest_command(state, obs, here)
    if harvest is not None:
        return harvest
    if not state.get("saw_harvest") and int(state.get("harvest_tries") or 0) < 2:
        state["explore_steps"] = int(state.get("explore_steps") or 0) + 1
        if int(state["explore_steps"]) >= 24:
            state["harvest_tries"] = 2
        elif int(state["explore_steps"]) % 6 == 0:
            state["harvest_tries"] = int(state.get("harvest_tries") or 0) + 1
            state["saw_harvest"] = True
            return {"action": "press", "payload": {"input": "action_a"}}
        else:
            return _spiral_hold(state)
    build = _build_command(state)
    if build is not None:
        return build
    return _hunt_command(state, obs, here)


def turn_budget_error() -> dict[str, str | bool]:
    return {
        "code": "turn_budget_exhausted",
        "retryable": False,
        "hint": "The loop reached --turns without quit; raise the budget or inspect the report.",
    }


def godot_cmd(godot_bin: str, project: Path) -> list[str]:
    return [godot_bin, "--path", str(project), *playtests.godot_audio_args()]


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
    state: dict[str, Any],
    file_once: bool,
    novelty: dict[str, Any] | None,
    turn_budget: int = TURN_BUDGET,
) -> tuple[dict[str, Any], dict[str, Any], bool]:
    planner = os.environ.get(PLANNER_CMD_ENV, "").strip()
    if planner and observation is not None:
        planned = _planner_command(observation, planner)
        if planned:
            planned.setdefault("id", f"t{turn}")
            return apply_live_policy(planned), state, file_once
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
        return apply_live_policy(command), state, True
    if turn >= turn_budget:
        return apply_live_policy({"id": f"t{turn}", "action": "quit", "payload": {}}), state, file_once
    step = explorer_command(state, observation)
    command = {"id": f"t{turn}", "action": step["action"], "payload": dict(step.get("payload") or {})}
    return apply_live_policy(command), state, file_once


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


def _drive(project: Path, godot_bin: str, timeout: float, prior_findings: list[Any],
           turn_budget: int = TURN_BUDGET) -> dict[str, Any]:
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
    explorer_state = new_explorer_state()
    file_once = False
    observation: dict[str, Any] | None = None
    sent_quit = False
    recorder: subprocess.Popen | None = None
    video_reason = ""
    try:
        recorder, video_reason = start_recorder(video_path_for(project))
        env = os.environ.copy()
        env.setdefault("GODOT_AUDIO_DRIVER", "Dummy")
        proc = subprocess.Popen(
            godot_cmd(godot_bin, project), cwd=str(project),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace", bufsize=1, env=env,
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
        while turns < turn_budget and time.monotonic() < deadline:
            drain()
            command, explorer_state, file_once = _next_command(
                turns + 1, observation, explorer_state, file_once, novelty, turn_budget,
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
                sent_quit = True
                break
            if proc.poll() is not None:
                break
        if (
            not sent_quit
            and proc is not None
            and proc.poll() is None
            and time.monotonic() < deadline
        ):
            quit_cmd = apply_live_policy({
                "id": f"t{turns + 1}", "action": "quit", "payload": {},
            })
            write_json_atomic(command_path, quit_cmd)
            grace = _wait_observation(observation_path, quit_cmd["id"], proc, deadline)
            if grace is not None:
                sent_quit = True
                observation = grace
        if turns >= turn_budget and not sent_quit:
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
        if recorder is not None and proc is not None and proc.poll() is None:
            time.sleep(0.5)
        stop_err = stop_recorder(recorder)
        if stop_err and not video_reason:
            video_reason = stop_err
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
        **video_report_fields(project, recorder, video_reason),
    )


def run_loop(project: Path, godot_bin: str, timeout: float = PLAY_TIMEOUT,
             prior_findings: list[Any] | None = None,
             report_path: Path | None = None,
             turn_budget: int = TURN_BUDGET) -> tuple[dict[str, Any], Path]:
    if force_headless():
        report = skip_report(skip_reason())
        return report, write_report(project, report, report_path)
    report = _drive(project, godot_bin, timeout, prior_findings or [], turn_budget)
    return report, write_report(project, report, report_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=str(ROOT))
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN))
    parser.add_argument("--timeout", type=float, default=PLAY_TIMEOUT)
    parser.add_argument("--turns", type=int, default=TURN_BUDGET)
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--prior-findings", type=Path, default=None)
    parser.add_argument("--no-video", action="store_true",
                        help="Skip the ffmpeg play-session recording")
    parser.add_argument("--video", type=Path, default=None,
                        help="Write the play-session mp4 here (default .godot-smoke/play_agent_loop.mp4)")
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
    if args.no_video:
        os.environ[RECORD_VIDEO_ENV] = "0"
    if args.video is not None:
        os.environ[VIDEO_PATH_ENV] = str(Path(args.video).expanduser().resolve())
    turn_budget = TURN_BUDGET
    if args.turns > 0:
        turn_budget = min(int(args.turns), TURN_BUDGET)
    report, path = run_loop(project, args.godot_bin, float(args.timeout), prior, args.report, turn_budget)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {path}", file=sys.stderr)
    if report.get("video"):
        print(f"video: {report['video']}", file=sys.stderr)
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
