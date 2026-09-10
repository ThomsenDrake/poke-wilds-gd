#!/usr/bin/env python3
"""Fixture tests for the play_agent_loop file-bridge contract.

Validates command / observation / report JSON against
docs/references/agent-step-bridge.md. Stdlib-only. No Godot.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest

TOOLS = Path(__file__).resolve().parent
FIXTURES = TOOLS / "fixtures" / "agent_step"

ACTIONS = frozenset({
    "boot_new_game", "press", "hold", "observe", "file_feedback", "quit",
})
INPUTS = frozenset({
    "move_up", "move_down", "move_left", "move_right",
    "action_a", "action_b", "menu",
})
MESSAGE_PREFIX = "[agent-play]"
MESSAGE_MAX = 1000
SKIP_KEYS = ("ok", "skipped", "reason")
REPORT_KEYS = (
    "ok", "skipped", "reason", "turns", "anomalies", "filed",
    "skipped_duplicate", "issue_number", "errors",
    "video", "video_bytes", "video_reason",
)


def _load(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def validate_command(doc: dict) -> tuple[bool, str]:
    if not isinstance(doc, dict):
        return False, "not_object"
    if not str(doc.get("id", "")).strip():
        return False, "missing_id"
    action = doc.get("action")
    if action not in ACTIONS:
        return False, "unknown_action"
    payload = doc.get("payload", {})
    if not isinstance(payload, dict):
        return False, "invalid_payload"
    if action in {"press", "hold"}:
        if payload.get("input") not in INPUTS:
            return False, "unknown_input"
    if action == "file_feedback":
        message = payload.get("message", "")
        if not isinstance(message, str) or message == "":
            return False, "empty_message"
        if len(message) > MESSAGE_MAX:
            return False, "message_too_long"
        if not message.startswith(MESSAGE_PREFIX):
            return False, "missing_agent_play_prefix"
        if "live" in payload and not isinstance(payload["live"], bool):
            return False, "live_not_bool"
    return True, ""


def validate_observation(doc: dict) -> tuple[bool, str]:
    if not isinstance(doc, dict):
        return False, "not_object"
    for key in (
        "command_id", "screen", "monitors", "tile", "trace_tail",
        "ui_tree", "exceptions", "stuck", "feedback",
    ):
        if key not in doc:
            return False, f"missing_{key}"
    monitors = doc["monitors"]
    if not isinstance(monitors, dict):
        return False, "monitors_not_object"
    for key in ("game/current_screen", "game/party_size", "game/world_seed"):
        if key not in monitors:
            return False, f"missing_monitor_{key}"
    tile = doc["tile"]
    if tile is not None and not (
        isinstance(tile, list) and len(tile) == 2
    ):
        return False, "tile_shape"
    if not isinstance(doc["trace_tail"], list):
        return False, "trace_tail_not_list"
    if not isinstance(doc["ui_tree"], dict):
        return False, "ui_tree_not_object"
    if not isinstance(doc["exceptions"], list):
        return False, "exceptions_not_list"
    if not isinstance(doc["stuck"], bool):
        return False, "stuck_not_bool"
    return True, ""


def validate_report(doc: dict) -> tuple[bool, str]:
    if not isinstance(doc, dict):
        return False, "not_object"
    for key in SKIP_KEYS:
        if key not in doc:
            return False, f"missing_{key}"
    if not isinstance(doc["ok"], bool) or not isinstance(doc["skipped"], bool):
        return False, "ok_skipped_not_bool"
    if not isinstance(doc["reason"], str):
        return False, "reason_not_string"
    if doc.get("skipped") and doc.get("ok") is not True:
        return False, "skip_must_be_ok"
    return True, ""


def _load_findings():
    path = TOOLS / "play_agent_findings.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("play_agent_findings", path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class AgentStepContractTests(unittest.TestCase):
    def test_valid_press_parses(self) -> None:
        ok, err = validate_command(_load("command_press_valid.json"))
        self.assertTrue(ok, err)

    def test_valid_file_feedback_parses(self) -> None:
        ok, err = validate_command(_load("command_file_feedback_valid.json"))
        self.assertTrue(ok, err)

    def test_valid_quit_parses(self) -> None:
        ok, err = validate_command(_load("command_quit_valid.json"))
        self.assertTrue(ok, err)

    def test_file_feedback_rejects_missing_prefix(self) -> None:
        ok, err = validate_command(_load("command_file_feedback_no_prefix.json"))
        self.assertFalse(ok)
        self.assertEqual(err, "missing_agent_play_prefix")

    def test_file_feedback_rejects_empty(self) -> None:
        ok, err = validate_command(_load("command_file_feedback_empty.json"))
        self.assertFalse(ok)
        self.assertEqual(err, "empty_message")

    def test_file_feedback_rejects_1001_chars(self) -> None:
        message = MESSAGE_PREFIX + "x" * (MESSAGE_MAX - len(MESSAGE_PREFIX) + 1)
        self.assertEqual(len(message), MESSAGE_MAX + 1)
        ok, err = validate_command({
            "id": "bad3",
            "action": "file_feedback",
            "payload": {"message": message, "live": False},
        })
        self.assertFalse(ok)
        self.assertEqual(err, "message_too_long")

    def test_unknown_action_rejected(self) -> None:
        ok, err = validate_command(_load("command_unknown_action.json"))
        self.assertFalse(ok)
        self.assertEqual(err, "unknown_action")

    def test_observation_fixture_shape(self) -> None:
        ok, err = validate_observation(_load("observation_valid.json"))
        self.assertTrue(ok, err)

    def test_report_fixture_shape(self) -> None:
        report = _load("report_valid.json")
        ok, err = validate_report(report)
        self.assertTrue(ok, err)
        for key in REPORT_KEYS:
            self.assertIn(key, report)

    def test_headless_skip_envelope(self) -> None:
        skip = _load("report_skip.json")
        ok, err = validate_report(skip)
        self.assertTrue(ok, err)
        self.assertTrue(skip["ok"])
        self.assertTrue(skip["skipped"])
        self.assertTrue(skip["reason"])

    def test_novelty_signature_format_when_u4_present(self) -> None:
        findings = _load_findings()
        if findings is None:
            self.skipTest("play_agent_findings not landed yet")
        sig = findings.signature(_load("observation_valid.json"))
        parts = sig.split("|")
        self.assertEqual(len(parts), 5)
        self.assertEqual(parts[0], "overworld")
        self.assertEqual(parts[1], "3,4")
        self.assertNotIn("/home/", sig)
        self.assertNotIn("user://", sig)


if __name__ == "__main__":
    unittest.main()
