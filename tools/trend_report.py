#!/usr/bin/env python3
"""Trend report (Track D) — cross-run history + a local HTML dashboard for the
verify_all gate.

History store: .godot-smoke/history/verify-runs.jsonl — one slim record per
verify_all run, appended by verify_all._write_result (the single writer; this
file is gitignored machine-local state, never a committed ledger — the
graduation-ledger ritual owns curated history). verify_all calls append+render
after writing its own result JSON; a failure here is a stderr warning, NEVER a
gate red.

Dashboard: .godot-smoke/trend-report.html — self-contained (inline CSS, no JS,
no external assets): recent-runs table, a step-status heatmap over the last
runs, and per-run duration bars. Render standalone with:

  python3 tools/trend_report.py            # history -> .godot-smoke/trend-report.html
"""
from __future__ import annotations

import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HISTORY_PATH = ROOT / ".godot-smoke" / "history" / "verify-runs.jsonl"
HTML_PATH = ROOT / ".godot-smoke" / "trend-report.html"
MAX_HISTORY = 200  # records read for rendering (oldest dropped)
HEATMAP_RUNS = 15  # columns in the step-status heatmap
TABLE_RUNS = 25

_STATUS_COLOR = {"pass": "#2da44e", "fail": "#cf222e", "skip": "#9a6700",
                 "tool_error": "#bf3989"}


def slim_record(result: dict) -> dict:
    """The history record for one verify_all run — slim on purpose: step names,
    statuses, durations, and the summary counts, never output tails."""
    return {
        "ts": result.get("generated_at"),
        "head_sha": result.get("head_sha"),
        "exit_code": result.get("exit_code"),
        "duration_s": result.get("duration_s"),
        "skip_windowed": bool(result.get("skip_windowed")),
        "steps": [{"n": s.get("name"), "s": s.get("status"), "d": s.get("duration_s")}
                  for s in result.get("steps") or [] if isinstance(s, dict)],
        "summary": result.get("summary") or {},
    }


def append_history(record: dict, history_path: Path = HISTORY_PATH) -> int:
    """Append one JSONL record; returns the stored record count. Compacts on
    threshold — when the store exceeds 2x MAX_HISTORY it is rewritten keeping
    the newest MAX_HISTORY — so a per-run artifact never grows without bound."""
    history_path.parent.mkdir(parents=True, exist_ok=True)
    with history_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")
    try:
        lines = history_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return 1
    if len(lines) > MAX_HISTORY * 2:
        lines = lines[-MAX_HISTORY:]
        history_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def load_history(history_path: Path = HISTORY_PATH, cap: int = MAX_HISTORY) -> list[dict]:
    try:
        lines = history_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    records = []
    for line in lines[-cap:]:
        try:
            rec = json.loads(line)
        except ValueError:
            continue  # a torn line (killed writer) is skipped, never fatal
        if isinstance(rec, dict):
            records.append(rec)
    return records


def _esc(value) -> str:
    return html.escape(str(value if value is not None else ""))


def _cell(status: str) -> str:
    color = _STATUS_COLOR.get(status, "#57606a")
    return f'<td class="hm" title="{_esc(status)}"><span style="background:{color}"></span></td>'


