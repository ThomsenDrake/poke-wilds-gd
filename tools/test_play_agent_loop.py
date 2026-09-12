#!/usr/bin/env python3
"""Unit tests for play_agent_loop (no Godot window required)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest

import play_agent_loop as pal


class PlayAgentLoopTests(unittest.TestCase):
    def setUp(self) -> None:
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        os.environ.pop(pal.COMMIT_SHA_ENV, None)
        os.environ.pop("CI", None)
        os.environ.pop("GITHUB_ACTIONS", None)

    def tearDown(self) -> None:
        os.environ.pop(pal.FORCE_HEADLESS_ENV, None)
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        os.environ.pop(pal.COMMIT_SHA_ENV, None)
        os.environ.pop(pal.RECORD_VIDEO_ENV, None)
        os.environ.pop(pal.VIDEO_PATH_ENV, None)
        os.environ.pop(pal.FFMPEG_ENV, None)
        os.environ.pop("CI", None)
        os.environ.pop("GITHUB_ACTIONS", None)

    def test_headless_skip_envelope(self) -> None:
        os.environ[pal.FORCE_HEADLESS_ENV] = "1"
        self.assertTrue(pal.force_headless())
        report = pal.skip_report(pal.skip_reason())
        self.assertTrue(report["ok"])
        self.assertTrue(report["skipped"])
        self.assertIn(pal.FORCE_HEADLESS_ENV, report["reason"])

    def test_main_headless_skip_writes_report(self) -> None:
        os.environ[pal.FORCE_HEADLESS_ENV] = "1"
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "project.godot").write_text("\n", encoding="utf-8")
            code = pal.main(["--project", str(root)])
            self.assertEqual(code, 0)
            report = json.loads((root / ".godot-smoke" / pal.REPORT_NAME).read_text(encoding="utf-8"))
            self.assertTrue(report["ok"])
            self.assertTrue(report["skipped"])
            self.assertTrue(report["reason"])
            self.assertEqual(report["video"], "")
            self.assertEqual(report["video_reason"], "headless")
            self.assertEqual(report["commands"], [])
            self.assertEqual(report["findings"], [])
            self.assertFalse(report["replayed"])

    def test_live_flag_absent_defaults_on(self) -> None:
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertTrue(out["payload"]["live"])
        self.assertTrue(pal.live_file_enabled())

    def test_live_flag_zero_strips_live(self) -> None:
        os.environ[pal.LIVE_FILE_ENV] = "0"
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertFalse(out["payload"]["live"])

    def test_live_flag_ci_strips_live(self) -> None:
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        os.environ["CI"] = "1"
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertFalse(out["payload"]["live"])
        self.assertFalse(pal.live_file_enabled())

    def test_live_flag_github_actions_strips_even_explicit_on(self) -> None:
        os.environ[pal.LIVE_FILE_ENV] = "1"
        os.environ["GITHUB_ACTIONS"] = "true"
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertFalse(out["payload"]["live"])
        self.assertFalse(pal.live_file_enabled())

    def test_live_flag_present_keeps_live(self) -> None:
        os.environ[pal.LIVE_FILE_ENV] = "1"
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertTrue(out["payload"]["live"])

    def test_explorer_vocab(self) -> None:
        plan = pal.explorer_plan()
        self.assertEqual(plan[0]["action"], "boot_new_game")
        self.assertNotEqual(plan[-1]["action"], "quit")
        self.assertTrue(any(step["action"] == "observe" for step in plan))
        self.assertTrue(any(
            step.get("payload", {}).get("input") == "build_toggle" for step in plan
        ))
        self.assertTrue(any(
            step.get("payload", {}).get("input") == "menu" for step in plan
        ))
        self.assertTrue(any(
            step.get("payload", {}).get("input") == "action_a" for step in plan
        ))
        for step in plan:
            self.assertIn(step["action"], pal.ACTIONS)
            payload = step.get("payload") or {}
            if step["action"] in {"press", "hold"}:
                self.assertIn(payload.get("input"), pal.INPUTS)
        self.assertIn("build_toggle", pal.INPUTS)

    def test_turn_budget_error(self) -> None:
        err = pal.turn_budget_error()
        self.assertEqual(err["code"], "turn_budget_exhausted")
        self.assertFalse(err["retryable"])
        self.assertTrue(err["hint"])

    def test_next_command_starts_with_boot(self) -> None:
        command, state, filed = pal._next_command(1, None, pal.new_explorer_state(), False, None)
        self.assertEqual(command["action"], "boot_new_game")
        self.assertTrue(state["booted"])
        self.assertFalse(filed)

    def test_last_turn_forces_quit(self) -> None:
        command, _, _ = pal._next_command(
            8, {"screen": "overworld"}, pal.new_explorer_state(), True, None, 8,
        )
        self.assertEqual(command["action"], "quit")

    def test_last_turn_still_files_novel(self) -> None:
        novelty = {"anomaly": True, "novel": True, "live_fileable": True, "anomalies": ["stuck"]}
        command, _, filed = pal._next_command(
            8, {"screen": "overworld", "exceptions": ["boom"]},
            pal.new_explorer_state(), False, novelty, 8,
        )
        self.assertEqual(command["action"], "file_feedback")
        self.assertTrue(filed)
        message = command["payload"]["message"]
        self.assertTrue(message.startswith(pal.MESSAGE_PREFIX))
        self.assertIn("replay:", message)
        self.assertNotIn("/home/", message)
        self.assertLessEqual(len(message), 1000)
        self.assertTrue(command["payload"]["live"])

    def test_last_turn_skips_vision_only(self) -> None:
        novelty = {
            "anomaly": True, "novel": False, "live_fileable": False,
            "anomalies": ["vision:blur"],
        }
        command, _, filed = pal._next_command(
            8, {"screen": "overworld"}, pal.new_explorer_state(), False, novelty, 8,
        )
        self.assertEqual(command["action"], "quit")
        self.assertFalse(filed)

    def test_replay_queue_emits_recorded_commands(self) -> None:
        recorded = [
            {"id": "t1", "action": "boot_new_game", "payload": {}},
            {"id": "t2", "action": "hold", "payload": {"input": "move_right"}},
            {"id": "t3", "action": "quit", "payload": {}},
        ]
        first, _, _ = pal._next_command(
            1, None, pal.new_explorer_state(), False, None,
            replay_commands=recorded,
        )
        self.assertEqual(first["action"], "boot_new_game")
        second, _, _ = pal._next_command(
            2, {"screen": "overworld"}, pal.new_explorer_state(), False, None,
            replay_commands=recorded,
        )
        self.assertEqual(second["action"], "hold")
        self.assertEqual(second["payload"]["input"], "move_right")
        done, _, _ = pal._next_command(
            4, {"screen": "overworld"}, pal.new_explorer_state(), False, None,
            replay_commands=recorded,
        )
        self.assertEqual(done["action"], "quit")

    def test_replay_missing_pack_exits_without_godot(self) -> None:
        os.environ.pop(pal.FORCE_HEADLESS_ENV, None)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "project.godot").write_text("\n", encoding="utf-8")
            code = pal.main([
                "--project", str(root),
                "--godot-bin", str(root / "missing-godot"),
                "--replay", str(root / "no-pack.json"),
            ])
            self.assertEqual(code, 1)
            report = json.loads((root / ".godot-smoke" / pal.REPORT_NAME).read_text(encoding="utf-8"))
            self.assertFalse(report["ok"])
            self.assertTrue(report["replayed"])
            self.assertEqual(report["errors"][0]["code"], "replay_source_missing")

    def test_session_report_includes_transcript_keys(self) -> None:
        report = pal.session_report()
        self.assertEqual(report["commands"], [])
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["world_seed"], 0)
        self.assertFalse(report["replayed"])
        self.assertEqual(report["coverage"], {"screens": [], "verbs": [], "biomes": []})

    def test_explorer_harvests_faced_tile(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [3, 4],
            "facing": [1, 0],
            "faced_action": "cut",
            "harvest_near": {"action": "cut", "tile": [4, 4], "from_tile": [3, 4]},
            "nearby": [],
        })
        self.assertEqual(command["action"], "press")
        self.assertEqual(command["payload"]["input"], "action_a")
        self.assertTrue(state["saw_harvest"])

    def test_explorer_walks_to_harvest_stand(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [1, 4],
            "facing": [1, 0],
            "faced_action": "",
            "harvest_near": {"action": "cut", "tile": [4, 4], "from_tile": [3, 4]},
            "nearby": [],
        })
        self.assertEqual(command["action"], "hold")
        self.assertEqual(command["payload"]["input"], "move_right")

    def test_explorer_harvests_faced_dig(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [3, 4],
            "facing": [1, 0],
            "faced_action": "dig",
            "party_field_moves": ["dig"],
            "harvest_near": {"action": "dig", "tile": [4, 4], "from_tile": [3, 4]},
            "nearby": [],
        })
        self.assertEqual(command["payload"]["input"], "action_a")
        self.assertTrue(state["saw_harvest"] or state.get("pending_harvest"))

    def test_explorer_skips_swallowed_spawn_dig(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        spawn = {
            "screen": "overworld",
            "tile": [-4, -4],
            "facing": [0, 1],
            "faced_action": "dig",
            "party_field_moves": [],
            "harvest_near": {"action": "dig", "tile": [-4, -4], "from_tile": [-4, -4]},
            "nearby": [],
            "trace_tail": [],
        }
        first = pal.explorer_command(state, spawn)
        self.assertNotEqual(first.get("payload", {}).get("input"), "action_a")
        self.assertFalse(state["saw_harvest"])
        self.assertEqual(int(state.get("harvest_tries") or 0), 0)
        swallowed = dict(spawn)
        swallowed["trace_tail"] = [
            {"event": "play_agent_step_applied", "ts_msec": 9, "payload": {"action": "press"}},
        ]
        pal.explorer_command(state, swallowed)
        self.assertFalse(state["saw_harvest"])
        self.assertEqual(int(state.get("harvest_tries") or 0), 0)

    def _cut_bump_obs(
        self,
        tile: list[int],
        nearby: list[dict],
        *,
        faced: str = "cut",
        party: list[str] | None = None,
        facing: list[int] | None = None,
    ) -> dict:
        return {
            "screen": "overworld",
            "tile": tile,
            "facing": facing if facing is not None else [0, 1],
            "faced_action": faced,
            "party_field_moves": [] if party is None else party,
            "nearby": nearby,
            "ui_tree": {
                "screen": "overworld",
                "nodes": [{
                    "path": ".", "type": "Label",
                    "text": "A TALL TREE BLOCKS THE WAY. IT COULD BE CUT.",
                }],
            },
            "trace_tail": [{
                "event": "traversal_blocked", "ts_msec": 12,
                "payload": {
                    "reason": "A tall tree blocks the way. It could be CUT.",
                    "requires_field_move": "cut",
                },
            }],
        }

    def test_explorer_skips_cut_when_party_cannot(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (-4, 5),
            "last_input": "move_down", "blocked": 1, "blocked_dirs": ["move_down"],
        })
        command = pal.explorer_command(state, self._cut_bump_obs(
            [-4, 5],
            [{"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"}],
        ))
        self.assertEqual(command["action"], "hold")
        self.assertIn(command["payload"]["input"], ("move_right", "move_left"))
        self.assertNotEqual(command["payload"]["input"], "action_a")
        self.assertFalse(state["saw_harvest"])
        self.assertEqual(int(state.get("harvest_tries") or 0), 0)

    def test_explorer_retries_cut_when_party_can(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": True, "harvest_tries": 2,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (-4, 5),
            "last_input": "move_down", "blocked": 1, "blocked_dirs": ["move_down"],
        })
        first = pal.explorer_command(state, self._cut_bump_obs(
            [-4, 5],
            [{"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"}],
            party=["cut"],
        ))
        self.assertEqual(first["action"], "press")
        self.assertEqual(first["payload"]["input"], "action_a")
        second = pal.explorer_command(state, self._cut_bump_obs(
            [-4, 5],
            [{"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"}],
            party=["cut"],
        ))
        self.assertNotEqual(second.get("payload", {}).get("input"), "action_a")

    def test_explorer_does_not_retry_cut_after_leaving_tile(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (-4, 5),
            "last_input": "move_down", "blocked": 1, "blocked_dirs": ["move_down"],
        })
        weedle = [{"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"}]
        first = pal.explorer_command(state, self._cut_bump_obs([-4, 5], weedle))
        self.assertNotEqual(first.get("payload", {}).get("input"), "action_a")
        pal.explorer_command(state, {
            "screen": "overworld", "tile": [-3, 5], "facing": [1, 0],
            "faced_action": "", "party_field_moves": [], "nearby": weedle,
        })
        back = pal.explorer_command(state, self._cut_bump_obs([-4, 5], weedle))
        self.assertNotEqual(back.get("payload", {}).get("input"), "action_a")
        self.assertEqual(back["action"], "hold")
        self.assertIn(back["payload"]["input"], ("move_right", "move_left"))

    def test_explorer_builds_after_harvest(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        state["saw_harvest"] = True
        state["harvest_tries"] = 2
        command = pal.explorer_command(state, {
            "screen": "overworld", "tile": [3, 4], "nearby": [],
        })
        self.assertEqual(command["payload"]["input"], "build_toggle")
        self.assertTrue(state["saw_build"])

    def test_explorer_sidesteps_blocked_tree(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": True, "harvest_tries": 2,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (3, 4),
            "last_input": "move_down", "blocked_dirs": ["move_down"],
        })
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [3, 4],
            "facing": [0, 1],
            "faced_action": "cut",
            "party_field_moves": [],
            "nearby": [{"tile": [3, 7], "species_id": "PIDGEY", "kind": "roamer"}],
        })
        self.assertEqual(command["action"], "hold")
        self.assertNotEqual(command["payload"]["input"], "move_down")

    def test_explorer_fights_in_battle(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        command = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
        self.assertEqual(command["payload"]["input"], "action_a")
        self.assertTrue(state["saw_battle"])

    def test_explorer_hunts_nearby_mon(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        state["saw_harvest"] = True
        state["harvest_tries"] = 2
        state["build_phase"] = 3
        state["saw_build"] = True
        state["opened_menu"] = True
        state["observed"] = True
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [3, 4],
            "nearby": [{"tile": [3, 7], "species_id": "PIDGEY", "kind": "roamer"}],
        })
        self.assertEqual(command["action"], "hold")
        self.assertEqual(command["payload"]["input"], "move_down")

    def test_explorer_keeps_playing_after_verbs(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": True, "saw_build": True,
            "build_phase": 3, "saw_battle": True, "battle_presses": pal.MIN_BATTLE_PRESSES,
        })
        first = pal.explorer_command(state, {"screen": "overworld", "tile": [3, 4]})
        self.assertEqual(first["payload"]["input"], "menu")
        second = pal.explorer_command(state, {"screen": "overworld", "tile": [3, 4]})
        self.assertEqual(second["action"], "observe")
        third = pal.explorer_command(state, {"screen": "overworld", "tile": [3, 4]})
        self.assertNotEqual(third["action"], "quit")

    def test_explorer_opens_menu_without_battle(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True,
        })
        command = pal.explorer_command(state, self._cut_bump_obs(
            [-4, 5],
            [{"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"}],
        ))
        self.assertEqual(command["payload"]["input"], "menu")
        self.assertTrue(state["opened_menu"])
        self.assertFalse(state["saw_battle"])

    def test_explorer_does_not_open_menu_before_possible_harvest(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True,
        })
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [1, 4],
            "facing": [1, 0],
            "faced_action": "",
            "party_field_moves": ["cut"],
            "harvest_near": {"action": "cut", "tile": [4, 4], "from_tile": [3, 4]},
            "nearby": [],
        })
        self.assertNotEqual(command.get("payload", {}).get("input"), "menu")
        self.assertEqual(command["action"], "hold")
        self.assertEqual(command["payload"]["input"], "move_right")

    def test_explorer_prefers_reachable_mon_over_cut_wall(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (-4, 5),
            "last_input": "move_down", "blocked": 1, "blocked_dirs": ["move_down"],
        })
        command = pal.explorer_command(state, self._cut_bump_obs(
            [-4, 5],
            [
                {"tile": [-4, 9], "species_id": "WEEDLE", "kind": "roamer"},
                {"tile": [2, 5], "species_id": "PIDGEY", "kind": "roamer"},
            ],
        ))
        self.assertEqual(command["action"], "hold")
        self.assertEqual(command["payload"]["input"], "move_right")
        self.assertNotEqual(command["payload"]["input"], "action_a")

    def test_explorer_walks_around_unusable_smash(self) -> None:
        state = pal.new_explorer_state()
        state.update({
            "booted": True, "saw_harvest": False, "harvest_tries": 0,
            "build_phase": 3, "saw_build": True, "opened_menu": True,
            "observed": True, "last_tile": (1, 1),
            "last_input": "move_right", "blocked": 1, "blocked_dirs": ["move_right"],
        })
        command = pal.explorer_command(state, {
            "screen": "overworld",
            "tile": [1, 1],
            "facing": [1, 0],
            "faced_action": "smash",
            "party_field_moves": [],
            "nearby": [{"tile": [4, 1], "species_id": "GEODUDE", "kind": "roamer"}],
            "trace_tail": [{
                "event": "traversal_blocked", "ts_msec": 8,
                "payload": {"reason": "A rock blocks the way.", "requires_field_move": "smash"},
            }],
        })
        self.assertEqual(command["action"], "hold")
        self.assertNotEqual(command["payload"]["input"], "action_a")
        self.assertNotEqual(command["payload"]["input"], "move_right")

    def test_explorer_lingers_in_menu(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        first = pal.explorer_command(state, {"screen": "menu", "tile": [3, 4]})
        self.assertEqual(first["payload"]["input"], "move_down")
        second = pal.explorer_command(state, {"screen": "menu", "tile": [3, 4]})
        self.assertEqual(second["payload"]["input"], "action_a")
        third = pal.explorer_command(state, {"screen": "menu", "tile": [3, 4]})
        self.assertEqual(third["payload"]["input"], "action_b")
        self.assertTrue(state["saw_menu"])

    def test_explorer_lingers_in_camp(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        command = pal.explorer_command(state, {"screen": "camp", "tile": [3, 4]})
        self.assertEqual(command["payload"]["input"], "move_down")

    def test_explorer_tries_capture_in_battle(self) -> None:
        state = pal.new_explorer_state()
        state["booted"] = True
        for _ in range(3):
            command = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
            self.assertEqual(command["payload"]["input"], "action_a")
        back = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
        self.assertEqual(back["payload"]["input"], "action_b")
        down = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
        self.assertEqual(down["payload"]["input"], "move_down")
        open_item = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
        self.assertEqual(open_item["payload"]["input"], "action_a")
        ball = pal.explorer_command(state, {"screen": "battle", "tile": [3, 4]})
        self.assertEqual(ball["payload"]["input"], "action_a")
        self.assertTrue(state["saw_capture"])

    def test_godot_cmd_uses_dummy_audio(self) -> None:
        argv = pal.godot_cmd("/godot", Path("/tmp/proj"))
        self.assertIn("--audio-driver", argv)
        self.assertIn("Dummy", argv)
        self.assertIn("--max-fps", argv)
        self.assertIn("60", argv)

    def test_recorder_disabled(self) -> None:
        os.environ[pal.RECORD_VIDEO_ENV] = "0"
        argv, reason = pal.recorder_argv(Path("/tmp/play.mp4"))
        self.assertIsNone(argv)
        self.assertEqual(reason, "video_disabled")

    def test_recorder_missing_ffmpeg(self) -> None:
        os.environ[pal.RECORD_VIDEO_ENV] = "1"
        os.environ[pal.FFMPEG_ENV] = ""
        orig = pal.shutil.which
        pal.shutil.which = lambda _name: None
        try:
            argv, reason = pal.recorder_argv(Path("/tmp/play.mp4"))
        finally:
            pal.shutil.which = orig
        self.assertIsNone(argv)
        self.assertEqual(reason, "ffmpeg_missing")

    def test_recorder_linux_x11_argv(self) -> None:
        os.environ[pal.RECORD_VIDEO_ENV] = "1"
        os.environ[pal.FFMPEG_ENV] = "/usr/bin/ffmpeg"
        os.environ["DISPLAY"] = ":99"
        argv, reason = pal.recorder_argv(Path("/tmp/play.mp4"))
        if not pal.sys.platform.startswith("linux"):
            self.assertIsNone(argv)
            self.assertEqual(reason, "no_capture_source")
            return
        self.assertEqual(reason, "")
        self.assertIsNotNone(argv)
        self.assertIn("-f", argv)
        self.assertIn("x11grab", argv)
        self.assertIn("/tmp/play.mp4", argv)

    def test_video_report_fields_empty(self) -> None:
        fields = pal.video_report_fields(Path("/tmp"), None, "ffmpeg_missing")
        self.assertEqual(fields["video"], "")
        self.assertEqual(fields["video_bytes"], 0)
        self.assertEqual(fields["video_reason"], "ffmpeg_missing")

    def test_stamp_commit_sha_never_agent_play(self) -> None:
        self.assertEqual(pal.stamp_commit_sha({"PLAY_AGENT_COMMIT_SHA": "agent-play"}, git_head=""), "unknown")
        self.assertEqual(pal.stamp_commit_sha({"PLAY_AGENT_COMMIT_SHA": "ABCDEF0"}), "abcdef0")
        self.assertEqual(pal.stamp_commit_sha({}, git_head="c" * 40), "c" * 40)
        self.assertEqual(pal.stamp_commit_sha({"PLAY_AGENT_COMMIT_SHA": "nope"}, git_head="deadbeef"), "deadbeef")
        src = (Path(__file__).resolve().parents[1] / "scripts/app/play_agent_loop_file_checks.gd").read_text(encoding="utf-8")
        self.assertNotIn('"commit_sha": "agent-play"', src)
        self.assertIn("unknown", src)
        self.assertIn("stamp_commit_sha", src)

    def test_filed_from_observation_rejects_live_without_issue(self) -> None:
        command = {"action": "file_feedback", "payload": {"live": True}}
        failed = {
            "feedback": {"status": "sent", "reason": "http_400:invalid_build", "issue_number": 0},
            "trace_tail": [{"event": "feedback_report_failed", "payload": {"reason": "http_400:invalid_build"}}],
        }
        filed, issue = pal.filed_from_observation(failed, command)
        self.assertFalse(filed)
        self.assertEqual(issue, 0)
        sent = {
            "feedback": {"status": "sent", "issue_number": 77},
            "trace_tail": [{"event": "feedback_report_sent", "payload": {"issue_number": 77}}],
        }
        filed, issue = pal.filed_from_observation(sent, command)
        self.assertEqual(filed, "live")
        self.assertEqual(issue, 77)
        dry = pal.filed_from_observation(
            {"feedback": {"status": "sent", "issue_number": 0}},
            {"action": "file_feedback", "payload": {"live": False}},
        )
        self.assertEqual(dry[0], "dry")
        gd = (Path(__file__).resolve().parents[1] / "scripts/app/play_agent_loop_file.gd").read_text(encoding="utf-8")
        self.assertNotIn('state.get("last_status", "sent")', gd)
        self.assertIn("result_without_issue", gd)


if __name__ == "__main__":
    unittest.main()
