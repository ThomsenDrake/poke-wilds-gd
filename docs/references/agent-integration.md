Status: current
Last verified: 2026-08-14
Review cadence days: 14
Source paths: tools/setup_worktree.py, tools/godot_dap_smoketest.py, tools/run_playtests.py, tools/verify_all.py, tools/cloud_env.py, tools/vlm_reviewer.py, scripts/core/trace_logger.gd, scripts/runtime/game_runtime.gd, scripts/runtime/smoke_scenario_runner.gd, scripts/runtime/performance_monitors.gd, scripts/app/ui_tree_dump_scenario.gd, docs/registry/agent-surface.toml, docs/references/trace-events.md, docs/references/godot-dap.md, docs/references/accessibility.md, docs/references/snapshot-sidecar.md, addons/agent_trace/agent_trace_plugin.gd, addons/agent_trace/agent_trace_debugger.gd, addons/agent_trace/README.md, docs/generated/visual-baselines, docs/generated/golden-saves/v4_golden.json

# Agent Integration

How ANY coding agent — CLI agent, IDE agent, or MCP server — drives this repo.
The house rule is **protocols, not vendors**: the repo owns its agent-facing
surface (ports, CLIs, JSONL traces, golden baselines) and documents it; it never
vendors an agent-vendor server and never commits an agent-client config. The
canonical machine-readable source for every endpoint, path, and command named
here is the manifest: [docs/registry/agent-surface.toml](../registry/agent-surface.toml)
(mechanically gated by `tools/check_repo_contracts.py` — a referenced path that
goes missing reds the static gate).

## The five integration channels

| Channel | What it is | Supported natively here |
| --- | --- | --- |
| Files | Read/edit the tree, run CLIs, parse committed artifacts | **Yes — the primary channel.** [AGENTS.md](../../AGENTS.md) is the table of contents; `tools/*.py` are stdlib-only and runnable as-is. |
| LSP | Language Server Protocol for GDScript (diagnostics, symbols, completion) | **Yes, via the running editor.** The Godot editor's GDScript language server listens on `127.0.0.1:6005`, TCP-only, and only while the editor has this project open. An agent host that needs stdio must run a per-developer stdio↔TCP bridge (never vendored). |
| DAP | Debug Adapter Protocol: launch the game, collect exceptions, drive scenarios | **Yes.** `127.0.0.1:6006` with [tools/godot_dap_smoketest.py](../../tools/godot_dap_smoketest.py) as the repo's reference client (launch contract and scenario mechanism: [godot-dap.md](godot-dap.md)). The transport is **launch/trace-only** — the windowed-subprocess transport is the sole pixel/VLM authority ([godot-dap.md](godot-dap.md) § Transport authority). |
| Editor bridge | An in-editor plugin surface (debugger tabs, docks) | **Yes, opt-in.** [addons/agent_trace](../../addons/agent_trace/README.md) is an editor plugin (ships **disabled by default** — Project Settings > Plugins) that renders the live trace stream in-editor: a per-session debugger tab plus a bottom-panel activity log. The game side is an additive `EngineDebugger.send_message("agent_trace:event", [line])` hook in `scripts/core/trace_logger.gd` (a strict no-op when no debugger is attached, so headless/scenario runs are byte-identical); the editor side declares the `agent_trace` capture. It visualizes the repo's own JSONL contract — no vendor coupling — and no plugin is required to drive the repo (the DAP/LSP endpoints remain sufficient). |
| Runtime bridge | File-in/file-out control of a running game | **Yes.** The harness writes `.godot-smoke/scenario.json`, which `scripts/runtime/smoke_scenario_runner.gd` consumes at boot; the game answers on the JSONL trace stream (`user://logs/agent_trace.jsonl`, also mirrored on stdout) and the playtest report. No socket required on the headless transport. |

## Attaching an agent or MCP server

Attach at the protocol level only:

1. The local Cursor/Codex creation hook runs `python3 tools/setup_worktree.py
   --quick`. Before the first runtime test, run the full manifest `[preflight]`
   command `python3 tools/setup_worktree.py`; optionally seed missing independent
   caches with `--seed-from /absolute/path/to/a/warm/worktree`.
2. Read the manifest for the endpoints and commands (DAP `6006`, LSP `6005`,
   the scenario CLI, the trace path, the preflight gate).
3. Drive the scenario CLI ([tools/run_playtests.py](../../tools/run_playtests.py))
   or the DAP smoke runner directly — both are plain stdlib Python.
4. An MCP server that wraps these protocols is a **per-developer** install: the
   repo vendors no server and commits no client configuration. Client config
   files (`.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`,
   `.claude/settings.local.json`) are gitignored.

Per-developer example (illustrative placeholder — lives in YOUR editor's MCP
client config, NEVER in this repo; the referenced server is not vendored here):

