#!/usr/bin/env python3
"""Launcher honesty and model-cap tests for the unattended hunt."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "hunt_soak_under_test", ROOT / "tools/hunt_soak.py"
)
assert SPEC is not None and SPEC.loader is not None
HUNT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HUNT)


class HuntSoakLauncherTests(unittest.TestCase):
    def test_check_exits_zero(self) -> None:
        self.assertEqual(HUNT.main(["--check"]), 0)

    def test_headless_skip_with_reason(self) -> None:
        with mock.patch.dict("os.environ", {HUNT.FORCE_HEADLESS_ENV: "1"}):
            report = HUNT.run_hunt(ROOT, "godot", 1)
        self.assertTrue(report["skipped"])
        self.assertTrue(report["ok"])
        self.assertIn("windowed-only", report["skipped_reason"])

    def test_write_request_includes_minutes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            path = HUNT.write_request(project, 3)
            payload = json.loads(path.read_text(encoding="utf-8"))
            budget = json.loads(
                (project / ".godot-smoke" / "hunt-request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(payload["scenario"], "hunt_soak")
            self.assertEqual(budget["minutes"], 3)

    def test_model_looked_off_ranks_below_coded(self) -> None:
        rows = [
            {"id": "still-01", "tag": "still", "ts_msec": 5},
            {"id": "coded-01", "tag": "coded", "ts_msec": 1},
        ]
        ranked = HUNT.apply_model_keeps(
            rows, [{"id": "still-01", "looked_off": True}], cap=8
        )
        self.assertEqual([row["id"] for row in ranked], ["coded-01", "still-01"])
        self.assertEqual(ranked[1]["tag"], "model")

    def test_model_cap_stops_further_keeps(self) -> None:
        rows = [
            {"id": f"still-{i:02d}", "tag": "still", "ts_msec": i}
            for i in range(4)
        ]
        verdicts = [{"id": f"still-{i:02d}", "looked_off": True} for i in range(4)]
        ranked = HUNT.apply_model_keeps(rows, verdicts, cap=2)
        self.assertEqual(sum(1 for row in ranked if row["tag"] == "model"), 2)
        self.assertEqual(sum(1 for row in ranked if row["tag"] == "still"), 2)

    def test_missing_reviewer_leaves_coded_keeps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "project.godot").write_text("", encoding="utf-8")
            run = project / ".godot-smoke" / "hunt-inbox" / "20260821-150000"
            run.mkdir(parents=True)
            (run / "index.json").write_text(
                json.dumps({"run_id": run.name, "keeps": [{"id": "c1", "tag": "coded", "ts_msec": 1}]}),
                encoding="utf-8",
            )
            (project / ".godot-smoke" / "hunt-inbox" / "runs.json").write_text(
                json.dumps({"latest": run.name, "runs": [run.name]}),
                encoding="utf-8",
            )
            with mock.patch.object(HUNT.subprocess, "Popen", side_effect=OSError("no godot")):
                report = HUNT.run_hunt(project, "missing-godot", 1)
            self.assertFalse(report["ok"])
            self.assertIsNone(report["inbox"])
            keeps = json.loads((run / "index.json").read_text(encoding="utf-8"))["keeps"]
            self.assertEqual(keeps[0]["tag"], "coded")
            self.assertFalse((project / ".godot-smoke" / "scenario.json").exists())
            self.assertFalse((project / ".godot-smoke" / "hunt-request.json").exists())

    def test_launch_failure_does_not_reuse_prior_inbox(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "project.godot").write_text("", encoding="utf-8")
            prior = project / ".godot-smoke" / "hunt-inbox" / "20260821-140000"
            prior.mkdir(parents=True)
            (prior / "index.json").write_text(
                json.dumps({"run_id": prior.name, "keeps": []}),
                encoding="utf-8",
            )
            with mock.patch.object(HUNT.subprocess, "Popen", side_effect=OSError("no godot")):
                report = HUNT.run_hunt(project, "missing-godot", 1)
            self.assertFalse(report["ok"])
            self.assertIsNone(report["inbox"])


if __name__ == "__main__":
    unittest.main()
