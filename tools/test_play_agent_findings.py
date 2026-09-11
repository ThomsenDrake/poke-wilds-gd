#!/usr/bin/env python3
"""Pure tests for play_agent_findings (no Godot, no network)."""

from __future__ import annotations

import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
