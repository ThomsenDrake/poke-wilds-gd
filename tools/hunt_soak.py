#!/usr/bin/env python3
"""Standalone unattended hunt launcher. Not a verify_all lane.

Writes name-only .godot-smoke/scenario.json plus minutes in
hunt-request.json (consume-once boot deletes scenario.json). Launches
windowed Godot and points at .godot-smoke/hunt-inbox/<run>/. Headless or
PLAYTEST_FORCE_HEADLESS reports SKIP-with-reason and exits 0.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT_BIN = os.environ.get(
    "GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot"
)
FORCE_HEADLESS_ENV = "PLAYTEST_FORCE_HEADLESS"
SCENARIO = "hunt_soak"
DEFAULT_MINUTES = 15
WINDOWED_ONLY = True
MODEL_CAP = 8


def force_headless() -> bool:
    return os.environ.get(FORCE_HEADLESS_ENV, "").lower() not in (
        "", "0", "false", "no", "off",
    )


def skip_reason() -> str:
    return (
        f"windowed-only hunt soak skipped under {FORCE_HEADLESS_ENV} "
        "(unattended hunt needs a real window and renderer)"
    )


def rank_keeps(rows: list[dict]) -> list[dict]:
    def key(row: dict) -> tuple[int, int]:
        tag = str(row.get("tag", ""))
        order = 0 if tag == "coded" else 1 if tag == "model" else 2
        return (order, int(row.get("ts_msec", 0)))

    return sorted(rows, key=key)


def apply_model_keeps(
    rows: list[dict],
    verdicts: list[dict],
    cap: int = MODEL_CAP,
) -> list[dict]:
    """Promote cadence stills the model marked looked-off, up to cap."""
    kept = 0
    by_id = {str(row.get("id")): row for row in rows}
    for verdict in verdicts:
        if kept >= cap:
            break
        if not verdict.get("looked_off"):
            continue
        keep_id = str(verdict.get("id", ""))
        row = by_id.get(keep_id)
        if row is None or str(row.get("tag")) != "still":
            continue
        row["tag"] = "model"
        row["trigger"] = str(verdict.get("trigger", "model_looked_off"))
        kept += 1
    return rank_keeps(rows)


def write_request(project: Path, minutes: int) -> Path:
    smoke = project / ".godot-smoke"
    smoke.mkdir(parents=True, exist_ok=True)
    path = smoke / "scenario.json"
    path.write_text(json.dumps({"scenario": SCENARIO}), encoding="utf-8")
    (smoke / "hunt-request.json").write_text(
        json.dumps({"minutes": minutes}), encoding="utf-8"
    )
    return path


def cleanup_request(project: Path) -> None:
    smoke = project / ".godot-smoke"
    for name in ("scenario.json", "hunt-request.json"):
        path = smoke / name
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def latest_run_dir(project: Path) -> Path | None:
    root = project / ".godot-smoke" / "hunt-inbox"
    runs_path = root / "runs.json"
    if runs_path.is_file():
        try:
            data = json.loads(runs_path.read_text(encoding="utf-8"))
            latest = str(data.get("latest") or "")
            if latest and (root / latest).is_dir():
                return root / latest
        except json.JSONDecodeError:
            pass
    if not root.is_dir():
        return None
    runs = sorted(path for path in root.iterdir() if path.is_dir())
    return runs[-1] if runs else None


def _skipped_report(reason: str) -> dict:
    return {
        "scenario": SCENARIO,
        "skipped": True,
        "skipped_reason": reason,
        "ok": True,
        "inbox": None,
    }


def run_hunt(
    project: Path,
    godot_bin: str,
    minutes: int,
    reviewer=None,
) -> dict:
    if force_headless():
        return _skipped_report(skip_reason())
    before = latest_run_dir(project)
    write_request(project, minutes)
    timeout = max(60, minutes * 60 + 30)
    proc: subprocess.Popen | None = None
    try:
        try:
            proc = subprocess.Popen(
                [godot_bin, "--path", str(project)],
                cwd=str(project),
            )
        except OSError as exc:
            return {
                "scenario": SCENARIO,
                "skipped": False,
                "ok": False,
                "error": str(exc),
                "inbox": None,
            }

        def _stop(_signum=None, _frame=None) -> None:
            if proc and proc.poll() is None:
                proc.terminate()

        signal.signal(signal.SIGINT, _stop)
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _stop()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        inbox = latest_run_dir(project)
        new_run = inbox is not None and inbox != before
        report = {
            "scenario": SCENARIO,
            "skipped": False,
            "ok": new_run,
            "inbox": str(inbox) if new_run else None,
            "minutes": minutes,
        }
        if new_run and reviewer is not None:
            index_path = inbox / "index.json"
            if index_path.is_file():
                payload = json.loads(index_path.read_text(encoding="utf-8"))
                rows = list(payload.get("keeps") or [])
                verdicts = reviewer(rows)
                payload["keeps"] = apply_model_keeps(rows, verdicts)
                index_path.write_text(json.dumps(payload), encoding="utf-8")
                report["model"] = "judged"
        elif new_run:
            report["model"] = "skipped"
            report["model_reason"] = "no Command Code reviewer configured"
        return report
    finally:
        cleanup_request(project)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=str(ROOT))
    parser.add_argument("--godot-bin", default=DEFAULT_GODOT_BIN)
    parser.add_argument("--minutes", type=int, default=DEFAULT_MINUTES)
    parser.add_argument(
        "--check",
        action="store_true",
        help="print windowed-only guard status and exit 0",
    )
    args = parser.parse_args(argv)
    if args.check:
        print(
            f"WINDOWED_ONLY={WINDOWED_ONLY} SCENARIO={SCENARIO} "
            f"DEFAULT_MINUTES={DEFAULT_MINUTES}"
        )
        return 0
    project = Path(args.project).expanduser().resolve()
    if not (project / "project.godot").exists():
        print(f"error: no project.godot at {project}", file=sys.stderr)
        return 2
    report = run_hunt(project, args.godot_bin, max(1, args.minutes))
    print(json.dumps(report))
    if report.get("inbox"):
        print(f"inbox: {report['inbox']}", file=sys.stderr)
    return 0 if report.get("ok") or report.get("skipped") else 1


if __name__ == "__main__":
    sys.exit(main())