def render_html(records: list[dict]) -> str:
    latest = records[-1] if records else {}
    step_names: list[str] = []
    for rec in records:
        for step in rec.get("steps") or []:
            name = str(step.get("n"))
            if name not in step_names:
                step_names.append(name)
    recent = records[-HEATMAP_RUNS:]
    max_dur = max((float(r.get("duration_s") or 0) for r in records), default=1.0) or 1.0

    rows: list[str] = []
    rows.append("<!doctype html><html><head><meta charset='utf-8'>")
    rows.append("<title>verify_all trend</title><style>")
    rows.append("body{font:14px/1.4 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;margin:24px;color:#1f2328}"
                "h1{font-size:20px} h2{font-size:15px;margin-top:28px}"
                "table{border-collapse:collapse} td,th{border:1px solid #d0d7de;padding:3px 8px;text-align:left}"
                "th{background:#f6f8fa} .ok{color:#2da44e} .bad{color:#cf222e;font-weight:600}"
                ".hm{padding:2px 3px} .hm span{display:block;width:12px;height:12px;border-radius:2px}"
                ".bar{height:10px;background:#8250df;border-radius:2px;display:inline-block}"
                ".meta{color:#57606a;font-size:12px}")
    rows.append("</style></head><body>")
    rows.append("<h1>verify_all trend</h1>")
    rows.append(f"<p class='meta'>{len(records)} run(s) recorded; latest {_esc(latest.get('ts'))} "
                f"head {_esc(str(latest.get('head_sha'))[:10])} — machine-local history "
                "(.godot-smoke/history/verify-runs.jsonl), regenerated by tools/trend_report.py</p>")

    rows.append("<h2>Step status heatmap (recent runs)</h2>")
    rows.append("<table><tr><th>step</th>" + "".join(
        f"<th>{_esc(str(r.get('head_sha'))[:7])}<br>{_esc(str(r.get('ts'))[5:16])}</th>"
        for r in recent) + "</tr>")
    for name in step_names:
        cells = []
        for rec in recent:
            status = next((str(s.get("s")) for s in rec.get("steps") or [] if s.get("n") == name), "")
            cells.append(_cell(status))
        rows.append(f"<tr><td>{_esc(name)}</td>{''.join(cells)}</tr>")
    rows.append("</table>")

    rows.append("<h2>Duration (total, seconds)</h2>")
    rows.append("<table><tr><th>run</th><th>exit</th><th></th></tr>")
    for rec in recent:
        dur = float(rec.get("duration_s") or 0)
        width = max(2, int(240 * dur / max_dur))
        ok = rec.get("exit_code") == 0
        rows.append(f"<tr><td>{_esc(str(rec.get('ts'))[5:16])}</td>"
                    f"<td class='{'ok' if ok else 'bad'}'>{_esc(rec.get('exit_code'))}</td>"
                    f"<td><span class='bar' style='width:{width}px'></span> {dur:.0f}s</td></tr>")
    rows.append("</table>")

    rows.append(f"<h2>Recent runs (last {TABLE_RUNS})</h2>")
    rows.append("<table><tr><th>time</th><th>head</th><th>exit</th><th>dur s</th>"
                "<th>passed</th><th>failed</th><th>skipped</th><th>refusals</th><th>tool errors</th></tr>")
    for rec in reversed(records[-TABLE_RUNS:]):
        summary = rec.get("summary") or {}
        ok = rec.get("exit_code") == 0
        rows.append(
            f"<tr><td>{_esc(rec.get('ts'))}</td><td>{_esc(str(rec.get('head_sha'))[:10])}</td>"
            f"<td class='{'ok' if ok else 'bad'}'>{_esc(rec.get('exit_code'))}</td>"
            f"<td>{_esc(rec.get('duration_s'))}</td><td>{_esc(summary.get('passed'))}</td>"
            f"<td>{_esc(summary.get('failed'))}</td><td>{_esc(summary.get('skipped'))}</td>"
            f"<td>{_esc(summary.get('refusals'))}</td><td>{_esc(summary.get('tool_errors'))}</td></tr>")
    rows.append("</table></body></html>")
    return "\n".join(rows)


def render(html_path: Path = HTML_PATH, history_path: Path = HISTORY_PATH) -> int:
    records = load_history(history_path)
    html_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.write_text(render_html(records), encoding="utf-8")
    return len(records)


def main() -> int:
    count = render()
    if count == 0:
        print("trend_report: no history yet (verify_all appends one record per run)")
        return 0
    print(f"trend_report: {count} run(s) -> {HTML_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
