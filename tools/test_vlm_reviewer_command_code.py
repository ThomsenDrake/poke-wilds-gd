#!/usr/bin/env python3
"""Focused Command Code availability tests for the Lane-4 reviewer."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/vlm_reviewer.py"
SPEC = importlib.util.spec_from_file_location("vlm_reviewer_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VLM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VLM)


class CommandCodeAvailabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fake_bin = Path(self.temp.name) / "bin"
        self.fake_bin.mkdir()
        self.cmd = self.fake_bin / "cmd"
        self.cmd.write_text(
            """#!/usr/bin/env bash
sleep "${FAKE_CMD_DELAY:-0}"
printf '1.26.0\n'
""",
            encoding="utf-8",
        )
        self.cmd.chmod(self.cmd.stat().st_mode | stat.S_IXUSR)

    def _env(self, **extra: str) -> dict[str, str]:
        env = {
            "PATH": f"{self.fake_bin}:{os.environ.get('PATH', '')}",
            "COMMAND_CODE_API_KEY": "test-only-placeholder",
        }
        env.update(extra)
        return env

    def test_reuses_successful_launcher_preflight_without_duplicate_probe(self) -> None:
        env = self._env(
            POKEWILDS_COMMAND_CODE_PREFLIGHTED="1",
            FAKE_CMD_DELAY="10",
        )
        started = time.monotonic()
        with mock.patch.dict(os.environ, env, clear=True):
            available, reason = VLM._command_code_available()
        self.assertTrue(available)
        self.assertIn("preflight reused", reason)
        self.assertLess(time.monotonic() - started, 2)

    def test_standalone_probe_timeout_is_configurable(self) -> None:
        env = self._env(
            COMMAND_CODE_PROBE_TIMEOUT="1",
            FAKE_CMD_DELAY="2",
        )
        with mock.patch.dict(os.environ, env, clear=True):
            available, reason = VLM._command_code_available()
        self.assertFalse(available)
        self.assertIn("TimeoutExpired", reason)

    def test_standalone_probe_accepts_cold_start_within_budget(self) -> None:
        env = self._env(
            COMMAND_CODE_PROBE_TIMEOUT="2",
            FAKE_CMD_DELAY="0.1",
        )
        with mock.patch.dict(os.environ, env, clear=True):
            available, reason = VLM._command_code_available()
        self.assertTrue(available)
        self.assertEqual(reason, "cmd CLI available")

    def test_invalid_probe_timeout_falls_back_to_default(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"COMMAND_CODE_PROBE_TIMEOUT": "not-a-number"},
            clear=True,
        ):
            self.assertEqual(
                VLM._command_code_probe_timeout(),
                VLM.DEFAULT_COMMAND_CODE_PROBE_TIMEOUT,
            )

    def test_preflight_never_bypasses_runtime_auth_requirement(self) -> None:
        env = self._env(POKEWILDS_COMMAND_CODE_PREFLIGHTED="1")
        env.pop("COMMAND_CODE_API_KEY")
        no_auth_home = Path(self.temp.name) / "no-auth-home"
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(VLM.Path, "home", return_value=no_auth_home):
            available, reason = VLM._command_code_available()
        self.assertFalse(available)
        self.assertIn("COMMAND_CODE_API_KEY unset", reason)


class CommandCodeIncompleteRepairTests(unittest.TestCase):
    def test_targeted_repair_adds_missing_answer_without_overwriting_original(self) -> None:
        questions = [
            {"id": "menu.layout", "text": "Layout readable?"},
            {"id": "menu.cursor", "text": "Cursor aligned?"},
        ]
        original = {
            "answers": [
                {"question_id": "menu.layout", "verdict": "yes", "note": "ok"}
            ]
        }
        targeted_repair = {
            "answers": [
                # A repeated conflicting verdict must not overwrite pass one.
                {"question_id": "menu.layout", "verdict": "no", "note": "repeat"},
                {"question_id": "menu.cursor", "verdict": "yes", "note": "ok"},
            ]
        }
        cfg = SimpleNamespace(
            seed=7,
            independent_vote=False,
            n=2,
            command_code_model="gpt-5.6-luna",
            dashscope_model="unused",
            model="unused",
        )
        review_context = SimpleNamespace(specialist_block=lambda _group: "")
        with mock.patch.object(VLM, "load_questions", return_value=("menu", questions)), \
                mock.patch.object(VLM, "_region_catalog", return_value=("catalog", [])), \
                mock.patch.object(VLM, "build_system_prompt", return_value="system"), \
                mock.patch.object(VLM, "build_user_content", return_value=("user", [], [])), \
                mock.patch.object(
                    VLM,
                    "_call_model",
                    side_effect=[
                        VLM.json.dumps(original),
                        VLM.json.dumps(targeted_repair),
                    ],
                ) as call_model, \
                mock.patch.object(VLM, "_review_context", return_value=review_context):
            answers, meta = VLM.run_model({}, cfg, "command_code")

        self.assertEqual(call_model.call_count, 2)
        self.assertEqual(
            [(answer["question_id"], answer["verdict"]) for answer in answers],
            [("menu.layout", "yes"), ("menu.cursor", "yes")],
        )
        self.assertEqual(meta["passes_completed"], 1)
        self.assertEqual(meta["per_pass"][0]["answers"], 2)
        self.assertEqual(meta["per_pass"][0]["incomplete_repair"], "completed")
        self.assertEqual(meta["per_pass"][0]["repair_added"], ["menu.cursor"])


class OpenAICompatibleFallbackTests(unittest.TestCase):
    def test_default_argv_keeps_low_effort_on_luna(self) -> None:
        cfg = VLM.Config(VLM._parse_args([]))
        argv = VLM.command_code_argv("/bin/cmd", "prompt", cfg)
        self.assertEqual(cfg.command_code_effort, "low")
        self.assertEqual(argv[argv.index("--effort") + 1], "low")
        self.assertEqual(argv[argv.index("--model") + 1], "gpt-5.6-luna")

    def test_fallback_constants_are_mistral_medium_high_effort(self) -> None:
        self.assertEqual(VLM.FALLBACK_MODEL, "mistral-medium-3-5")
        self.assertEqual(VLM.FALLBACK_EFFORT, "high")
        self.assertEqual(VLM.DEFAULT_FALLBACK_BASE, "https://api.mistral.ai/v1")

    def test_probe_uses_openai_compatible_when_command_code_missing(self) -> None:
        cfg = VLM.Config(VLM._parse_args(["--runtime", "auto"]))
        cfg.fallback_key = "test-only-placeholder"
        with mock.patch.object(VLM, "_command_code_available", return_value=(False, "cmd CLI not found")):
            backend, reason = VLM.probe_availability(cfg)
        self.assertEqual(backend, "openai_compatible")
        self.assertIn("fallback key present", reason)

    def test_fallback_request_sends_reasoning_effort_high(self) -> None:
        cfg = VLM.Config(VLM._parse_args([]))
        cfg.fallback_key = "test-only-placeholder"
        captured: dict = {}

        def fake_post(url: str, body: dict, headers: dict, timeout: int) -> dict:
            captured.update({"url": url, "body": body, "headers": headers, "timeout": timeout})
            return {"choices": [{"message": {"content": '{"answers":[]}'}}]}

        with mock.patch.object(VLM, "_post_json", side_effect=fake_post):
            text = VLM._call_fallback(cfg, "system", "user", [], 0.0, 1)
        self.assertEqual(text, '{"answers":[]}')
        self.assertEqual(captured["url"], "https://api.mistral.ai/v1/chat/completions")
        self.assertEqual(captured["body"]["model"], "mistral-medium-3-5")
        self.assertEqual(captured["body"]["reasoning_effort"], "high")
        self.assertTrue(captured["headers"]["Authorization"].startswith("Bearer "))
        self.assertNotIn(cfg.fallback_key, str(captured["url"]))

    def test_describe_records_fallback_presence_without_secret(self) -> None:
        cfg = VLM.Config(VLM._parse_args([]))
        cfg.fallback_key = "super-secret-key"
        meta = cfg.describe()
        self.assertTrue(meta["fallback_key_present"])
        dumped = VLM.json.dumps(meta)
        self.assertNotIn("super-secret-key", dumped)
        self.assertEqual(meta["fallback_model"], "mistral-medium-3-5")
        self.assertEqual(meta["fallback_effort"], "high")

    def test_openai_compatible_is_single_pass(self) -> None:
        cfg = VLM.Config(VLM._parse_args([]))
        self.assertEqual(VLM._required_passes(cfg, "openai_compatible"), 1)
        self.assertEqual(VLM._required_passes(cfg, "command_code"), 1)
        self.assertEqual(VLM._required_passes(cfg, "dashscope"), 2)


if __name__ == "__main__":
    unittest.main()
