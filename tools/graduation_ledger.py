"""Graduation ledger + calibration for the per-state pixel-half graduation (Slice 6).

Spec: docs/superpowers/plans/2026-07-20-agent-legibility-and-vision-verification.md
(Workstream L.5) and docs/product-specs/vision-fidelity.md § Graduation ledger &
calibration.

ARTIFACT: docs/generated/graduation-ledger.json — TRACKED (sibling of
legibility-report.md and visual-baselines/), canonical JSON (indent 2, sorted keys,
git-diffable) because streaks must be COMPUTED from entries, never narrated. The
human-readable rendering lives in the "Graduation & calibration" section of
tools/generate_legibility_report.py (render_section below; missing ledger => a "not
yet recorded" note, never an error). .godot-smoke/ is gitignored, so the evidence
binder cannot live there.

CALIBRATION PRINCIPLE: the existing quarantine->graduation pipeline IS the free
calibration loop — every pixel finding fires as a `quarantine_finding` trace FIRST
(ui_render_audit.gd emits the trace for every finding, then appends to `_failures`
only if the state is graduated), so a graduated-state red leaves the same joinable
record as a quarantine finding. No new engine events; all joins are over recorded
data: audit pixel findings by (state, kind family, overlapping stage-px region),
Lane-4 vision_review findings by their stable `finding_id`.

WHO RUNS IT: a human/agent ritual, NOT a runner post-step (decided, justified):
(1) the ledger is TRACKED evidence — a runner post-step would mutate a committed
artifact on every run (git noise, accidental-commit hazard), unlike the report and
the quarantine fields which live in gitignored .godot-smoke/; (2) `record` needs the
machine-local user:// JSONL join, which would couple run_playtests.py to userdata
path resolution; (3) the runner already persists everything per run in the report —
the ledger is the explicit, attested evidence binder on top. RELIABILITY.md documents
the ritual: run --scenario ui_render_audit && graduation_ledger.py record (sequential),
then commit the ledger with the flip.

STDLIB-ONLY core tool (json/argparse/pathlib/datetime/subprocess/re/sys/importlib);
it auto-passes the core_tools_stdlib guard. The optional vision extra
(tools/vision_metrics.py, scikit-image) is the ONE documented guard-exempt tool and
is NEVER imported here.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "graduation-ledger/1"
THRESHOLD = 5
STATES = ["battle_action", "battle_message", "battle_moves", "battle_item"]
FLIP_ORDER = ["battle_moves", "battle_item", "battle_action", "battle_message"]  # documented order: anchor states first, lint next, box last
PREDECESSORS = {"battle_action": ["battle_moves", "battle_item"], "battle_message": ["battle_action"]}
ELIGIBLE_TRANSPORTS = {"windowed", "dap"}
# Kinds that break per-state cleanliness: the UNION of text_oracle.check() kinds
# (glyph_mismatch/clipped/low_ink/garble) and visual_lint.py kinds (low_ink/
# forbidden_ink/garble) plus lint_unavailable — the missing-evidence verdict from
# UiRenderModel.run_lint. Missing evidence breaks cleanliness, it never passes it.
CLEAN_BREAKING_KINDS = {"glyph_mismatch", "clipped", "low_ink", "garble", "forbidden_ink", "lint_unavailable"}
# Defect families for confirmation joins: glyph_mismatch/garble/low_ink/clipped are
# ONE text-ink family; forbidden_ink is alone; lint_unavailable (missing evidence)
# and unknown kinds are their own family each and can only match themselves.
TEXT_INK_FAMILY = {"glyph_mismatch", "clipped", "low_ink", "garble"}
EXPECTED_ORACLE = {"states_checked": 4, "T_str": 2, "T_glyph": 1}  # calibrated constants; drift invalidates the entry
SAMPLE_CAP = 8  # dirty-run sample payloads embedded per state (keeps the ledger small)
CADENCE = ("weekly, aligned to the legibility-garden workflow (Mon 14:00 UTC); "
           "a trend needs >=2 cycles")
SHOT_STATE_MAP = {"10_battle_moves": "battle_moves", "12_battle_items": "battle_item"}
# 09_battle / 11_battle_after_attack have no single audit state => UNJOINED, never faked.


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def git_head_sha(root: Path) -> str | None:
    try:
        result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root,
                                capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _project_name(root: Path) -> str:
    try:
        for line in (root / "project.godot").read_text(encoding="utf-8").splitlines():
            match = re.match(r'\s*config/name\s*=\s*"([^"]+)"', line)
            if match:
                return match.group(1)
    except OSError:
        pass
    return "PokeWilds-Godot"


def default_trace_path(root: Path) -> Path:
    """user:// globalizes per-OS (validated live on this Mac): the append-only
    agent_trace.jsonl under the project-named userdata dir (trace_logger.gd opens
    READ_WRITE + seek_end, no rotation, so line numbers are stable join keys)."""
    name = _project_name(root)
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Godot" / "app_userdata"
    elif sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))) / "Godot" / "app_userdata"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))) / "godot" / "app_userdata"
    return base / name / "logs" / "agent_trace.jsonl"


class LedgerUnreadable(ValueError):
    """A ledger file that EXISTS but cannot be parsed (or is not a JSON object) —
    deliberately distinct from a MISSING ledger (which starts a fresh empty one).
    `record`/`calibration` REFUSE on this rather than silently reset, so a corrupt
    TRACKED evidence binder is never clobbered by a fresh empty ledger."""


def _empty_ledger() -> dict:
    return {"schema": SCHEMA, "threshold": THRESHOLD, "states": list(STATES),
            "runs": [], "flips": [], "calibration": {"cadence": CADENCE, "cycles": []}}


def load_ledger(path: Path) -> dict:
    if not path.exists():
        return _empty_ledger()
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:  # ValueError covers json.JSONDecodeError
        raise LedgerUnreadable(str(exc)) from exc
    if not isinstance(doc, dict):
        raise LedgerUnreadable("top-level JSON is not an object")
    return doc


def save_ledger(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def split_sessions(trace_path: Path) -> list[dict]:
    """Split the append-only JSONL into boot-delimited sessions (one boot_started per
    scenario process launch). Line numbers are 1-based and stable (append-only log,
    no rotation); ts_msec is a BOOT clock (resets per process — no wall-clock join,
    which is why ledger entries embed head_sha and never backfill unstamped history)."""
    sessions: list[dict] = []
    current: dict | None = None
    with trace_path.open(encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue  # valid JSON but not an object (e.g. a bare array) — not a trace record
            event = str(record.get("event", ""))
            if event == "boot_started":
                try:
                    boot_ts_msec = int(record.get("ts_msec", 0))
                except (TypeError, ValueError):
                    boot_ts_msec = 0  # non-numeric boot clock — keep the session, never crash the join
                current = {"start_line": line_no, "end_line": line_no,
                           "boot_ts_msec": boot_ts_msec,
                           "events": {}, "capture_invalid": 0}
                sessions.append(current)
            if current is None:
                continue  # preamble before the first boot of the log
            current["end_line"] = line_no
            if event == "capture_invalid":
                current["capture_invalid"] += 1
            if event:
                payload = record.get("payload", {})
                current["events"].setdefault(event, []).append(payload if isinstance(payload, dict) else {"value": payload})
    return sessions


def _is_audit_session(session: dict) -> bool:
    if "ui_render_audit_passed" in session["events"] or "text_oracle_passed" in session["events"]:
        return True
    return any(isinstance(p, dict) and p.get("state") in STATES
               for p in session["events"].get("quarantine_finding", []))


def graduated_map(root: Path) -> dict:
    """Parse the GRADUATED_STATES const literal from ui_render_audit.gd so status and
    calibration report the LIVE graduated set (the flip's only code edit target)."""
    try:
        text = (root / "scripts" / "app" / "ui_render_audit.gd").read_text(encoding="utf-8")
    except (OSError, ValueError):  # ValueError covers UnicodeDecodeError on a corrupt file
        return {}
    match = re.search(r"const\s+GRADUATED_STATES\s*:=\s*\{([^}]*)\}", text)
    if not match:
        return {}
    return {m.group(1): m.group(2) == "true"
            for m in re.finditer(r'"(\w+)"\s*:\s*(true|false)', match.group(1))}


def _graduated_epoch(flips: list[dict], state: str) -> int | None:
    """A flip applies to runs recorded AFTER its evidence runs: epoch = max
    evidence_run_ids, so run j is post-flip iff j > epoch."""
    epochs = [max(int(e) for e in flip.get("evidence_run_ids") or [0])
              for flip in flips if flip.get("state") == state and flip.get("evidence_run_ids")]
    return max(epochs) if epochs else None


def _vision_explain():
    """importlib-load visual_explain for rects_overlap — the single geometry home,
    never re-implemented here (the sanctioned sibling-tool import pattern)."""
    path = Path(__file__).resolve().with_name("visual_explain.py")
    spec = importlib.util.spec_from_file_location("visual_explain", path)
    if spec is None or spec.loader is None:
        return None
    try:
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:
        return None
    return module


def _overlaps(ve, a, b) -> bool:
    """Stage-px region overlap; a missing/zeroed region (lint_unavailable carries
    [0,0,0,0]) is unjoinable, never faked as an overlap."""
    if ve is None:
        return False
    if not (isinstance(a, list) and isinstance(b, list) and len(a) >= 4 and len(b) >= 4):
        return False
    if not any(a[:4]) or not any(b[:4]):
        return False
    try:
        return bool(ve.rects_overlap([int(v) for v in a[:4]], [int(v) for v in b[:4]]))
    except (TypeError, ValueError):
        return False


def _family(kind: str) -> str:
    if kind in TEXT_INK_FAMILY:
        return "text_ink"
    return kind  # forbidden_ink alone; lint_unavailable/unknown match only themselves


def _norm_oracle(payload) -> dict | None:
    if not isinstance(payload, dict):
        return None
    return {key: payload.get(key) for key in ("states_checked", "strings_checked", "glyphs_checked", "T_str", "T_glyph")}


def _norm_passed(payload) -> dict | None:
    if not isinstance(payload, dict):
        return None
    return {key: payload.get(key) for key in ("states_checked", "labels_checked", "cursors_checked", "quarantined")}


def build_run_entry(report: dict, entry: dict, session: dict, trace_path: Path, doc: dict) -> dict:
    """One self-contained evidence entry: counts + <=8 sample payloads embedded, so
    the committed ledger stays valid even if the JSONL is later deleted."""
    findings_by_state = {state: [] for state in STATES}
    for payload in session["events"].get("quarantine_finding", []):
        if isinstance(payload, dict) and payload.get("state") in findings_by_state:
            findings_by_state[payload["state"]].append(payload)
    oracle_list = session["events"].get("text_oracle_passed", [])
    oracle = _norm_oracle(oracle_list[-1] if oracle_list else None)
    passed_list = session["events"].get("ui_render_audit_passed", [])
    passed = _norm_passed(passed_list[-1] if passed_list else entry.get("passed_payload"))

    anomalies: list[str] = []
    events_seen = set(entry.get("events_seen") or [])
    for name in ("ui_render_audit_passed", "text_oracle_passed"):
        if (name in events_seen) != (name in session["events"]):
            anomalies.append(f"events_seen/session disagree on {name}")
    session_findings = sum(len(items) for items in findings_by_state.values())
    session_quarantined = passed.get("quarantined") if isinstance(passed, dict) else None
    if isinstance(session_quarantined, int) and session_quarantined != session_findings:
        anomalies.append(f"session ui_render_audit_passed quarantined={session_quarantined} but the "
                         f"session carries {session_findings} findings")
    # Report<->session cross-check: the report is single-slot, so a lagged `record`
    # could pair a report from a different run with this session — a quarantined-count
    # mismatch catches the mispairing. An anomaly only clears `eligible` (untrusted
    # evidence): like other missing-evidence ineligibles it neither counts nor breaks
    # a streak (state_streak `continue`s) UNLESS ok=false, when the run is a windowed
    # RED that breaks every state. "Treated as dirty" would overstate it — a dirty
    # entry resets the streak, an anomaly with ok=true is merely skipped.
    report_passed = entry.get("passed_payload")
    if (isinstance(report_passed, dict) and isinstance(report_passed.get("quarantined"), int)
            and report_passed["quarantined"] != session_findings):
        anomalies.append(f"report passed_payload quarantined={report_passed['quarantined']} but the "
                         f"session carries {session_findings} findings")
    if oracle is not None:
        for key, want in EXPECTED_ORACLE.items():
            if oracle.get(key) != want:
                anomalies.append(f"text_oracle {key}={oracle.get(key)!r} != calibrated {want!r} — "
                                 "tolerance drift invalidates the entry (vision-fidelity.md § Tolerance)")
        if not (isinstance(oracle.get("glyphs_checked"), int) and oracle["glyphs_checked"] > 0):
            anomalies.append("text_oracle glyphs_checked missing or not > 0 (blank-mask pass withheld)")

    transport = str(entry.get("transport", ""))
    eligible = (transport in ELIGIBLE_TRANSPORTS
                and "ui_render_audit_passed" in session["events"]
                and "text_oracle_passed" in session["events"]
                and bool(entry.get("ok"))
                and not anomalies)
    states = {}
    for state in STATES:
        state_findings = findings_by_state[state]
        breaking = [f for f in state_findings if str(f.get("kind", "")) in CLEAN_BREAKING_KINDS]
        states[state] = {
            "findings": len(state_findings),
            "kinds": sorted({str(f.get("kind", "")) for f in state_findings}),
            "clean": eligible and not breaking,
            "sample": breaking[:SAMPLE_CAP],  # raw payloads when dirty; [] when clean
        }
    return {
        "id": max((int(run.get("id", 0)) for run in doc.get("runs", [])), default=0) + 1,
        "head_sha": report.get("head_sha"),  # always present in the report (git rev-parse HEAD)
        "recorded_at": utc_now(),
        "scenario": "ui_render_audit",
        "transport": transport,
        "ok": bool(entry.get("ok")),
        # Honest nulls: ui_render_audit emits no snapshot_captured, so audit-only
        # reports carry null stamps — never faked.
        "stamps": {"godot_version": report.get("godot_version"),
                   "window": report.get("window"), "renderer": report.get("renderer")},
        "session": {"trace_path": str(trace_path), "start_line": session["start_line"],
                    "end_line": session["end_line"], "boot_ts_msec": session["boot_ts_msec"]},
        "text_oracle_passed": oracle,
        "ui_render_audit_passed": passed,
        "eligible": eligible,
        "anomalies": anomalies,
        "capture_invalid_count": session.get("capture_invalid", 0),  # >0 flags a magenta-fallback run for review
        "states": states,
        "report_ref": {"path": ".godot-smoke/playtest-report.json",
                       "generated_at": (report.get("summary") or {}).get("generated_at")},
    }


def _windowed_red(run: dict) -> bool:
    """Evidence-of-a-red, distinct from mere missing evidence: a real window run
    (transport windowed/dap) whose scenario FAILED (ok=false). For ui_render_audit the
    scenario's sole required event is ui_render_audit_passed (godot_dap_smoketest.py
    requirements["all"]), which fires only when `_failures` is empty — so ok=false ⟺
    `_failures` non-empty ⟺ a graduated-state finding was routed to red OR a scene-tree
    failure fired. Quarantine-only runs stay GREEN with ok=true (an un-flipped state's
    findings never touch `_failures` — the exit-4 proof's plant 2 is exactly this), so
    ok=true is NEVER a red even when findings are present. Headless/skipped runs carry
    no pixel evidence and are never a red here."""
    return (str(run.get("transport", "")) in ELIGIBLE_TRANSPORTS
            and not run.get("eligible")
            and not run.get("ok"))


def state_streak(runs: list[dict], state: str) -> tuple[int, list[int], dict | None]:
    """Trailing eligible-clean streak. Missing-evidence ineligibles (headless/skipped,
    or ok=true runs lacking a pass event) NEITHER COUNT NOR BREAK (a headless CI run
    must not punish a streak); an eligible dirty entry resets; AND an ineligible run
    with EVIDENCE OF A RED (_windowed_red: a windowed/dap run with ok=false) BREAKS
    consecutiveness — a failed windowed audit is not a clean windowed run, so a strict
    reading of '5 consecutive clean windowed runs' (vision-fidelity.md § Per-state
    graduation rule) requires it to reset the streak rather than be silently skipped.
    A windowed red breaks EVERY state's streak (the run-level audit failed, so the run
    is not clean for any state). Returns (streak, run_ids, last_dirty {id, kinds,
    windowed_red}) — the reset reason `status` shows."""
    streak, ids, last_dirty = 0, [], None
    for run in runs:
        if not run.get("eligible"):
            if _windowed_red(run):
                streak, ids = 0, []
                kinds = sorted({kind for info in (run.get("states") or {}).values()
                                for kind in (info or {}).get("kinds", [])})
                last_dirty = {"id": run.get("id"), "kinds": kinds, "windowed_red": True}
            continue  # missing evidence (headless/skipped/ok=true): neither counts nor breaks
        info = (run.get("states") or {}).get(state) or {}
        if info.get("clean"):
            streak += 1
            ids.append(int(run.get("id", 0)))
        else:
            streak, ids = 0, []
            last_dirty = {"id": run.get("id"), "kinds": info.get("kinds", []),
                          "windowed_red": False}
    return streak, ids, last_dirty


# --------------------------------------------------------------------------- record

def cmd_record(args) -> int:
    root = repo_root()
    report_path = Path(args.report)
    report_path = report_path if report_path.is_absolute() else root / report_path
    ledger_path = Path(args.ledger)
    ledger_path = ledger_path if ledger_path.is_absolute() else root / ledger_path
    if not report_path.exists():
        print(f"refused: report {report_path} does not exist — run "
              "`python3 tools/run_playtests.py --scenario ui_render_audit` first", file=sys.stderr)
        return 1
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"refused: report {report_path} is unreadable: {exc}", file=sys.stderr)
        return 1
    entry = next((s for s in report.get("scenarios", [])
                  if isinstance(s, dict) and s.get("scenario") == "ui_render_audit"), None)
    if entry is None:
        print("refused: report does not describe a ui_render_audit run — re-run first", file=sys.stderr)
        return 1
    trace_path = Path(args.trace) if args.trace else default_trace_path(root)
    if not trace_path.exists():
        print(f"refused: trace log {trace_path} not found (pass --trace PATH; CI has no user:// log)", file=sys.stderr)
        return 1
    try:
        doc = load_ledger(ledger_path)
    except LedgerUnreadable as exc:
        print(f"refused: ledger {ledger_path} is unreadable ({exc}) — refusing to overwrite recorded "
              "evidence with a fresh ledger; repair or remove the file by hand, then re-run", file=sys.stderr)
        return 1
    runs = doc.setdefault("runs", [])
    # The report is single-slot (overwritten per run): refuse a report older than the
    # ledger's last entry so the report<->session join cannot pair mismatched runs.
    generated_at = str((report.get("summary") or {}).get("generated_at") or "")
    if runs:
        last_generated = str(((runs[-1].get("report_ref") or {}).get("generated_at")) or "")
        if generated_at and last_generated and generated_at < last_generated:
            print(f"refused: report generated_at {generated_at} predates the ledger's last "
                  f"entry ({last_generated}) — stale single-slot report, re-run first", file=sys.stderr)
            return 1
    sessions = split_sessions(trace_path)
    audit_sessions = [s for s in sessions if _is_audit_session(s)]
    if not audit_sessions:
        print(f"refused: no ui_render_audit session found in {trace_path} — re-run the scenario first", file=sys.stderr)
        return 1
    session = audit_sessions[-1]  # the LAST boot-delimited session containing audit events
    for run in runs:  # dedupe on the boot-delimited session identity: re-recording is a no-op
        session_ref = run.get("session") or {}
        if session_ref.get("start_line") == session["start_line"] and session_ref.get("boot_ts_msec") == session["boot_ts_msec"]:
            print(f"no-op: session (start_line={session['start_line']}, boot_ts_msec="
                  f"{session['boot_ts_msec']}) already recorded as run {run.get('id')}")
            return 0
    run = build_run_entry(report, entry, session, trace_path, doc)
    runs.append(run)
    save_ledger(ledger_path, doc)
    threshold = int(doc.get("threshold", THRESHOLD))
    parts = []
    for state in FLIP_ORDER:
        info = run["states"][state]
        if info["clean"]:
            streak = state_streak(runs, state)[0]
            parts.append(f"{state} CLEAN (streak {streak}/{threshold})")
        else:
            parts.append(f"{state} DIRTY kinds={info['kinds']}")
    head = (run["head_sha"] or "?")[:12]
    print(f"recorded run {run['id']} at head {head} ({run['transport']}, ok={run['ok']}): " + " | ".join(parts))
    if not run["eligible"]:
        if _windowed_red(run):
            print(f"WINDOWED RED (ok={run['ok']}) — breaks streaks for every state: a failed "
                  "windowed audit is not a clean windowed run")
        else:
            reason = "; ".join(run["anomalies"]) or "transport/pass-event gate (missing evidence)"
            print(f"not eligible ({reason}) — missing evidence; neither counts nor breaks streaks")
    if run["capture_invalid_count"]:
        print(f"note: {run['capture_invalid_count']} capture_invalid event(s) — magenta-fallback run; review before trusting")
    return 0


