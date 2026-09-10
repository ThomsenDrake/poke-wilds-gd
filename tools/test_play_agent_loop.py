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
    def tearDown(self) -> None:
        os.environ.pop(pal.FORCE_HEADLESS_ENV, None)
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        os.environ.pop(pal.RECORD_VIDEO_ENV, None)
        os.environ.pop(pal.VIDEO_PATH_ENV, None)
        os.environ.pop(pal.FFMPEG_ENV, None)

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

    def test_live_flag_absent_strips_live(self) -> None:
        os.environ.pop(pal.LIVE_FILE_ENV, None)
        command = {
            "id": "t1",
            "action": "file_feedback",
            "payload": {"message": "[agent-play] planted", "live": True},
        }
        out = pal.apply_live_policy(command)
        self.assertFalse(out["payload"]["live"])
        self.assertTrue(command["payload"]["live"])

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
        self.assertEqual(plan[-1]["action"], "quit")
        self.assertTrue(any(step["action"] == "observe" for step in plan))
        for step in plan:
            self.assertIn(step["action"], pal.ACTIONS)
            payload = step.get("payload") or {}
            if step["action"] in {"press", "hold"}:
                self.assertIn(payload.get("input"), pal.INPUTS)

    def test_turn_budget_error(self) -> None:
        err = pal.turn_budget_error()
        self.assertEqual(err["code"], "turn_budget_exhausted")
        self.assertFalse(err["retryable"])
        self.assertTrue(err["hint"])

    def test_next_command_starts_with_boot(self) -> None:
        command, index, filed = pal._next_command(1, None, 0, False, None)
        self.assertEqual(command["action"], "boot_new_game")
        self.assertEqual(index, 1)
        self.assertFalse(filed)

    def test_last_turn_forces_quit(self) -> None:
        command, _, _ = pal._next_command(8, {"screen": "overworld"}, 3, True, None, 8)
        self.assertEqual(command["action"], "quit")

    def test_last_turn_still_files_novel(self) -> None:
        novelty = {"anomaly": True, "novel": True, "live_fileable": False}
        command, _, filed = pal._next_command(
            8, {"screen": "overworld", "exceptions": ["boom"]}, 3, False, novelty, 8,
        )
        self.assertEqual(command["action"], "file_feedback")
        self.assertTrue(filed)

    def test_godot_cmd_uses_dummy_audio(self) -> None:
        argv = pal.godot_cmd("/godot", Path("/tmp/proj"))
        self.assertIn("--audio-driver", argv)
        self.assertIn("Dummy", argv)

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


if __name__ == "__main__":
    unittest.main()