```json
{
  "mcpServers": {
    "godot-poke-wilds": {
      "command": "your-per-developer-godot-mcp-server",
      "args": ["--dap-endpoint", "127.0.0.1:6006", "--lsp-endpoint", "127.0.0.1:6005"]
    }
  }
}
```

## Text over pixels (the legibility rule)

Agents answer "what is the game doing?" from **structured text**, in this order:

1. The trace stream — one JSON object per line, `{event, ts_msec, source,
   payload}`; per-event meanings in [trace-events.md](trace-events.md).
2. The playtest report (`.godot-smoke/playtest-report.json`) — per-scenario
   `events_seen`, `missing_all`/`missing_any`, `exceptions`, `failed_events`.
3. Capture sidecars (`docs/generated/visual-baselines/*.png.sidecar.json`) —
   machine-readable geometry/labels per golden shot.
4. The UI-tree dumps (`.godot-smoke/ui_tree/<screen>.json`, produced by the
   `ui_tree_dump` scenario; manifest `[ui_tree]`) — per-screen JSON of every
   visible Control (path, type, text, rect, disabled) plus the AccessKit
   annotations the GBC widget
   library sets (`a11y_name`/`a11y_description`/`a11y_live`, emitted only when
   non-default — e.g. the selection cursor's `"Row N of M"` description) plus
   the cursor/selection. The annotation contract (what is set where, and the
   rule for new widgets) lives in
   [accessibility.md](accessibility.md). The `legibility_soak` scenario
   continuously gates the three-way agreement between these dumps, the
   `game/*` Performance monitors (manifest `[monitors]`), and the trace
   stream's screen-transition lifecycle events, emitting
   `legibility_soak_passed` / `legibility_soak_failed{failures}`.
5. The Lane-4 vision review (`.godot-smoke/vision-review.json`, written by
   `tools/vlm_reviewer.py` through the runner's mandatory review post-step;
   manifest `[vision_review]`) — a vision model's rubric answers over the
   windowed sweep shots, merged onto the scenario entry as
   `vision_review_quarantine` findings. Advisory only: quarantine-FOREVER,
   never promoted to red (see Recipes below).

Screenshots are golden-baseline **verification artifacts**, not a primary
perception channel: capture paths go in transcripts, never binary image data in
context. A windowed lane that cannot run reports SKIP, never PASS — a skipped
lane certifies nothing, and no agent should treat it as a pass.

## Recipes

Short vendor-neutral loops over the artifacts above. Each names the manifest
section that is its machine-readable source instead of restating paths.

- **Read a screen without pixels** (manifest `[ui_tree]`). Run `python3
  tools/run_playtests.py --scenario ui_tree_dump` (headless-runnable,
  self-pinned), then read `.godot-smoke/ui_tree/<screen>.json` — one file per
  agent-facing screen (`title`, `menu`, `party`, `bag`, `battle`), each
  `{screen, cursor, node_count, nodes}` with per-node path/type/text/rect and
  the non-default a11y annotations. Node contract:
  [accessibility.md](accessibility.md).
- **Probe live state** (manifest `[monitors]`). In any running build —
  including release — `Performance.get_custom_monitor` answers
  `game/current_screen`, `game/party_size`, and `game/world_seed`; the JSONL
  trace is the file artifact, these are the in-process surface.
- **Explain a capture** (manifest `[visual_baselines]`). Join four artifacts
  by name and cursor: the PNG path ↔ its `<shot>.png.sidecar.json` sibling ↔
  the `snapshot_captured` record at 1-based line `trace_cursor + 1` of the
  JSONL trace ↔ the `visual_sweep` entry of the playtest report
  (`region_failures`, `region_quarantine`, `vision_review_written`). Full
  protocol: [snapshot-sidecar.md](snapshot-sidecar.md) § Correlation protocol.
- **Read the quarantine tiers** (manifest `[vision_review]`). Red-tier
  findings flip `ok` and gate. Quarantine-tier findings ride the scenario
  entry — `region_quarantine`, `contrast_findings` / `cvd_findings`,
  `anchor_drift_quarantine`, `vision_review_quarantine` — reported, never
  gating. A `QUARANTINED_SCENARIOS` entry still runs every pass, but its red
  counts under `summary.quarantined_flakes`, not failure. Lane 4 is
  quarantine-FOREVER: `vision-review.json` is advisory model output and must
  never be promoted to red; under `VLM_REQUIRED=1` a missing, stale, or
  incomplete review fails closed (`vision_review_failed` /
  `vision_review_stale` / `vision_review_incomplete`).
- **Treat SKIP as nothing certified.** A windowed-only scenario under
  `PLAYTEST_FORCE_HEADLESS=1` — or the gate's `--skip-windowed` — reports
  SKIP-with-reason (`transport: "skipped-headless"`,
  `vision_review_written: null`) and exits 0: transport honesty, not a pass.
  Only a `transport: "windowed"` entry certifies the pixel lanes.
- **Drive the game like a player — optional** (manifest `[play_agent]`). Any
  scripted play agent can drive the windowed transport through the same
  scenario seams; `tools/commandcode_play_agent.py` is the repo's optional
  reference driver (windowed-only), never part of the contract.

## Error-as-directive

Every agent-facing failure this repo emits — tool exit, scenario failure, gate
refusal — is a **directive, not a dead end**. The convention is emitted as
plain JSON (no vendor channel) by the playtest suite and the local gate:

- a **stable `code`** — machine-matchable, never reworded casually;
- a **`retryable` flag** — whether re-running as-is can succeed;
- an **imperative `hint`** — the exact next action, with the command or path.

Concrete example (the DAP-unreachable failure, structured):

```json
{
  "ok": false,
  "error": {
    "code": "dap_endpoint_unreachable",
    "retryable": true,
    "hint": "Start the Godot editor with this project open (DAP listens on 127.0.0.1:6006), then re-run; or force the headless transport with PLAYTEST_FORCE_HEADLESS=1."
  }
}
```

The builder (`error_envelope`) and the failure-class deriver
(`scenario_failure_error`) are single-sourced in
[tools/godot_dap_smoketest.py](../../tools/godot_dap_smoketest.py) and reused by
both harnesses and the gate. Where the envelopes live:

- **Per-scenario results** — every red entry in
  `.godot-smoke/playtest-report.json` (and each `.godot-smoke/result-<scenario>.json`
  from the DAP smoke runner) carries `"error": {code, retryable, hint}` (`null`
  when green). Transport-derived reds are classified by `scenario_failure_error`:
  `dap_endpoint_unreachable` (the editor endpoint is not listening; retryable),
  `exceptions_captured` (a script error/timeout line is the named cause;
  retryable), `scenario_failed` (a `<scenario>_failed` trace carries the
  reasons; not retryable), `missing_required_events` (required trace events
  absent; retryable — event timing is a known flake class). Every ok-flipping
  post-step gate instead sets its own envelope at the flip site (never the
  deriver): `region_gate_failed` (RED-tier region diffs not retryable, tool
  crash/errors retryable — both transports), `sidecar_seed_mismatch` (not
  retryable), `contrast_failed` (graduated findings not retryable, tool
  crash/errors retryable), `anchor_refused` (baseline-regeneration refusal not
  retryable, gate load crash retryable), `anchor_drift_failed` (graduated
  drift; not retryable), `soak_tripwire` (corrupt pin / warning-count
  regression not retryable, pin-write IO failure retryable), and the Lane-4
  review codes `vision_review_failed` / `vision_review_stale` (retryable) /
  `vision_review_incomplete` (not retryable). A deterministic pixel/seed/pin
  red is NEVER labeled retryable — a plain re-run cannot pass, so the hint
  names the exact gate artifact/command instead.
- **`verify_all` refusals** — every row in the result's `refusals` array carries
  `code` / `retryable` / `hint` beside `check` / `ok` / `detail` / `level`
  (`null` for passing rows and envelope-less tool errors; the `detail` text and
  exit-code semantics are unchanged). Stable codes: `stale_head_sha` (R1),
  `report_invalid` (R2),   `stamp_mismatch` (R3), `adapter_mismatch` (R3 adapter-authority warn when
  `capture_env.adapter_name` differs — PNG/region compare is not certified;
  never a silent pass and never an exit-escalating refusal),
  `windowed_lane_missing` (R4),
  `dap_endpoint_unreachable` (R5), `vision_review_stale` (R6, including its
  warn-tier degradation under `--skip-windowed`).

Existing exemplars of the convention: `verify_all`'s R5 refusal ("start the
Godot editor with DAP on 127.0.0.1:6006, or pass `--skip-windowed`…"), the
symmetric `<scenario>_failed` trace events whose payloads carry the `failures`
array (a red always names its cause), and the playtest runner's per-scenario
`missing_all`/`missing_any`/`exceptions` fields. New agent-facing failures
SHOULD carry the structured `{code, retryable, hint}` triple; prose-only
messages MUST stay imperative.

## Preflight

Before pushing, run the local gate: `python3 tools/verify_all.py
--skip-windowed` on a display-less machine, the full `python3
tools/verify_all.py` otherwise. On Cursor Cloud, `environment.json` `start`
runs `.cursor/start.sh` as a child — it writes `~/.pokewilds-cloud.env` (no
secrets) and hooks bashrc/profile; `tools/cloud_env.py` then fills unset
`DISPLAY` / lavapipe / Dummy keys so a later `python3 tools/verify_all.py`
does not need a manual `source`. Semantics, exit codes, and refusals:
[docs/RELIABILITY.md](../RELIABILITY.md) § Local gate. Serialize gate runs —
exactly one harness writer against a project at a time (the scenario request
file and the appended trace log are shared state). If another checkout's Godot
editor owns DAP 6006, launch this checkout's editor on a different port and pass
that endpoint with `verify_all --dap-port <port>`; never validate through a
foreign editor merely because its socket is open.