# --------------------------------------------------------------------------- status

def cmd_status(args) -> int:
    root = repo_root()
    ledger_path = Path(args.ledger)
    ledger_path = ledger_path if ledger_path.is_absolute() else root / ledger_path
    threshold = THRESHOLD
    runs: list[dict] = []
    flips: list[dict] = []
    if ledger_path.exists():
        try:
            doc = load_ledger(ledger_path)
            threshold = int(doc.get("threshold", THRESHOLD))
            runs, flips = doc.get("runs", []), doc.get("flips", [])
        except LedgerUnreadable as exc:
            print(f"ledger {ledger_path}: unreadable ({exc}) — re-run `graduation_ledger.py record` to "
                  "regenerate; streaks render empty until then")
    else:
        print(f"ledger {ledger_path}: not yet recorded — bank runs with "
              "`python3 tools/run_playtests.py --scenario ui_render_audit && "
              "python3 tools/graduation_ledger.py record`")
    head = git_head_sha(root)
    graduated = graduated_map(root)
    flips_by_state = {flip.get("state"): flip for flip in flips}
    runs_by_id = {int(run.get("id", 0)): run for run in runs}
    print(f"GRADUATED_STATES (scripts/app/ui_render_audit.gd): {json.dumps(graduated, sort_keys=True)}")
    print(f"flip order: battle_moves + battle_item (anchor) -> battle_action (lint) -> "
          f"battle_message (box); threshold {threshold} consecutive clean eligible runs; git HEAD {head}")
    for state in FLIP_ORDER:
        line = f"- {state}: "
        if state not in graduated:
            print(line + "no GRADUATED_STATES key — never graduates (menu/party/bag family; a future author must not add keys)")
            continue
        if graduated[state]:
            flip = flips_by_state.get(state)
            if flip:
                judgment = f"; judgment: {flip['judgment']}" if flip.get("judgment") else ""
                print(line + f"GRADUATED (flip at {flip.get('at_head', '?')}, mode={flip.get('mode')}, "
                             f"basis={flip.get('basis')}{judgment}, evidence runs {flip.get('evidence_run_ids')})")
            else:
                print(line + "GRADUATED in code but no flips[] ledger entry — record the flip evidence")
            continue
        streak, ids, last_dirty = state_streak(runs, state)
        blockers = [f"streak {streak}/{threshold}"]
        streak_shas = {(runs_by_id.get(run_id) or {}).get("head_sha") for run_id in ids}
        stale = bool(streak_shas) and streak_shas != {head}
        if streak < threshold:
            missing = threshold - streak
            blockers.append(f"next step: {missing} more clean windowed ui_render_audit run(s) at HEAD {head}, "
                            "recorded after each run")
        elif stale:
            blockers.append(f"STALE evidence: streak entries at {sorted(sha or 'null' for sha in streak_shas)} "
                            f"!= current HEAD {head} — the streak progress is banked, but the flip needs "
                            f"{threshold} fresh runs at {head}")
        for predecessor in PREDECESSORS.get(state, []):
            if not graduated.get(predecessor, False):
                blockers.append(f"missing predecessor flip: {predecessor}")
        if state == "battle_message" and not any(
                flip.get("state") == state and flip.get("judgment") for flip in flips):
            blockers.append("box mode: a documented judgment is REQUIRED in the flip entry (engine-owned "
                            "~1px pen offset, glyph match excluded by design, lint cleanliness accepted as "
                            "sufficient, deferral considered) — DEFERRED until recorded; progress is banked")
        flippable = streak >= threshold and not stale and not blockers[1:]
        verdict = "FLIPPABLE" if flippable else "NOT FLIPPABLE"
        extra = ""
        if last_dirty:
            tag = "windowed RED, " if last_dirty.get("windowed_red") else ""
            extra = f" (last dirty: run {last_dirty['id']}, {tag}kinds {last_dirty['kinds']})"
        print(line + f"{verdict} — " + "; ".join(blockers) + extra)
    return 0


