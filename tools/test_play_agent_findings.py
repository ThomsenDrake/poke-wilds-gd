#!/usr/bin/env python3
"""Pure tests for play_agent_findings (no Godot, no network)."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from play_agent_findings import detect_anomalies, evaluate_novelty, signature

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "agent_step"


def _obs(**overrides) -> dict:
    base = json.loads((FIXTURES / "observation_valid.json").read_text(encoding="utf-8"))
    base.update(overrides)
    return base


class PlayAgentFindingsTests(unittest.TestCase):
    def test_empty_observation_has_no_anomaly(self) -> None:
        self.assertEqual(detect_anomalies({}), [])
        verdict = evaluate_novelty({})
        self.assertFalse(verdict["anomaly"])
        self.assertFalse(verdict["novel"])
        self.assertEqual(verdict["reason"], "no_anomaly")

    def test_valid_fixture_is_quiet(self) -> None:
        obs = _obs()
        self.assertEqual(detect_anomalies(obs), [])
        sig = signature(obs)
        self.assertEqual(sig.split("|")[0], "overworld")
        self.assertEqual(sig.split("|")[1], "3,4")
        self.assertEqual(len(sig.split("|")), 5)
        self.assertNotIn("/home/", sig)

    def test_exception_is_anomaly_and_novel(self) -> None:
        obs = _obs(exceptions=["NullRef: planted"])
        verdict = evaluate_novelty(obs)
        self.assertTrue(verdict["anomaly"])
        self.assertTrue(verdict["novel"])
        self.assertTrue(verdict["live_fileable"])
        self.assertEqual(verdict["reason"], "novel")

    def test_same_signature_twice_is_duplicate(self) -> None:
        obs = _obs(exceptions=["NullRef: planted"], stuck=False)
        first = evaluate_novelty(obs)
        second = evaluate_novelty(obs, session_signatures=[first["signature"]])
        self.assertTrue(second["anomaly"])
        self.assertFalse(second["novel"])
        self.assertEqual(second["reason"], "duplicate")

    def test_prior_findings_signature_skips(self) -> None:
        obs = _obs(exceptions=["NullRef: planted"])
        sig = signature(obs)
        verdict = evaluate_novelty(obs, prior_findings=[{"signature": sig}])
        self.assertEqual(verdict["reason"], "duplicate")

    def test_different_screen_same_exception_is_novel(self) -> None:
        first = _obs(screen="overworld", exceptions=["NullRef"])
        second = _obs(screen="menu", exceptions=["NullRef"])
        verdict = evaluate_novelty(second, session_signatures=[signature(first)])
        self.assertTrue(verdict["novel"])
        self.assertNotEqual(signature(first), signature(second))

    def test_stuck_is_anomaly(self) -> None:
        verdict = evaluate_novelty(_obs(stuck=True))
        self.assertTrue(verdict["anomaly"])
        self.assertIn("stuck", verdict["anomalies"])

    def test_failed_trace_is_anomaly(self) -> None:
        obs = _obs(trace_tail=[{"event": "nav_audit_failed", "payload": {}}])
        verdict = evaluate_novelty(obs)
        self.assertTrue(verdict["anomaly"])
        self.assertTrue(any(item.startswith("failed:") for item in verdict["anomalies"]))

    def test_quarantine_only_is_not_live_fileable(self) -> None:
        obs = _obs()
        verdict = evaluate_novelty(
            obs,
            prior_findings=[{"finding_id": "vision-1", "tier": "quarantine", "source": "vlm"}],
        )
        self.assertFalse(verdict["live_fileable"])
        self.assertFalse(verdict["anomaly"])

    def test_github_issue_duplicate(self) -> None:
        obs = _obs(exceptions=["NullRef"])
        issues = ["[agent-play] overworld NullRef already filed"]
        verdict = evaluate_novelty(obs, github_issues=issues)
        self.assertEqual(verdict["reason"], "duplicate")

    def test_signature_omits_home_paths(self) -> None:
        obs = _obs(
            exceptions=["boom at /home/ubuntu/secret.gd"],
            ui_tree={"nodes": [{"path": ".", "type": "Control", "text": "/home/ubuntu/x"}]},
        )
        sig = signature(obs)
        self.assertNotIn("/home/ubuntu", sig)
        self.assertNotIn("secret.gd", sig)

    def test_compact_turn_and_coverage(self) -> None:
        from play_agent_findings import compact_turn, coverage_from_turns, world_seed_of
        command = {"id": "t1", "action": "hold", "payload": {"input": "move_right"}}
        obs = _obs()
        turn = compact_turn(command, obs)
        self.assertEqual(turn["action"], "hold")
        self.assertEqual(turn["screen"], "overworld")
        self.assertEqual(turn["tile"], [3, 4])
        self.assertEqual(world_seed_of(obs), 2026080702)
        coverage = coverage_from_turns([turn, {"action": "press", "payload": {"input": "action_a"}, "screen": "battle"}])
        self.assertEqual(coverage["screens"], ["overworld", "battle"])
        self.assertIn("hold:move_right", coverage["verbs"])

    def test_finding_pack_round_trip_and_replay(self) -> None:
        from play_agent_findings import (
            build_finding_pack, commands_from_source, compact_turn,
            load_replay_source, merge_prior_ledger, replay_commands,
            save_prior_ledger, write_finding_pack,
        )
        obs = _obs(exceptions=["NullRef: planted"])
        command = {"id": "t1", "action": "boot_new_game", "payload": {}}
        pack = build_finding_pack(
            obs,
            [compact_turn(command, obs)],
            anomalies=["exception:NullRef: planted"],
            video=".godot-smoke/play_agent_loop.mp4",
            report=".godot-smoke/play_agent_loop.json",
        )
        self.assertEqual(pack["schema"], "play_agent_finding/1")
        self.assertEqual(pack["world_seed"], 2026080702)
        self.assertNotIn("nodes", pack["observation"].get("ui_tree") or {})
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = write_finding_pack(root / "play_agent_findings", pack)
            self.assertTrue(path.is_file())
            self.assertNotIn("|", path.name)
            loaded = json.loads(path.read_text(encoding="utf-8"))
            cmds = replay_commands(loaded)
            self.assertEqual(len(cmds), 1)
            self.assertEqual(cmds[0]["action"], "boot_new_game")
            with_file = commands_from_source({
                "commands": cmds + [{"id": "t2", "action": "file_feedback", "payload": {"message": "[agent-play] x"}}],
            })
            self.assertEqual(len(replay_commands({"commands": with_file})), 1)
            missing_cmds, err = load_replay_source(root / "missing.json")
            self.assertEqual(missing_cmds, [])
            self.assertEqual(err["code"], "replay_source_missing")
            empty_path = root / "empty.json"
            empty_path.write_text("{}", encoding="utf-8")
            _, empty_err = load_replay_source(empty_path)
            self.assertEqual(empty_err["code"], "replay_missing_commands")
            ledger_path = root / "play_agent_prior.json"
            merged = merge_prior_ledger([], [pack, pack])
            self.assertEqual(len(merged), 1)
            save_prior_ledger(ledger_path, merged)
            self.assertTrue(ledger_path.is_file())

    def test_file_message_is_bounded_and_prefixed(self) -> None:
        from play_agent_findings import MESSAGE_MAX, MESSAGE_PREFIX, file_message
        obs = _obs(exceptions=["NullRef: planted"])
        commands = [
            {"action": "boot_new_game", "payload": {}},
            {"action": "hold", "payload": {"input": "move_right"}},
        ]
        message = file_message(obs, commands)
        self.assertTrue(message.startswith(MESSAGE_PREFIX))
        self.assertLessEqual(len(message), MESSAGE_MAX)
        self.assertIn("seed 2026080702", message)
        self.assertIn("boot_new_game", message)
        self.assertNotIn("/home/", message)


if __name__ == "__main__":
    unittest.main()
