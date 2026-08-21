#!/usr/bin/env python3
"""Inbox ranking and per-run folder contract for the unattended hunt."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "hunt_soak_under_test", ROOT / "tools/hunt_soak.py"
)
assert SPEC is not None and SPEC.loader is not None
HUNT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HUNT)


def _row(keep_id: str, tag: str, ts: int) -> dict:
    return {"id": keep_id, "tag": tag, "ts_msec": ts, "trigger": tag}


class HuntInboxTests(unittest.TestCase):
    def test_coded_rows_sort_before_model(self) -> None:
        rows = [
            _row("model-01", "model", 1),
            _row("coded-02", "coded", 20),
            _row("model-02", "model", 2),
            _row("coded-01", "coded", 10),
        ]
        ranked = HUNT.rank_keeps(rows)
        self.assertEqual(
            [row["id"] for row in ranked],
            ["coded-01", "coded-02", "model-01", "model-02"],
        )

    def test_empty_index_is_a_list_not_missing(self) -> None:
        ranked = HUNT.rank_keeps([])
        self.assertEqual(ranked, [])

    def test_second_run_folder_does_not_replace_the_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "hunt-inbox"
            first = root / "20260821-150000"
            second = root / "20260821-160000"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            (first / "index.json").write_text(
                json.dumps({"run_id": first.name, "keeps": [_row("c1", "coded", 1)]}),
                encoding="utf-8",
            )
            (second / "index.json").write_text(
                json.dumps({"run_id": second.name, "keeps": []}),
                encoding="utf-8",
            )
            (root / "runs.json").write_text(
                json.dumps({"runs": [second.name, first.name], "latest": second.name}),
                encoding="utf-8",
            )
            first_keeps = json.loads((first / "index.json").read_text(encoding="utf-8"))
            self.assertEqual(first_keeps["keeps"][0]["id"], "c1")
            self.assertTrue((second / "index.json").is_file())

    def test_failed_clip_row_does_not_break_rank(self) -> None:
        rows = [_row("coded-01", "coded", 1), {"id": "bad", "tag": "model"}]
        ranked = HUNT.rank_keeps(rows)
        self.assertEqual(ranked[0]["id"], "coded-01")
        self.assertEqual(ranked[1]["id"], "bad")


if __name__ == "__main__":
    unittest.main()