# ----------------------------------------------------------------------- calibration

def _vision_doc(root: Path) -> dict | None:
    path = root / ".godot-smoke" / "vision-review.json"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) and doc.get("schema", "").startswith("vision-review/") else None


def _stage_to_display(region, window) -> list[int] | None:
    """Map an audit stage-px rect to display px at the entry's RECORDED window
    (canonical 1152x648 => k=4, display = (256,36)+stage*4). Audit-only runs carry
    window=null => unjoinable, counted, never faked."""
    if not (isinstance(window, list) and len(window) == 2 and isinstance(region, list) and len(region) >= 4):
        return None
    try:
        width, height = int(window[0]), int(window[1])
        k = min((width - 32) // 160, (height - 32) // 144)
    except (TypeError, ValueError, ZeroDivisionError):
        return None
    if k <= 0:
        return None
    x0, y0 = (width - 160 * k) // 2, (height - 144 * k) // 2
    x, y, w, h = (int(v) for v in region[:4])
    return [x0 + x * k, y0 + y * k, w * k, h * k]


def _vision_corroboration(vision_doc, window_runs, ve) -> tuple[int, int]:
    """Lane-4 quarantine-forever corroboration of window audit findings (bbox overlap
    at the recorded window + shot->state compatibility). Corroboration only — Lane 4
    NEVER confirms (only a graduated coded oracle confirms). Returns (joined, unjoined)."""
    if vision_doc is None:
        return 0, 0
    vision_findings = [f for shot in vision_doc.get("shots", [])
                       for f in shot.get("findings", []) if isinstance(f, dict)]
    joined = unjoined = 0
    for run in window_runs:
        window = (run.get("stamps") or {}).get("window")
        for state, info in (run.get("states") or {}).items():
            for finding in info.get("sample", []):
                mapped = _stage_to_display(finding.get("region"), window)
                if mapped is None:
                    unjoined += 1  # null-window runs join on state+kind only — documented weaker join
                    continue
                hit = any(SHOT_STATE_MAP.get(str(f.get("shot", ""))) == state
                          and _overlaps(ve, mapped, f.get("bbox"))
                          for f in vision_findings)
                joined += hit
                unjoined += not hit
    return joined, unjoined


def _confirmations(window: list[dict], flips: list[dict], ve) -> tuple[int, int, bool]:
    """Quarantine finding Q from run i is CONFIRMED-real iff a later recorded run
    j > i carries the state graduated (flips[] epoch < j) AND a finding in the SAME
    defect family with an OVERLAPPING stage-px region. Returns (confirmed, total, capped)."""
    epochs = {state: _graduated_epoch(flips, state) for state in STATES}
    confirmed = total = 0
    capped = False
    for run in window:
        run_id = int(run.get("id", 0))
        for state, info in (run.get("states") or {}).items():
            for finding in info.get("sample", []):
                total += 1
                kind = str(finding.get("kind", ""))
                region = finding.get("region")
                for later in window:
                    later_id = int(later.get("id", 0))
                    epoch = epochs.get(state)
                    if later_id <= run_id or epoch is None or later_id <= epoch:
                        continue
                    later_info = (later.get("states") or {}).get(state) or {}
                    if any(_family(kind) == _family(str(l.get("kind", ""))) and _overlaps(ve, region, l.get("region"))
                           for l in later_info.get("sample", [])):
                        confirmed += 1
                        break
            if info.get("findings", 0) > len(info.get("sample", [])):
                capped = True
                total += info["findings"] - len(info.get("sample", []))  # counted, unconfirmable past the cap
    return confirmed, total, capped


def _graduated_reds(window: list[dict], flips: list[dict]) -> int:
    """Findings in runs recorded after the state's flip — caught at first occurrence
    by the graduated gate (the same quarantine_finding trace, routed to _failures)."""
    epochs = {state: _graduated_epoch(flips, state) for state in STATES}
    reds = 0
    for run in window:
        run_id = int(run.get("id", 0))
        for state, info in (run.get("states") or {}).items():
            epoch = epochs.get(state)
            if epoch is not None and run_id > epoch:
                reds += info.get("findings", 0)
    return reds


def _compute_cycle(doc: dict, window: list[dict], cycle_no: int, root: Path) -> dict:
    flips = doc.get("flips", [])
    ve = _vision_explain()
    confirmed, quarantine_total, capped = _confirmations(window, flips, ve)
    graduated_reds = _graduated_reds(window, flips)
    real_defects = graduated_reds + confirmed  # honest ground-truth PROXY; seeded-proof plants add here when recorded
    window_end = max((int(run.get("id", 0)) for run in window), default=0)
    oracle_existed = any((_graduated_epoch(flips, state) or 10**18) < window_end for state in STATES)
    precision = (confirmed / quarantine_total) if (quarantine_total and oracle_existed) else None
    recall = (graduated_reds / real_defects) if real_defects else None
    notes = []
    if capped:
        notes.append("dirty-run samples capped at 8 — findings past the cap are counted, unconfirmable")
    joined, unjoined = _vision_corroboration(_vision_doc(root), window, ve)
    if joined or unjoined:
        notes.append(f"Lane-4 corroboration (quarantine-forever, NOT confirmations): {joined} joined, {unjoined} unjoined vision_review findings")
    if not oracle_existed:
        notes.append(f"no graduated oracle existed before the window closed — precision undefined; "
                     f"graduated states: {sorted(set(f.get('state', '') for f in flips)) or '[]'}")
    if cycle_no <= 1:
        notes.append(f"Cycle {cycle_no} baseline recorded {datetime.now(timezone.utc).date().isoformat()} "
                     f"at {git_head_sha(root)}. A two-cycle TREND requires the next legibility-garden cycle "
                     "(weekly, Mon 14:00 UTC); none is claimed from a single cycle.")
    else:
        notes.append(f"trend over {cycle_no} cycles — recorded, not interpreted (samples are tiny)")
    return {"cycle": cycle_no, "date": datetime.now(timezone.utc).date().isoformat(),
            "head_sha": git_head_sha(root),
            "window_run_ids": [int(window[0].get("id", 0)), int(window[-1].get("id", 0))] if window else None,
            "graduated_states": sorted(k for k, v in graduated_map(root).items() if v),
            "quarantine_total": quarantine_total, "confirmed": confirmed, "precision": precision,
            "graduated_reds": graduated_reds, "real_defects": real_defects, "recall": recall,
            "notes": "; ".join(notes)}


def cmd_calibration(args) -> int:
    root = repo_root()
    ledger_path = Path(args.ledger)
    ledger_path = ledger_path if ledger_path.is_absolute() else root / ledger_path
    try:
        doc = load_ledger(ledger_path)
    except LedgerUnreadable as exc:
        print(f"refused: ledger {ledger_path} is unreadable ({exc}) — re-run `graduation_ledger.py record` "
              "to regenerate; not computing a cycle over a corrupt binder", file=sys.stderr)
        return 1
    runs = doc.setdefault("runs", [])
    calibration = doc.setdefault("calibration", {"cadence": CADENCE, "cycles": []})
    calibration.setdefault("cadence", CADENCE)
    cycles = calibration.setdefault("cycles", [])
    last = max(cycles, key=lambda c: int(c.get("cycle", 0)), default=None)
    window = [r for r in runs if last is None
              or int(r.get("id", 0)) > int((last.get("window_run_ids") or [0, 0])[1])]
    if not runs:
        print("no recorded runs — record windowed ui_render_audit runs first "
              "(`graduation_ledger.py record`); nothing to calibrate")
        return 0
    if not window:
        print(f"no recorded runs since the last snapshot (cycle {last.get('cycle')}, window "
              f"{last.get('window_run_ids')}) — nothing new to calibrate")
        return 0
    cycle_no = args.cycle if args.cycle is not None else (int(last.get("cycle", 0)) + 1 if last else 1)
    if args.cycle is not None:
        # Replacing cycle N: the window restarts after cycle N-1's window (all runs
        # when N is the first cycle), so a recomputed cycle sees its full run range
        # and late-arriving confirmations land in the cycle that owns the finding.
        prior = max((c for c in cycles if int(c.get("cycle", 0)) < cycle_no),
                    key=lambda c: int(c.get("cycle", 0)), default=None)
        window = [r for r in runs if prior is None
                  or int(r.get("id", 0)) > int((prior.get("window_run_ids") or [0, 0])[1])]
        if not window:
            print(f"no recorded runs in the window for cycle {cycle_no} — nothing to calibrate")
            return 0
    snapshot = _compute_cycle(doc, window, cycle_no, root)
    # Preserve the hand-added seeded-proof narrative across a replace (Minor 4): `notes`
    # is a generated field, but cycle 1 carries an attested seeded-proof paragraph that
    # `calibration` cannot regenerate. The DURABLE authoritative copy is the top-level
    # `exit4_proof` (which no calibration run touches); this carry-over keeps the prose
    # too, so `calibration --cycle N` never silently deletes the exit-4 attestation.
    marker = "Seeded-proof plants"
    prior_cycle = next((c for c in cycles if int(c.get("cycle", 0)) == cycle_no), None)
    prior_notes = str((prior_cycle or {}).get("notes") or "")
    if prior_cycle and marker in prior_notes and marker not in snapshot.get("notes", ""):
        snapshot["notes"] = (snapshot.get("notes", "") + " "
                             + prior_notes[prior_notes.index(marker):]).strip()
        print(f"note: preserved the hand-added seeded-proof narrative across the cycle {cycle_no} "
              "replace (authoritative durable copy: top-level exit4_proof)")
    cycles[:] = sorted([c for c in cycles if int(c.get("cycle", 0)) != cycle_no] + [snapshot],
                       key=lambda c: int(c.get("cycle", 0)))
    save_ledger(ledger_path, doc)
    print(f"cycle {cycle_no}: window runs {snapshot['window_run_ids']}, quarantine precision "
          f"{quarantine_text(snapshot)}; graduated reds / recall {recall_text(snapshot)}")
    print(snapshot["notes"])
    return 0


def _render_rate(value, numerator: int, denominator: int, why: str) -> str:
    """Zero-denominator honesty: null renders literally, NEVER 0.0, NEVER 1.0,
    NEVER 'n/a' without counts."""
    if value is None:
        return f"undefined ({numerator} of {denominator} — {why})"
    return f"{value:.3f} ({numerator} of {denominator})"


def quarantine_text(snapshot: dict) -> str:
    return _render_rate(snapshot.get("precision"), snapshot.get("confirmed", 0),
                        snapshot.get("quarantine_total", 0),
                        "confirmed quarantine findings" if snapshot.get("quarantine_total")
                        else "no quarantine findings in the window")


def recall_text(snapshot: dict) -> str:
    return _render_rate(snapshot.get("recall"), snapshot.get("graduated_reds", 0),
                        snapshot.get("real_defects", 0),
                        "no real defects in the window; baseline cycle")


# ---------------------------------------------------------------------- report hook

def render_section(ledger_path) -> list[str]:
    """The "Graduation & calibration" section of generate_legibility_report.py —
    rendered from the TRACKED ledger (the garden workflow has no Godot and no user://
    log, so it only renders; record/calibration run locally). Missing ledger => a
    'not yet recorded' note, never an error. Calibration rows here are advisory text
    and never count as findings (the Legibility Debt regex matches only the report's
    first '- Total findings: N' line)."""
    lines = ["## Graduation & calibration", ""]
    path = Path(ledger_path)
    if not path.exists():
        lines.append("Graduation ledger: not yet recorded. Run `python3 tools/run_playtests.py "
                     "--scenario ui_render_audit` then `python3 tools/graduation_ledger.py record` "
                     "to bank stamped evidence — no ledger, no flips, never an error.")
        lines.append("")
        return lines
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        lines.append("Graduation ledger: unreadable — re-run `graduation_ledger.py record` to regenerate.")
        lines.append("")
        return lines
    threshold = int(doc.get("threshold", THRESHOLD))
    runs, flips = doc.get("runs", []), doc.get("flips", [])
    lines.append(f"Ledger `{path.name}` (schema {doc.get('schema', '?')}): {len(runs)} recorded run(s), "
                 f"threshold {threshold} consecutive clean eligible runs; streaks are computed from the "
                 "entries, never narrated. Missing-evidence ineligibles (headless/skipped, or ok=true runs "
                 "lacking a pass event) neither count nor break streaks; a windowed RED (ok=false) BREAKS "
                 "consecutiveness for every state (a failed windowed audit is not a clean windowed run).")
    lines.append("")
    graduated: dict = {}  # bind before the try so a raised graduated_map (e.g. a corrupt
    # ui_render_audit.gd) degrades to an empty live map and never leaves `graduated`
    # unbound for the streak loop below (the 'missing ledger => note, never an error' contract).
    try:
        graduated = graduated_map(repo_root())
        lines.append(f"GRADUATED_STATES (live): {json.dumps(graduated, sort_keys=True)}")
        lines.append("")
    except Exception:
        pass  # degrade: render streaks against an empty live map, never crash the report
    if flips:
        lines.append("Flips (recorded evidence):")
        for flip in flips:
            judgment = f" — judgment: {flip['judgment']}" if flip.get("judgment") else ""
            lines.append(f"- {flip.get('state')}: {flip.get('mode')} ({flip.get('basis')}) at "
                         f"{flip.get('at_head', '?')}, evidence runs {flip.get('evidence_run_ids')}{judgment}")
        lines.append("")
    proof = doc.get("exit4_proof")
    if isinstance(proof, dict) and proof.get("plants"):
        lines.append("Exit-criterion-4 seeded proof (temporary perturbations, all reverted byte-identical; "
                     "documented as PROOF, never counted as organic statistics — graduated_reds/confirmed/"
                     "precision/recall exclude these):")
        for plant in proof.get("plants", []):
            session = plant.get("session") or {}
            grad_label = "graduated" if plant.get("graduated_at_plant_time") else "un-flipped"
            lines.append(f"- plant {plant.get('plant')} ({plant.get('state')}, {grad_label}): "
                         f"{plant.get('quarantine_finding_count')} findings "
                         f"{json.dumps(plant.get('kinds'), sort_keys=True)} (trace session "
                         f"{session.get('start_line')}-{session.get('end_line')}) — {plant.get('result')}")
        if proof.get("post_flip_clean_run_id") is not None:
            lines.append(f"- post-flip clean run {proof.get('post_flip_clean_run_id')}: both pass events, "
                         "quarantined=0 (no flip-introduced false positives)")
        if proof.get("revert_proof"):
            lines.append(f"- revert proof: {proof['revert_proof']}")
        lines.append("")
    if runs:
        lines.append("Per-state trailing eligible-clean streak:")
        for state in FLIP_ORDER:
            streak, ids, last_dirty = state_streak(runs, state)
            mark = "GRADUATED" if graduated.get(state) else ("FLIPPABLE" if streak >= threshold else "in progress")
            if last_dirty:
                tag = "windowed RED, " if last_dirty.get("windowed_red") else ""
                extra = f"; last dirty run {last_dirty['id']} ({tag}kinds {', '.join(last_dirty['kinds'])})"
            else:
                extra = ""
            lines.append(f"- {state}: {streak}/{threshold} — {mark}{extra}")
    else:
        lines.append("No runs recorded yet — the ledger starts at the first stamped `record` "
                     "(historical sessions carry no head_sha; backfilling would assert, not record).")
    lines.append("")
    cycles = (doc.get("calibration") or {}).get("cycles", [])
    lines.append(f"Calibration (cadence: {(doc.get('calibration') or {}).get('cadence', CADENCE)}):")
    if not cycles:
        lines.append("- no cycle recorded yet — run `python3 tools/graduation_ledger.py calibration` "
                     "locally and commit the snapshot.")
    for snapshot in cycles:
        lines.append(f"- cycle {snapshot.get('cycle')} ({snapshot.get('date')}, head "
                     f"{(snapshot.get('head_sha') or '?')[:12]}, window {snapshot.get('window_run_ids')}): "
                     f"precision {quarantine_text(snapshot)}; graduated reds / recall {recall_text(snapshot)}")
        if snapshot.get("notes"):
            lines.append(f"  notes: {snapshot['notes']}")
    lines.append("")
    return lines


# ------------------------------------------------------------------------------ main

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ledger", default="docs/generated/graduation-ledger.json",
                        help="Ledger artifact (repo-relative or absolute).")
    record = sub.add_parser("record", parents=[common], help="Bank ONE ui_render_audit run as ledger evidence.")
    record.add_argument("--report", default=".godot-smoke/playtest-report.json")
    record.add_argument("--trace", help="agent_trace.jsonl path (default: resolved user:// path for this OS).")
    sub.add_parser("status", parents=[common], help="Streaks + flippable declarations (read-only).")
    calibration = sub.add_parser("calibration", parents=[common],
                                 help="Append/replace a precision/recall cycle snapshot (local-only).")
    calibration.add_argument("--cycle", type=int, help="Override the cycle number (default: last + 1).")
    args = parser.parse_args()
    if args.command == "record":
        return cmd_record(args)
    if args.command == "status":
        return cmd_status(args)
    return cmd_calibration(args)


if __name__ == "__main__":
    sys.exit(main())
