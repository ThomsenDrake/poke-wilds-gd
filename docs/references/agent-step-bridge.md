Status: current
Last verified: 2026-09-10
Review cadence days: 14
Source paths: tools/test_agent_step_contract.py, tools/play_agent_loop.py, tools/play_agent_findings.py, scripts/runtime/agent_step_reader.gd, scripts/app/play_agent_loop_scenario.gd, scripts/app/play_agent_loop_drive.gd, scripts/app/play_agent_loop_file.gd, docs/registry/agent-surface.toml

# Agent Step Bridge

Mid-session file contract for the optional `play_agent_loop` windowed scenario. Python publishes one command; the engine consumes it, applies real input-phase events, and publishes one observation. No sockets. No DAP input. `play_agent` / `play_agent_passed` are unchanged.

## Runtime paths

All under `.godot-smoke/` (gitignored). Engine paths use the `res://.godot-smoke/` prefix.

- `scenario.json` — boot request: `{"scenario":"play_agent_loop"}`
- `agent_command.json` — Python writes via temp file + atomic rename. Engine consumes, then deletes.
- `agent_observation.json` — engine writes via temp file + atomic rename after each applied command.
- `play_agent_loop.json` — Python session report at exit.
- `ui_tree/loop.json` — latest UI-tree snapshot from an `observe` or any applied command.

## Command object

- `id` (string, unique per turn)
- `action` one of: `boot_new_game`, `press`, `hold`, `observe`, `file_feedback`, `quit`
- `payload` object
  - `press` / `hold`: `{"input":"<bridge input name>"}` — allowed inputs: `move_up`, `move_down`, `move_left`, `move_right`, `action_a`, `action_b`, `menu`. `menu` maps to the InputMap action `start` (Enter); the other names are InputMap actions as-is.
  - `file_feedback`: `{"message":"<1-1000 chars starting with [agent-play]>", "live": false}`
  - others: empty object

A `file_feedback` message that is empty, longer than 1000 Unicode code points, or missing the `[agent-play]` prefix is invalid. Unknown `action` values are invalid.

## Observation object

- `command_id` — echoes the applied command
- `screen` — `PerformanceMonitors.screen_label_for` string
- `monitors` — `game/current_screen`, `game/party_size`, `game/world_seed`
- `tile` — `[x, y]` or `null`
- `trace_tail` — last 40 JSONL records
- `ui_tree` — `UiTreeDumpWriter.snapshot_screen` dictionary
- `exceptions` — strings
- `stuck` — true after 8 applied movement commands with the same screen+tile
- `feedback` — `null` or `{status, reason, issue_number}`

## Novelty signature

Canonical string: `screen|tile|exception_class|last_failed_event|ui_tree_structure_hash`

- `tile` is `x,y` or empty
- `ui_tree_structure_hash` hashes paths+types+text, not pixels
- Duplicate when the signature matches this session, `prior_findings`, or an open GitHub issue that already carries `[agent-play]` plus the same screen and exception class
- Lane-4 / VLM quarantine findings alone never justify a live file

## Session report

`{ok, skipped, reason, turns, anomalies, filed, skipped_duplicate, issue_number, errors:[{code,retryable,hint}]}`

Headless / `PLAYTEST_FORCE_HEADLESS=1` writes `{ok: true, skipped: true, reason}` and exits 0. A skipped lane certifies nothing.

## Flags

- `PLAY_AGENT_LIVE_FILE=1` — allow a real relay POST. Absent or `0` forces `live: false` and mock transport.
- `PLAY_AGENT_PLANNER_CMD` — optional CLI; stdin is one observation JSON, stdout is one command JSON. Default explorer is deterministic: `boot_new_game`, a bounded walk, `menu`, `observe`, `quit`.
- `PLAY_AGENT_FEEDBACK_ENDPOINT` — HTTPS endpoint embedded via the editor stamp for live runs. Not committed.

## Trace events

New only: `play_agent_loop_started`, `play_agent_step_applied`, `play_agent_anomaly_observed`, `play_agent_file_skipped`, `play_agent_loop_passed`, `play_agent_loop_failed`. Existing `feedback_*` events fire unchanged when F runs.

Turn budget 40 commands. Wall clock 180s. One file attempt per novel finding per session.
