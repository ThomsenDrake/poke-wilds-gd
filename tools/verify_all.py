#!/usr/bin/env python3
"""One-command verification gate (Workstream L.1): full windowed local ritual,
honest headless CI path.

Orchestrates the existing tools via subprocess — it NEVER forks their logic,
mutates their behavior, or touches their exit-code contracts:

  S1-S4  static gates   check_repo_contracts / check_architecture /
                        check_quality_docs / check_change_contract
  S4.5   freshness      import_pokeapi.py --check (committed catalog JSON vs pinned-cache regeneration)
  S5-S6  determinism    determinism_verify.py pins + canary
  S6.5   double-run     TEN rng-consumers x2 headless, cmp --mode trace (240s per-group
                        outer + 10s cmp; [5,5] groups — infinite-world slice 1 RETIRED the
                        world_chain consumer with world chaining; the lane's full history
                        rides the DOUBLE_RUN ledger below)
  S7     headless suite run_playtests.py --include-smoke (PLAYTEST_FORCE_HEADLESS=1)
  S8-S9  windowed lanes run_playtests.py --scenario ui_render_audit / visual_sweep
                        + the FIVE satellite sweep families (shots 15-23 + 30-34 minus
                        retired — 17/33/35/36 are whitelisted numbering gaps)
  S10    legibility     generate_legibility_report.py (generate-only, NOT gated)

then runs post-refusals R1-R6 (head_sha==HEAD, stamp shape, windowed stamps vs
baseline capture_env + canonical window, windowed entries/transport, and
vision-review freshness via vision_review.review_is_fresh — the ONE piece of
reused logic, importlib-loaded, never forked; vision_metrics is never imported).

Exit codes (most severe class wins; the full contract — precedence, the
warn-degradation rules, the result-file schema — is docs/RELIABILITY.md § Local
gate):
  0 GREEN        every step passed, no exit-escalating refusal fired
  1 STEP_FAILURE trustworthy run that found real defects
  2 REFUSAL      evidence stale/mismatched — the run is NOT certified
  3 TOOL_ERROR   no valid result obtained (crash / timeout / binary missing)

Honesty invariants: a transport-skip (headless visual_sweep) is NEVER a
failure; a missing/stale report or stamp mismatch is a REFUSAL (never a silent
pass); a missing Godot binary is a TOOL_ERROR; --skip-windowed reports the
windowed lanes SKIP (never PASS) and degrades R6 to a recorded, printed WARN
that never escalates the exit code.

The full windowed gate is a LOCAL ritual. CI runs this same orchestrator with
--skip-windowed; renderer-stamped pixel and VLM lanes remain local.
Typical full-run wall time is ~1-2 minutes on this machine (~63s measured).
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _apply_cloud_env() -> None:
    # start.sh is a child of environment.json `start`; inherit DISPLAY here.
    spec = importlib.util.spec_from_file_location(
        "cloud_env", Path(__file__).resolve().with_name("cloud_env.py"))
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.load_cloud_env()


_apply_cloud_env()

EXIT_GREEN = 0
EXIT_STEP_FAILURE = 1
EXIT_REFUSAL = 2
EXIT_TOOL_ERROR = 3

CANONICAL_WINDOW = [1152, 648]
BATTLE_BASELINE = "docs/generated/visual-baselines/09_battle.png"
BATTLE_SIDECAR = ROOT / "docs/generated/visual-baselines/09_battle.png.sidecar.json"
SMOKE_DIR = ROOT / ".godot-smoke"
SHOTS_DIR = SMOKE_DIR / "shots"
VISION_REVIEW_JSON = SMOKE_DIR / "vision-review.json"
BASELINE_DIR = ROOT / "docs/generated/visual-baselines"
DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
STAMP_KEYS = ("head_sha", "godot_version", "window", "renderer")
OUTPUT_TAIL_LINES = 40
_UNSET = object()  # memoization sentinel (both cached values can legitimately be None/str)

# Double-run determinism lane (deep-dive suite expansion), inserted AFTER S6: the
# ten rng-consumer scenarios run twice headless, each run persisting its ordered
# trace JSONL, then determinism_verify.py's cmp --mode trace canonical-compares the
# two trace sets (timing-stripped, key-sorted, order-sensitive); a mismatch reds
# with the divergent event + both canonical payloads as the named cause (miss-002).
# Every consumer must self-pin its seed (seed_for_smoke BEFORE new_game + rebuild —
# a boot world rides the wall-clock root_seed and would red the cmp); night_cycle
# rides that pattern to cover the unlit-night ghost draws no other consumer reaches
# (new games start at 10:00; the soaks never hit NIGHT_START 20:30). The per-group
# outer budgets are explicit headroom (count x the 45s cap + 15s cold start),
# index-aligned with the [5,5] groups. The full history — consumer additions, the
# retired world_chain, the 2026-08-01 30->45s budget re-stamp (a deadline-truncated
# run raced a completed one: a budget race, NOT a logic divergence) — is
# docs/RELIABILITY.md § Local gate S6b, the canonical narrative.
DOUBLE_RUN_SCENARIOS = ["playtest_journey", "playtest_soak", "overworld_mons",
                        "encounter_config", "landmark_flow", "shiny_odds", "fishing_flow",
                        "breed_flow", "legendary_spawn", "night_cycle"]
DOUBLE_RUN_GROUPS = [DOUBLE_RUN_SCENARIOS[:5], DOUBLE_RUN_SCENARIOS[5:]]
DOUBLE_RUN_PER_SCENARIO_TIMEOUT_S = 45.0
DOUBLE_RUN_RUN_OUTER_TIMEOUT_S = [240.0, 240.0]  # per GROUP, index-aligned with DOUBLE_RUN_GROUPS — never one run of all
DOUBLE_RUN_CMP_OUTER_TIMEOUT_S = 10.0

def _load_tool(module_name: str, path: Path):
    """The single importlib loader for sibling tools: tools are read, never
    forked (main entries are __main__-guarded)."""
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {module_name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_run_playtests_constant(name: str):
    """Single-source a constant from run_playtests.py (R3): the RED-tier sidecar
    seed-equality + anchor gates live there, so its SATELLITE_SWEEP_SCENARIOS is the
    truth this orchestrator's S9 windowed loop mirrors. run_playtests is read, never
    forked (its top-level only loads the sibling smoke harness; the main entry is
    __main__-guarded)."""
    return getattr(_load_tool("run_playtests", ROOT / "tools" / "run_playtests.py"), name)


# S9 windowed satellite sweep families, windowed-diffed one-command alongside the
# main visual_sweep. SINGLE-SOURCED from run_playtests.py (R3) so the orchestrator's
# loop and the runner's gates cover the identical family set by construction; the
# per-family shot ranges/retirement history live on the constant there.
SATELLITE_SWEEP_SCENARIOS = list(_load_run_playtests_constant("SATELLITE_SWEEP_SCENARIOS"))

# The error-as-directive envelope builders (agent-integration.md § Error-as-directive)
# are single-sourced in the sibling smoke harness and reused here for the R1-R6
# refusal rows — the same importlib load pattern as vision_review, never forked.
_smoketest = _load_tool("godot_dap_smoketest", ROOT / "tools" / "godot_dap_smoketest.py")
_error_envelope = _smoketest.error_envelope


# Per-code refusal-envelope builders: ONE scannable home per stable code, so a
# new/refined refusal edits a function here instead of hand-writing another
# inline {code, retryable, hint} literal. The R1-R6 prose contracts stay in
# docs/RELIABILITY.md § Local gate; the per-scenario gate codes live at the two
# harnesses' flip sites.
def _stale_head_sha_error() -> dict:
    return _error_envelope(
        "stale_head_sha", True,
        "Re-run the gate on a clean HEAD: python3 tools/verify_all.py "
        "(every report is re-stamped at the current HEAD each run).")


def _report_invalid_error(partial: bool, rel: Path) -> dict:
    if partial:
        return _error_envelope(
            "report_invalid", True,
            f"Re-run the gate: python3 tools/verify_all.py — an interrupted "
            f"run leaves a partial report; a fresh run re-stamps {rel}.")
    return _error_envelope(
        "report_invalid", True,
        f"Delete the malformed report and re-run the gate: "
        f"python3 tools/verify_all.py (it regenerates {rel} fresh).")


def _stamp_mismatch_error() -> dict:
    return _error_envelope(
        "stamp_mismatch", False,
        "Regenerate the baselines under this Godot "
        "binary/renderer/window: python3 tools/run_playtests.py "
        "--scenario visual_sweep_update, review and commit the "
        "result, then re-run python3 tools/verify_all.py.")


def _adapter_mismatch_error() -> dict:
    return _error_envelope(
        "adapter_mismatch", False,
        "PNG/region pixel compare is not certified on this GPU adapter; "
        "Mac baselines stay local pixel authority. Keep the windowed "
        "transport and Lane-4 VLM review; do not regenerate Mac baselines "
        "from this machine.")


def _windowed_lane_error(scenario: str) -> dict:
    return _error_envelope(
        "windowed_lane_missing", True,
        f"Run the pixel lane windowed (clear PLAYTEST_FORCE_HEADLESS from "
        f"the env): python3 tools/run_playtests.py --scenario {scenario}, "
        f"then re-run verify_all; or pass --skip-windowed to acknowledge "
        f"the lane is skipped.")


def _vision_stale_error(full: bool = True) -> dict:
    hint = ("Re-run the windowed sweep to regenerate a fresh review: "
            "python3 tools/run_playtests.py --scenario visual_sweep")
    if full:
        hint += " (the review manifest must match the shots on disk)"
    return _error_envelope("vision_review_stale", True, hint + ".")

# "warn" maps to GREEN on purpose: a warn-tier refusal (R6 vision-review
# freshness under --skip-windowed) is recorded + printed but NEVER escalates
# the exit code — the windowed lane was deliberately not run, so its evidence
# cannot certify or block. Only refusal/tool_error levels affect the verdict.
_SEVERITY = {"pass": 0, "skip": 0, "warn": EXIT_GREEN, "fail": EXIT_STEP_FAILURE,
             "refusal": EXIT_REFUSAL, "tool_error": EXIT_TOOL_ERROR}


def _git_head() -> str | None:
    try:
        proc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(ROOT),
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = proc.stdout.strip()
    return sha if proc.returncode == 0 and sha else None


def _load_visual_diff():
    """Sanctioned importlib load of visual_diff (adapter-mismatch helper)."""
    return _load_tool("visual_diff", ROOT / "tools" / "visual_diff.py")


def _load_vision_review():
    """Sanctioned importlib load of the stdlib-only sibling vision_review;
    reaches review_is_fresh without any static import and without ever
    touching vision_metrics."""
    return _load_tool("vision_review", ROOT / "tools" / "vision_review.py")


def _read_json(path: Path):
    """(doc, error) — error is None on success."""
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except OSError as exc:
        return None, f"unreadable ({exc})"
    except ValueError as exc:
        return None, f"corrupt JSON ({exc})"


def _tail(text: str) -> str:
    lines = (text or "").splitlines()
    return "\n".join(lines[-OUTPUT_TAIL_LINES:])


def _counts(steps: list[dict], refusals: list[dict]) -> dict:
    """One counting pass shared by the result JSON and the printed summary line
    so the two surfaces can never disagree (finding: the printed TOOL_ERROR used
    to be steps-only — refusal-level tool_errors merge into tool_errors here)."""
    counts = {"passed": 0, "failed": 0, "skipped": 0, "refusals": 0,
              "warnings": 0, "tool_errors": 0}
    status_key = {"pass": "passed", "fail": "failed", "skip": "skipped",
                  "tool_error": "tool_errors"}
    for entry in steps:
        key = status_key.get(entry["status"])
        if key:
            counts[key] += 1
    level_key = {"refusal": "refusals", "warn": "warnings", "tool_error": "tool_errors"}
    for refusal in refusals:
        if not refusal["ok"] and refusal["level"] in level_key:
            counts[level_key[refusal["level"]]] += 1
    return counts


def _invoke(argv: list[str], env: dict, timeout: float) -> dict:
    """One subprocess attempt: {returncode, output, error, timed_out}."""
    try:
        proc = subprocess.run(argv, cwd=str(ROOT), env=env, capture_output=True,
                              text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"returncode": None, "output": "", "error": "timeout", "timed_out": True}
    except OSError as exc:
        return {"returncode": None, "output": "", "error": f"failed to launch: {exc}",
                "timed_out": False}
    output = proc.stdout or ""
    if proc.stderr and proc.stderr.strip():
        output += ("\n[stderr]\n" + proc.stderr) if output else proc.stderr
    return {"returncode": proc.returncode, "output": output, "error": None,
            "timed_out": False}


class Runner:
    def __init__(self, args):
        self.args = args
        self.quiet = args.quiet
        self.steps: list[dict] = []
        self.refusals: list[dict] = []
        self.binary_missing = False
        self.fail_fast_stop = False
        # Each is computed once per run and reused by both the refusals and the
        # stamps block (finding #3): the Godot binary never changes mid-run, and
        # both vision-review reads happen after the sweep regenerated the file.
        self._binary_triple_cache = _UNSET
        self._vision_fresh_cache = _UNSET
        self._vision_coverage_cache = _UNSET

    # ------------------------------------------------------------------ steps
    def echo(self, text: str) -> None:
        if not self.quiet and text and text.strip():
            for line in text.splitlines():
                print(f"    {line}")

    def note_failure_output(self, entry: dict) -> None:
        if self.quiet and entry["status"] in ("fail", "tool_error") and entry.get("output_tail"):
            print(f"    --- captured output tail ---")
            for line in entry["output_tail"].splitlines():
                print(f"    {line}")

    def record_skip(self, name: str, kind: str, reason: str, argv=None) -> dict:
        entry = {"name": name, "kind": kind, "argv": argv or [], "status": "skip",
                 "skip_reason": reason, "duration_s": 0.0}
        self.steps.append(entry)
        print(f"[SKIP]  {name:<40} ({reason})")
        return entry

    def _run_windowed_playtest(self, scenario: str, report: Path, bin_: str,
                               env_override: dict | None = None) -> dict | None:
        """S8/S9 shared lane: SKIP honestly (skip_windowed / missing binary —
        never a silent pass) or run one scenario windowed and return its entry
        for the caller to certify."""
        args = self.args
        if args.skip_windowed:
            self.record_skip(f"run_playtests:windowed:{scenario}", "windowed",
                             "windowed lane skipped (--skip-windowed)")
            return None
        if self.binary_missing:
            self.record_skip(f"run_playtests:windowed:{scenario}", "windowed",
                             "godot binary missing (run_playtests exit 2)")
            return None
        return self.run_tool(
            f"run_playtests:windowed:{scenario}", "windowed",
            [sys.executable, "tools/run_playtests.py", "--scenario", scenario,
             "--report", str(report.relative_to(ROOT)),
             "--timeout", str(args.windowed_timeout), "--godot-bin", bin_,
             "--host", args.dap_host, "--port", str(args.dap_port)],
            pop_force_headless=True, env_override=env_override,
            outer_timeout=args.windowed_timeout + 120, retry_once=True,
            exit_map={0: "pass", 1: "fail", 2: "tool_error"},
            extra={"report": str(report.relative_to(ROOT))})

    def run_tool(self, name: str, kind: str, argv: list[str], *,
                 env_override: dict | None = None, pop_force_headless: bool = False,
                 outer_timeout: float = 300.0, retry_once: bool = False,
                 exit_map: dict | None = None, extra: dict | None = None,
                 count_issues: bool = False) -> dict:
        """Run one orchestrated tool. exit_map: {exit_code: status}; unmapped
        non-zero exits become tool_error. Returns the step entry."""
        env = os.environ.copy()
        if pop_force_headless:
            env.pop("PLAYTEST_FORCE_HEADLESS", None)
        if env_override:
            env.update(env_override)
        entry = {"name": name, "kind": kind, "argv": argv, "status": "pending",
                 "duration_s": 0.0}
        if env_override:
            entry["env"] = dict(env_override)
        if extra:
            entry.update(extra)
        start = time.monotonic()
        result = _invoke(argv, env, outer_timeout)
        if result["timed_out"] and retry_once:
            print(f"[retry] {name}: windowed run timed out after {outer_timeout:.0f}s "
                  f"(possible fully-occluded-window stall); retrying once")
            result = _invoke(argv, env, outer_timeout)
        entry["duration_s"] = round(time.monotonic() - start, 2)
        entry["output_tail"] = _tail(result["output"])
        if result["error"] == "timeout":
            entry["exit_code"] = None
            entry["status"] = "tool_error"
            entry["error"] = (f"exceeded outer hang-backstop timeout "
                              f"({outer_timeout:.0f}s){' after one retry' if retry_once else ''}")
        elif result["error"]:
            entry["exit_code"] = None
            entry["status"] = "tool_error"
            entry["error"] = result["error"]
        else:
            code = result["returncode"]
            entry["exit_code"] = code
            mapping = exit_map or {0: "pass", 1: "fail"}
            entry["status"] = mapping.get(code, "tool_error")
            if entry["status"] == "tool_error" and "error" not in entry:
                entry["error"] = f"unexpected exit code {code}"
            # Known honesty nuance (finding #2): a crashed orchestrated tool exits
            # 1 — indistinguishable from "defects found" on the code alone (the tools
            # own their 0/1(/2) contracts, untouched by design), so a crash reports
            # fail, never a silent pass. Timeouts/launch failures ARE tool_error.
        if count_issues and entry["status"] == "fail":
            # Count issues from the FULL captured output, not the ~40-line
            # output_tail, so a gate emitting more findings than the tail holds
            # reports the true total in the FAIL detail (exit status is decided
            # elsewhere; this is only the printed/recorded issue count).
            entry["issues"] = sum(1 for line in result["output"].splitlines()
                                  if line.startswith("- "))
        self.steps.append(entry)
        self._print_step_line(entry)
        self.echo(result["output"])
        self.note_failure_output(entry)
        if self.args.fail_fast and entry["status"] in ("fail", "tool_error"):
            self.fail_fast_stop = True
        return entry

    def _print_step_line(self, entry: dict) -> None:
        label = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP",
                 "tool_error": "TOOL_ERROR"}[entry["status"]]
        detail = ""
        if entry["status"] == "fail":
            issues = entry.get("issues")
            if issues is not None:
                detail = f"  {issues} issue(s)"
        elif entry["status"] == "tool_error":
            detail = f"  {entry.get('error', 'tool error')}"
        elif entry["status"] == "skip":
            print(f"[SKIP]  {entry['name']:<40} ({entry.get('skip_reason', 'skipped')})")
            return
        print(f"[{label}]  {entry['name']:<40} ({entry['duration_s']:.2f}s){detail}")
        if entry["status"] == "tool_error":
            print(f"verify_all: {entry['name']}: {entry.get('error', 'tool error')}",
                  file=sys.stderr)

    # -------------------------------------------------------------- refusals
    def refuse(self, check: str, ok: bool, detail: str, level: str = "refusal",
               error: dict | None = None) -> None:
        """Record one refusal row. `error` is the error-as-directive envelope
        ({code, retryable, hint} from _error_envelope) for a NOT-ok row whose
        failure maps to a stable code; the dict always carries the three keys
        (None for passes and envelope-less tool_errors). `detail` and the
        exit-code semantics are unchanged."""
        refusal = {"check": check, "ok": ok, "detail": detail, "level": level,
                   "code": None, "retryable": None, "hint": None}
        if error:
            refusal["code"] = error.get("code")
            refusal["retryable"] = error.get("retryable")
            refusal["hint"] = error.get("hint")
        self.refusals.append(refusal)
        if not ok:
            if level == "refusal":
                print(f"[REFUSE] {detail}")
                print(f"verify_all: {detail}", file=sys.stderr)
            elif level == "tool_error":
                print(f"[TOOL_ERROR] {detail}")
                print(f"verify_all: {detail}", file=sys.stderr)
            else:
                print(f"[WARN] {detail}")

    # ------------------------------------------------------------- pipeline
    def run(self) -> int:
        args = self.args
        t0 = time.monotonic()
        head = _git_head()
        if head is None:
            self.refuse("git_head", False,
                        "cannot determine git HEAD — verify_all must run inside the repo",
                        level="tool_error")
        headless_report = SMOKE_DIR / "playtest-report.json"
        audit_report = SMOKE_DIR / "verify-ui_render_audit.json"
        sweep_report = SMOKE_DIR / "verify-visual_sweep.json"
        bin_ = args.godot_bin
        static_map = {0: "pass", 1: "fail"}
        det_map = {0: "pass", 1: "fail", 2: "tool_error"}
        play_map = {0: "pass", 1: "fail", 2: "tool_error"}

        def py(rel: str) -> list[str]:
            return [sys.executable, f"tools/{rel}"]

        # --- S1-S4 + S4.5: static gates (fast; failures surface at the top) ---
        for name, tool, extra_argv in (
            ("check_repo_contracts", "check_repo_contracts.py", []),
            ("check_architecture", "check_architecture.py", []),
            ("check_quality_docs", "check_quality_docs.py", []),
            ("check_change_contract", "check_change_contract.py",
             ["--base", args.base] if args.base else []),
            ("import_pokeapi:check", "import_pokeapi.py", ["--check"]),
        ):
            self.run_tool(name, "static", py(tool) + extra_argv,
                          outer_timeout=300.0, exit_map=static_map, count_issues=True)
            if self.fail_fast_stop:
                break

        # --- S5-S6: determinism pins + canary ---
        if not self.fail_fast_stop:
            for name, argv in (
                ("determinism:pins", py("determinism_verify.py") + ["pins"]),
                ("determinism:canary", py("determinism_verify.py") +
                 ["canary", "--shot", BATTLE_BASELINE]),
            ):
                entry = self.run_tool(name, "determinism", argv,
                                      outer_timeout=120.0, exit_map=det_map)
                try:
                    entry["json"] = json.loads(entry.get("output_tail", "").strip().splitlines()[-1])
                except (ValueError, IndexError):
                    pass
                if self.fail_fast_stop:
                    break

        # --- S6.5: double-run determinism lane (eight rng-consumers x2, <=90s) ---
        if not self.fail_fast_stop:
            self._run_double_determinism_lane(bin_)

        # --- S7: headless full suite (transport-honest) ---
        certified: list[Path] = []  # reports whose producing step actually ran
        if not self.fail_fast_stop:
            entry = self.run_tool(
                "run_playtests:headless", "playtest",
                py("run_playtests.py") + ["--include-smoke", "--fresh-save", "--report",
                                          str(headless_report.relative_to(ROOT)),
                                          "--timeout", str(args.timeout),
                                          "--godot-bin", bin_],
                env_override={"PLAYTEST_FORCE_HEADLESS": "1"},
                outer_timeout=args.timeout * 20 + 120, exit_map=play_map,
                extra={"report": str(headless_report.relative_to(ROOT))})
            if entry["status"] in ("pass", "fail"):
                certified.append(headless_report)
            if entry["exit_code"] == 2:
                self.binary_missing = True
                entry["error"] = f"Godot binary missing: {bin_} (run_playtests exit 2)"
            if not self.fail_fast_stop:
                # --- S8: windowed ui_render_audit ---
                entry = self._run_windowed_playtest("ui_render_audit", audit_report, bin_)
                if entry is not None and entry["status"] in ("pass", "fail"):
                    certified.append(audit_report)
                # --- S9: windowed visual_sweep + the satellite sweep families
                # (single-sourced above; RUN LAST: freshest shots/review). The
                # main sweep keeps sweep_report (post-refusals R4 + stamps key
                # off it); each satellite gets its own report. Threaded per-shot
                # review (Track D): 4 shot workers; the merged manifest is
                # byte-identical to a sequential pass (proven 2026-08-07). ---
                if not self.fail_fast_stop:
                    sweep_lanes = [("visual_sweep", sweep_report)] + [
                        (name, SMOKE_DIR / f"verify-{name}.json")
                        for name in SATELLITE_SWEEP_SCENARIOS]
                    for scenario, report in sweep_lanes:
                        if self.fail_fast_stop:
                            break
                        entry = self._run_windowed_playtest(
                            scenario, report, bin_,
                            env_override={"VISION_REVIEW_WORKERS": "4"})
                        if entry is not None and entry["status"] in ("pass", "fail"):
                            certified.append(report)
                            if scenario == "visual_sweep":
                                self._vision_review_fresh()  # R6 memo: sample freshness the MOMENT the main sweep regenerated the review — later satellite captures land in .godot-smoke/shots and must not pollute the main-only manifest scope

                # --- S8.5: optional Command Code play agent (Track C.2) ---
                # Default OFF locally (--with-play-agent opts in); windowed-only,
                # so it SKIP-with-reason under --skip-windowed / a missing binary
                # and the headless force env is cleared so it can self-skip honestly.
                if not self.fail_fast_stop and getattr(args, "with_play_agent", False):
                    if args.skip_windowed:
                        self.record_skip("commandcode_play_agent", "windowed",
                                         "windowed lane skipped (--skip-windowed)")
                    elif self.binary_missing:
                        self.record_skip("commandcode_play_agent", "windowed",
                                         "godot binary missing (run_playtests exit 2)")
                    else:
                        self.run_tool(
                            "commandcode_play_agent", "windowed",
                            py("commandcode_play_agent.py") + [
                                "--project", str(ROOT),
                                "--godot-bin", bin_,
                                "--timeout", "180",
                                "--no-cmd",  # deterministic windowed-scenario drive; cmd pre-pass opt-in later
                            ],
                            pop_force_headless=True,
                            outer_timeout=300.0, retry_once=False,
                            exit_map={0: "pass", 1: "fail", 2: "tool_error"})

        # --- S10: legibility report (generate-only, findings already gated) ---
        if not self.fail_fast_stop:
            entry = self.run_tool(
                "generate_legibility_report", "legibility",
                py("generate_legibility_report.py") + ["--output",
                                                       str((SMOKE_DIR / "legibility-report.md")
                                                           .relative_to(ROOT))],
                outer_timeout=300.0, exit_map={0: "pass"})
            match = re.search(r"- Total findings: (\d+)", entry.get("output_tail", ""))
            entry["output"] = str((SMOKE_DIR / "legibility-report.md").relative_to(ROOT))
            if match:
                entry["total_findings"] = int(match.group(1))

        # --- Post-refusals R1-R6 (certify the artifacts the steps produced) ---
        self._post_refusals(head, certified, headless_report, audit_report,
                            sweep_report, bin_)

        duration = round(time.monotonic() - t0, 1)
        exit_code = self._verdict()
        stamps = self._collect_stamps(head, headless_report, audit_report, sweep_report, bin_)
        self._write_result(head, args, exit_code, duration, stamps)
        self._print_summary(exit_code, duration, stamps)
        return exit_code

    def _run_double_determinism_lane(self, bin_: str) -> None:
        """S6.5 double-run determinism lane (after the S5-S6 pins/canary).

        Runs the ten rng-consumer scenarios twice headless, each run persisting
        its ordered trace JSONL (--trace-dir), then canonical-compares the two
        trace sets with determinism_verify.py's cmp --mode trace. Budgets live on
        the DOUBLE_RUN constants (ledger: RELIABILITY.md § Local gate S6b). A trace
        mismatch reds with the divergent event + both canonical payloads as the
        named cause (miss-002); a missing binary skips honestly rather than faking
        a pass.
        """
        if self.binary_missing or not Path(bin_).exists():
            for label in ("run-A", "run-B", "cmp"):
                self.record_skip(f"determinism:double-run:{label}", "determinism",
                                 "godot binary missing (double-run lane needs headless runs)")
            return

        def py(rel: str) -> list[str]:
            return [sys.executable, f"tools/{rel}"]

        run_a = SMOKE_DIR / "determinism-run-a"
        run_b = SMOKE_DIR / "determinism-run-b"
        for directory in (run_a, run_b):  # drop stale traces so a short run can't pass on leftovers
            if directory.is_dir():
                for stale in directory.glob("*.jsonl"):
                    try:
                        stale.unlink()
                    except OSError:
                        pass

        # Two groups (not one run of all) so each run's worst case fits its
        # per-group outer budget; traces accumulate per dir and the single cmp
        # below compares the full ten-scenario set.
        for group_index, group in enumerate(DOUBLE_RUN_GROUPS, start=1):
            scenario_argv = [flag for name in group for flag in ("--scenario", name)]
            for label, trace_dir, report in (
                    (f"run-A{group_index}", run_a, SMOKE_DIR / "determinism-run-a-report.json"),
                    (f"run-B{group_index}", run_b, SMOKE_DIR / "determinism-run-b-report.json")):
                self.run_tool(
                    f"determinism:double-run:{label}", "determinism",
                    py("run_playtests.py") + scenario_argv +
                    ["--fresh-save",
                     "--trace-dir", str(trace_dir.relative_to(ROOT)),
                     "--report", str(report.relative_to(ROOT)),
                     "--timeout", str(DOUBLE_RUN_PER_SCENARIO_TIMEOUT_S),
                     "--godot-bin", bin_],
                    env_override={"PLAYTEST_FORCE_HEADLESS": "1"},
                    outer_timeout=DOUBLE_RUN_RUN_OUTER_TIMEOUT_S[group_index - 1],
                    exit_map={0: "pass", 1: "fail", 2: "tool_error"},
                    extra={"scenarios": list(group)})
                if self.fail_fast_stop:
                    return

        entry = self.run_tool(
            "determinism:double-run:cmp", "determinism",
            py("determinism_verify.py") +
            ["cmp", "--mode", "trace",
             "--a", str(run_a.relative_to(ROOT)),
             "--b", str(run_b.relative_to(ROOT))],
            outer_timeout=DOUBLE_RUN_CMP_OUTER_TIMEOUT_S,
            exit_map={0: "pass", 1: "fail", 2: "tool_error"})
        try:
            parsed = json.loads(entry.get("output_tail", "").strip().splitlines()[-1])
        except (ValueError, IndexError):
            parsed = None
        if isinstance(parsed, dict):
            entry["json"] = parsed
            if parsed.get("mismatches"):
                # Named cause (miss-002): the divergent event + both canonical forms.
                entry["mismatches"] = parsed["mismatches"]

    def _post_refusals(self, head, certified, headless_report, audit_report,
                       sweep_report, bin_) -> None:
        args = self.args
        docs = {}
        for path in certified:
            doc, err = _read_json(path)
            rel = path.relative_to(ROOT)
            # R2 — shape / stamp-key presence (missing/corrupt file: no verdict).
            if err is not None:
                self.refuse("report_shape", False,
                            f"{rel} is {err} — no verdict can be certified",
                            level="tool_error")
                continue
            if not isinstance(doc, dict):
                self.refuse("report_shape", False,
                            f"{rel} is not a JSON object — not a valid stamped report",
                            error=_report_invalid_error(False, rel))
                continue
            missing = [k for k in STAMP_KEYS if k not in doc]
            if missing:
                self.refuse("report_shape", False,
                            f"{rel} missing stamp key(s): {', '.join(missing)} — "
                            f"not a valid stamped report",
                            error=_report_invalid_error(True, rel))
                continue
            docs[path] = doc
            self.refuse("report_shape", True, f"{rel} carries all stamp keys")
            # R1 — head_sha freshness vs the single HEAD sampled at start.
            if head is None:
                continue
            if doc.get("head_sha") != head:
                self.refuse("report_head_sha", False,
                            f"{rel} head_sha {doc.get('head_sha')} != git HEAD {head} — "
                            f"report is stale; re-run verify_all on a clean HEAD",
                            error=_stale_head_sha_error())
            else:
                self.refuse("report_head_sha", True,
                            f"{rel} head_sha == HEAD {head[:10]}")

        sweep = docs.get(sweep_report)
        audit = docs.get(audit_report)

        # R3 — windowed stamps vs baseline capture_env + canonical window
        # (only when the windowed sweep actually ran and produced its report).
        if sweep is not None:
            sidecar, serr = _read_json(BATTLE_SIDECAR)
            if serr is not None or not isinstance(sidecar, dict):
                self.refuse("windowed_stamps_vs_environment", False,
                            f"baseline sidecar {BATTLE_SIDECAR.name} is "
                            f"{serr or 'not a dict'} — cannot certify windowed stamps",
                            level="tool_error")
            else:
                capture_env = sidecar.get("capture_env", {})
                base_window = sidecar.get("window")
                base_godot = capture_env.get("godot_version")
                base_renderer = capture_env.get("renderer")
                problems = []
                if sweep.get("window") != CANONICAL_WINDOW or (
                        base_window is not None and sweep.get("window") != base_window):
                    problems.append(f"sweep window {sweep.get('window')} != canonical "
                                    f"{CANONICAL_WINDOW} (baseline {base_window}) — captures "
                                    f"not at the pinned integer-scale window")
                triple = self._binary_triple(bin_)
                godot = sweep.get("godot_version")
                if not godot or godot != base_godot or (triple and not godot.startswith(triple)):
                    problems.append(f"sweep godot_version {godot} != baseline capture_env "
                                    f"{base_godot} (binary triple {triple}) — baselines were "
                                    f"captured under a different binary; regenerate baselines "
                                    f"before diffing")
                if not sweep.get("renderer") or sweep.get("renderer") != base_renderer:
                    problems.append(f"sweep renderer {sweep.get('renderer')} != baseline "
                                    f"capture_env renderer {base_renderer} — baselines captured "
                                    f"under a different renderer/driver; regenerate")
                if problems:
                    for problem in problems:
                        self.refuse("windowed_stamps_vs_environment", False, problem,
                                    error=_stamp_mismatch_error())
                else:
                    self.refuse("windowed_stamps_vs_environment", True,
                                "godot_version/renderer/window match baseline capture_env + "
                                "canonical window")
                adapter = _load_visual_diff().paired_adapter_mismatch(
                    SHOTS_DIR, BATTLE_SIDECAR.parent)
                if adapter:
                    self.refuse(
                        "windowed_adapter_authority", False,
                        f"fresh adapter {adapter['fresh']} != baseline "
                        f"{adapter['baseline']} ({adapter['shot']}) — PNG/region "
                        f"compare is not pixel authority on this machine; Lane-4 "
                        f"VLM review remains the Cloud visual check",
                        level="warn", error=_adapter_mismatch_error())
                else:
                    self.refuse("windowed_adapter_authority", True,
                                "fresh capture_env.adapter_name matches the "
                                "baseline sidecar (pixel compare is authority)")

            # R4 — visual_sweep entry present with windowed transport (guards
            # against PLAYTEST_FORCE_HEADLESS leaking into the windowed env).
            sweep_entry = next((item for item in sweep.get("scenarios", [])
                                if isinstance(item, dict)
                                and item.get("scenario") == "visual_sweep"), None)
            if sweep_entry is None or sweep_entry.get("transport") != "windowed":
                self.refuse("windowed_entries", False,
                            f"windowed visual_sweep entry missing or transport-skipped "
                            f"(transport={None if sweep_entry is None else sweep_entry.get('transport')})"
                            f" — the pixel lane did not actually run",
                            error=_windowed_lane_error("visual_sweep"))
            else:
                self.refuse("windowed_entries", True,
                            f"verify-visual_sweep.json carries a visual_sweep entry "
                            f"(transport=windowed)")

        # R4/R5 — ui_render_audit entry present + transport gate (a headless
        # fallback means the graduated red-tier pixel half never ran).
        # Certification bar: the audit lane is certified on TRANSPORT alone — R3's
        # stamp check covers only `sweep` because run_playtests stamps null
        # window/renderer/godot for the DAP audit run, and verify_all does not
        # fabricate. Closing that would mean stamping the DAP audit run, which
        # changes an orchestrated tool's behavior (out of scope by design).
        if audit is not None:
            audit_entry = next((item for item in audit.get("scenarios", [])
                                if isinstance(item, dict)
                                and item.get("scenario") == "ui_render_audit"), None)
            if audit_entry is None:
                self.refuse("windowed_entries", False,
                            "windowed ui_render_audit entry missing in "
                            "verify-ui_render_audit.json — the pixel lane did not "
                            "actually run",
                            error=_windowed_lane_error("ui_render_audit"))
            else:
                self.refuse("windowed_entries", True,
                            f"verify-ui_render_audit.json carries a ui_render_audit entry "
                            f"(transport={audit_entry.get('transport')})")
                transport = audit_entry.get("transport")
                if transport not in ("dap", "windowed"):
                    self.refuse("ui_render_audit_transport", False,
                                f"ui_render_audit ran headless (transport={transport}) — its "
                                f"graduated red-tier pixel half was not exercised; start the "
                                f"Godot editor with DAP on {args.dap_host}:{args.dap_port}, or pass "
                                f"--skip-windowed to acknowledge the lane is skipped",
                                error=_smoketest.dap_unreachable_error(
                                    args.dap_host, args.dap_port,
                                    "pass --skip-windowed to acknowledge the lane is skipped."))
                else:
                    self.refuse("ui_render_audit_transport", True,
                                f"ui_render_audit transport={transport}")

        # R6 — vision-review freshness (the sweep just regenerated the file).
        # Refusal only when the sweep ran; under --skip-windowed (or when the
        # windowed lane never produced evidence) it degrades to a WARN.
        fresh = self._vision_review_fresh()
        if sweep is not None:
            if fresh is True:
                self.refuse("vision_review_fresh", True,
                            "review_is_fresh true over .godot-smoke/shots vs "
                            "docs/generated/visual-baselines")
            else:
                self.refuse("vision_review_fresh", False,
                            "vision-review.json is stale vs current shots (review_is_fresh "
                            f"{'false' if fresh is False else fresh}) — manifest sha "
                            f"mismatch; the next sweep regenerates it",
                            error=_vision_stale_error(full=True))
        else:
            reason = ("windowed lanes skipped (--skip-windowed)" if args.skip_windowed
                      else "windowed visual_sweep produced no report")
            self.refuse("vision_review_fresh", fresh is True,
                        f"vision-review freshness not certified: {reason}; "
                        f"review_is_fresh={'true' if fresh is True else 'false/unavailable'}",
                        level="warn",
                        error=None if fresh is True else _vision_stale_error(full=False))

        # R7 — rubric-coverage honesty (advisory, NEVER red): over a FRESH
        # vision-review.json, shot-groups whose rubric questions have no fresh
        # reviewer pass surface as a WARN (warn maps to GREEN, so coverage gaps
        # never break the gate; "unanswered" is counted, never faked). Silent when
        # uncertifiable — R6 already records that, so there is no second warn.
        coverage_gaps = self._vision_coverage_gaps()
        if coverage_gaps:
            self.refuse("rubric_coverage", False,
                        f"rubric-coverage gaps (advisory, never red): {len(coverage_gaps)} "
                        f"shot-group(s) have rubric questions with no fresh reviewer pass — "
                        + "; ".join(coverage_gaps),
                        level="warn")
        elif coverage_gaps is not None:
            self.refuse("rubric_coverage", True,
                        "every rubric shot-group has a fresh reviewer pass (no coverage gaps)")

    def _vision_review_fresh(self):
        """True/False, or an error string when the evidence cannot be read.
        Memoized: re-reads vision-review.json + re-execs vision_review.py once."""
        if self._vision_fresh_cache is _UNSET:
            doc, err = _read_json(VISION_REVIEW_JSON)
            if err is not None:
                self._vision_fresh_cache = err
            else:
                try:
                    module = _load_vision_review()
                    self._vision_fresh_cache = bool(
                        module.review_is_fresh(doc, SHOTS_DIR, BASELINE_DIR))
                except Exception as exc:  # load failure: uncertifiable, never a silent pass
                    self._vision_fresh_cache = f"review_is_fresh raised {exc}"
        return self._vision_fresh_cache

    def _vision_coverage_gaps(self):
        """Rubric-coverage gap summaries from a FRESH vision-review.json: None
        (uncertifiable), [] (fresh, no gaps), or [..] (fresh, with gaps). Memoized;
        reuses the memoized R6 freshness check so the module/doc are not re-read.
        Coverage gaps are ADVISORY (never red) — they ride the WARN surface."""
        if self._vision_coverage_cache is _UNSET:
            gaps = None
            if self._vision_review_fresh() is True:
                doc, err = _read_json(VISION_REVIEW_JSON)
                if err is None and isinstance(doc, dict):
                    coverage = doc.get("rubric_coverage")
                    if isinstance(coverage, dict):
                        gaps = [f"[{g.get('group', '?')}] {g.get('reason', '')}"
                                for g in (coverage.get("gaps") or []) if isinstance(g, dict)]
            self._vision_coverage_cache = gaps
        return self._vision_coverage_cache

    def _binary_triple(self, bin_: str) -> str | None:
        """Leading X.Y.Z from `Godot --version`. Memoized: launches the binary once."""
        if self._binary_triple_cache is _UNSET:
            try:
                proc = subprocess.run([bin_, "--version"], cwd=str(ROOT),
                                      capture_output=True, text=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                proc = None
            if proc is None:
                self._binary_triple_cache = None
            else:
                match = re.search(r"\d+\.\d+\.\d+", proc.stdout or "")
                self._binary_triple_cache = (match.group(0)
                                             if proc.returncode == 0 and match else None)
        return self._binary_triple_cache

    def _collect_stamps(self, head, headless_report, audit_report, sweep_report, bin_):
        report_heads = {}
        for path in (headless_report, audit_report, sweep_report):
            if path.exists():
                doc, err = _read_json(path)
                report_heads[path.name] = (doc or {}).get("head_sha") if isinstance(doc, dict) else None
        sweep_doc, _ = _read_json(sweep_report)
        sweep_doc = sweep_doc if isinstance(sweep_doc, dict) else {}
        sidecar, _ = _read_json(BATTLE_SIDECAR)
        sidecar = sidecar if isinstance(sidecar, dict) else {}
        capture_env = sidecar.get("capture_env", {})
        window_match = (sweep_doc.get("window") == CANONICAL_WINDOW == sidecar.get("window")
                        if sweep_doc.get("window") is not None else None)
        godot_match = (sweep_doc.get("godot_version") == capture_env.get("godot_version")
                       if sweep_doc.get("godot_version") is not None else None)
        renderer_match = (sweep_doc.get("renderer") == capture_env.get("renderer")
                          if sweep_doc.get("renderer") is not None else None)
        adapter = _load_visual_diff().paired_adapter_mismatch(
            SHOTS_DIR, BATTLE_SIDECAR.parent) if SHOTS_DIR.is_dir() else None
        return {
            "git_head": head,
            "report_head_sha": report_heads,
            "godot_version": {"report": sweep_doc.get("godot_version"),
                              "baseline_capture_env": capture_env.get("godot_version"),
                              "binary_version_triple": self._binary_triple(bin_),
                              "match": godot_match},
            "window": {"report": sweep_doc.get("window"), "canonical": CANONICAL_WINDOW,
                       "baseline": sidecar.get("window"), "match": window_match},
            "renderer": {"report": sweep_doc.get("renderer"),
                         "baseline_capture_env": capture_env.get("renderer"),
                         "match": renderer_match},
            "adapter": {"fresh": None if adapter is None else adapter.get("fresh"),
                        "baseline": None if adapter is None else adapter.get("baseline"),
                        "match": adapter is None},
            "vision_review_fresh": self._vision_review_fresh(),
            "rubric_coverage_gaps": self._vision_coverage_gaps(),
        }

    def _verdict(self) -> int:
        code = EXIT_GREEN
        for entry in self.steps:
            code = max(code, _SEVERITY.get(entry["status"], 0))
        for refusal in self.refusals:
            if not refusal["ok"]:
                code = max(code, _SEVERITY.get(refusal["level"], EXIT_REFUSAL))
        return code

    def _write_result(self, head, args, exit_code, duration, stamps) -> None:
        counts = _counts(self.steps, self.refusals)
        result = {
            "schema": "verify-all/1",
            "head_sha": head,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "cwd": str(ROOT),
            "skip_windowed": args.skip_windowed,
            "godot_bin": args.godot_bin,
            "duration_s": duration,
            "exit_code": exit_code,
            "steps": self.steps,
            "stamps": stamps,
            "refusals": self.refusals,
            "summary": counts,
        }
        json_path = Path(args.json)
        if not json_path.is_absolute():
            json_path = ROOT / json_path
        try:
            json_path.parent.mkdir(parents=True, exist_ok=True)
            json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
            print(f"result:  {json_path}")
        except OSError as exc:
            print(f"verify_all: could not write result file {json_path}: {exc}",
                  file=sys.stderr)
        # Trend history (Track D): machine-local JSONL + HTML re-render; advisory
        # only — a failure here warns on stderr, NEVER reds the gate.
        try:
            trend = _load_tool("trend_report", ROOT / "tools" / "trend_report.py")
            total = trend.append_history(trend.slim_record(result))
            trend.render()
            print(f"trend:   {trend.HTML_PATH.relative_to(ROOT)} ({total} runs)")
        except Exception as exc:
            print(f"verify_all: trend history append/render failed (non-gating): {exc}",
                  file=sys.stderr)

    def _print_summary(self, exit_code, duration, stamps) -> None:
        # Single-sourced with the JSON summary via _counts (finding: the printed
        # TOOL_ERROR used to be steps-only; the merge now lives in ONE function).
        counts = _counts(self.steps, self.refusals)
        print()
        print("==== verify_all summary ====")
        print(f"PASS: {counts['passed']}  FAIL: {counts['failed']}  SKIP: {counts['skipped']}  "
              f"REFUSE: {counts['refusals']}  WARN: {counts['warnings']}  "
              f"TOOL_ERROR: {counts['tool_errors']}  (wall time {duration:.1f}s)")
        print("stamps:")
        print(f"  git_head:        {stamps['git_head']}")
        for name, sha in stamps["report_head_sha"].items():
            print(f"  {name + ':':<22}{sha}")
        print(f"  godot_version:   report={stamps['godot_version']['report']} "
              f"baseline={stamps['godot_version']['baseline_capture_env']} "
              f"triple={stamps['godot_version']['binary_version_triple']} "
              f"match={stamps['godot_version']['match']}")
        print(f"  window:          report={stamps['window']['report']} "
              f"canonical={stamps['window']['canonical']} "
              f"baseline={stamps['window']['baseline']} match={stamps['window']['match']}")
        print(f"  renderer:        report={stamps['renderer']['report']} "
              f"baseline={stamps['renderer']['baseline_capture_env']} "
              f"match={stamps['renderer']['match']}")
        print(f"  adapter:         fresh={stamps['adapter']['fresh']} "
              f"baseline={stamps['adapter']['baseline']} "
              f"match={stamps['adapter']['match']}")
        print(f"  vision_review:   fresh={stamps['vision_review_fresh']}")
        meaning = {
            EXIT_GREEN: "GREEN — every step passed, no refusal fired",
            EXIT_STEP_FAILURE: "STEP_FAILURE — trustworthy run that found real defects",
            EXIT_REFUSAL: "REFUSAL — evidence stale/mismatched; run NOT certified",
            EXIT_TOOL_ERROR: "TOOL_ERROR — no valid result obtained",
        }[exit_code]
        print(f"exit code: {exit_code} ({meaning})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--skip-windowed", action="store_true",
                        help="display-less environments: report the windowed pixel lanes "
                             "as SKIP (never PASS) and suppress the windowed refusals")
    parser.add_argument("--with-play-agent", action="store_true",
                        help="opt-in S8.5 Command Code play agent (windowed-subprocess "
                             "drive, no DAP; default off locally; skipped under --skip-windowed)")
    parser.add_argument("--timeout", type=float, default=120,
                        help="per-scenario wall-clock budget (s) for the headless suite "
                             "(default 120)")
    parser.add_argument("--windowed-timeout", type=float, default=600,
                        help="per-scenario budget (s) for the windowed lanes (default 600, "
                             "matching the documented 600000 ms windowed bound)")
    parser.add_argument("--dap-host", default="127.0.0.1",
                        help="DAP host for editor-driven windowed lanes (default 127.0.0.1)")
    parser.add_argument("--dap-port", type=int, default=6006,
                        help="DAP port for editor-driven windowed lanes (default 6006)")
    parser.add_argument("--json", default=str((SMOKE_DIR / "verify_all.json").relative_to(ROOT)),
                        help="machine-readable result path (default "
                             ".godot-smoke/verify_all.json, gitignored)")
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN),
                        help="Godot binary passed through to run_playtests")
    parser.add_argument("--base", default=None,
                        help="optional --base REF passthrough to check_change_contract.py")
    parser.add_argument("--fail-fast", action="store_true",
                        help="stop at the first nonzero step (default is run-all)")
    parser.add_argument("--quiet", action="store_true",
                        help="suppress echoing each tool's stdout (status lines + failure "
                             "tails still print)")
    args = parser.parse_args()
    return Runner(args).run()


if __name__ == "__main__":
    sys.exit(main())
