Status: current
Last verified: 2026-09-11
Review cadence days: 14
Source paths: tools/test_agent_step_contract.py, tools/play_agent_loop.py, tools/play_agent_findings.py, scripts/runtime/agent_step_reader.gd, scripts/app/play_agent_loop_scenario.gd, scripts/app/play_agent_loop_drive.gd, scripts/app/play_agent_loop_file.gd, scripts/app/play_agent_loop_file_checks.gd, docs/registry/agent-surface.toml

# Agent Step Bridge

Mid-session file contract for the optional `play_agent_loop` windowed scenario. Python publishes one command; the engine consumes it, applies real input-phase events, and publishes one observation. No sockets. No DAP input. `play_agent` / `play_agent_passed` are unchanged.

## Runtime paths

All under `.godot-smoke/` (gitignored). Engine paths use the `res://.godot-smoke/` prefix.

- `scenario.json` — boot request: `{"scenario":"play_agent_loop"}`
- `agent_command.json` — Python writes via temp file + atomic rename. Engine consumes, then deletes.
- `agent_observation.json` — engine writes via temp file + atomic rename after each applied command.
- `play_agent_loop.json` — Python session report at exit.
- `play_agent_loop.mp4` — ffmpeg recording of the windowed play session (default on; `--no-video` or `PLAY_AGENT_RECORD_VIDEO=0` skips).
- `play_agent_findings/<slug>.json` — one replayable pack per novel anomaly (command log, compact observation, signature, seed).
- `play_agent_prior.json` — local novelty ledger; loaded automatically on the next run when `--prior-findings` is omitted.
- `play_agent_anomaly.png` — optional one-frame capture of a novel hard anomaly for advisory vision review (never the Lane-4 sweep sidecar).
- `ui_tree/loop.json` — latest UI-tree snapshot from an `observe` or any applied command.

## Command object

- `id` (string, unique per turn)
- `action` one of: `boot_new_game`, `press`, `hold`, `observe`, `file_feedback`, `quit`
- `payload` object
  - `press` / `hold`: `{"input":"<bridge input name>"}` — allowed inputs: `move_up`, `move_down`, `move_left`, `move_right`, `action_a`, `action_b`, `menu`, `build_toggle`. `menu` maps to the InputMap action `start` (Enter); the other names are InputMap actions as-is.
  - `file_feedback`: `{"message":"<1-1000 chars starting with [agent-play]>", "live": true}`
  - others: empty object

A `file_feedback` message that is empty, longer than 1000 Unicode code points, or missing the `[agent-play]` prefix is invalid. Unknown `action` values are invalid.

## Observation object

- `command_id` — echoes the applied command
- `screen` — `PerformanceMonitors.screen_label_for` string
- `monitors` — `game/current_screen`, `game/party_size`, `game/world_seed`
- `tile` — `[x, y]` or `null`
- `facing` — `[dx, dy]` or `null`
- `faced_action` — harvest resolver action on the faced tile (`cut` / `dig` / `smash`) or `""`
- `nearby` — up to 8 non-egg overworld mons in a 16-tile window: `{tile, species_id, kind}`
- `harvest_near` — nearest cut/smash/dig target `{action, tile, from_tile}` within 16 rings, or `null`
- `party_field_moves` — `cut` / `smash` / `dig` the current party can perform (`runtime.party_has_field_move_ability`). Always a list on live observations (empty when none). Optional on older packs; missing means “unknown.”
- `trace_tail` — last 40 JSONL records from this loop session (not prior playtest leftovers in the append-only `user://logs/agent_trace.jsonl`)
- `ui_tree` — `UiTreeDumpWriter.snapshot_screen` dictionary using `game/current_screen` (not a synthetic `"loop"` id)
- `exceptions` — strings
- `stuck` — true after 8 applied movement commands with the same screen+tile
- `feedback` — `null` or `{status, reason, issue_number}`

## Novelty signature

Canonical string: `screen|tile|exception_class|last_failed_event|ui_tree_structure_hash`

- `tile` is `x,y` or empty
- `ui_tree_structure_hash` hashes paths+types+text, not pixels
- Duplicate when the signature matches this session, `prior_findings`, or an open GitHub issue that already carries `[agent-play]` plus the same signature or the same screen and first hard anomaly
- Lane-4 / VLM quarantine findings alone never justify a live file. Silent-failure oracles (screen disagreement, party wipe, uncommitted catch/KO, injection failure, swallowed A, uncommitted harvest, battle stall) are hard findings. Detector E does not flag `input_swallowed:action_a` when `faced_action` is a harvest verb absent from `party_field_moves` (empty-tile A stays quiet; “tile says dig but the party cannot dig” stays quiet too). Packs without `party_field_moves` keep the previous harvest-expect behavior. An advisory review of the anomaly PNG is quarantine-forever, never auto-filed, and never writes `.godot-smoke/vision-review.json`.

## Session report

`{ok, skipped, reason, turns, anomalies, filed, skipped_duplicate, issue_number, errors:[{code,retryable,hint}], video, video_bytes, video_reason, commands, findings, world_seed, replayed, source, coverage}`

`commands` is the compact transcript (`id`, `action`, `payload`, `screen`, `tile`, `stuck`, `exception_count`). `findings` copies each novel pack written this session. `coverage` is `{screens, verbs, biomes}` from that transcript plus `biome_entered` traces. `replayed` is true when `--replay` drove the session; `source` is that pack path. Full `ui_tree` nodes stay in `.godot-smoke/ui_tree/loop.json`, not the report.

`filed` is `"live"` only when the file_feedback observation has a sent status **and** `issue_number > 0` (or a `feedback_report_sent` trace with an issue). A relay 400 / `feedback_report_failed` / dialog result without an issue is not `"live"` (issue stays 0). Dry mock `sent` with issue 0 is `"dry"`.

`video` is a project-relative path to the session mp4 when ffmpeg recorded the window, else empty. Missing ffmpeg or a display-less host does not fail `ok`; it sets `video_reason` (`ffmpeg_missing`, `no_capture_source`, `video_disabled`, `headless`, `recorder_empty`). Headless / `PLAYTEST_FORCE_HEADLESS=1` writes `{ok: true, skipped: true, reason, video_reason: "headless"}` and exits 0. A skipped lane certifies nothing.

## Flags

- `PLAY_AGENT_LIVE_FILE=0` / `false` / `no` / `off` — force `live: false` and mock transport. Unset defaults **on**, except `GITHUB_ACTIONS` or `CI` (always off, including in `verify_all`). VLM-only rows never live-file.
- `PLAY_AGENT_COMMIT_SHA` — optional public-stamp `commit_sha`. Must be `unknown` or lowercase hex `[0-9a-f]{7,64}`. The driver sets it from git HEAD (else `unknown`) before launch. The literal `agent-play` is invalid (`build_id` may still be `agent-play`).
- `PLAY_AGENT_PLANNER_CMD` — optional CLI; stdin is one observation JSON, stdout is one command JSON. Default explorer is observation-driven: `boot_new_game`, harvest (cut/smash/dig) with `action_a` only when the party can use that verb, toggle `build_toggle` and try to place, then walk onto a nearby overworld mon, fight, and try a capture. Swallowed spawn harvest A does not spend `harvest_tries` / `saw_harvest`. Hunt tries Cut/Smash/Dig on a blocking tile only when the party can use that verb (once per tile, path-clearing, not harvest coverage). If the party cannot, it stops pressing A, probes east/west, and prefers a reachable nearby mon over the blocked tile. After the verbs that are possible this session it opens menus/camp overlays (not gated on a contact battle), lingers, and keeps hunting until the 96-turn / 180s cap.
- `PLAY_AGENT_RECORD_VIDEO=0` — skip the session mp4. Default is on for windowed runs (`--no-video` is the same).
- `PLAY_AGENT_VIDEO_PATH` / `--video` — write the mp4 somewhere other than `.godot-smoke/play_agent_loop.mp4`.
- `PLAY_AGENT_FFMPEG` — ffmpeg binary; otherwise `PATH`.
- `PLAY_AGENT_FEEDBACK_ENDPOINT` — HTTPS endpoint embedded via the editor stamp for live runs. Not committed.
- `--replay PATH` — republish the pack/report `commands[]` over the same file bridge (`file_feedback` omitted so F does not re-open). Fail-closed codes: `replay_source_missing`, `replay_source_invalid`, `replay_missing_commands`. Headless still SKIP.

Finding packs stay under `.godot-smoke/` (gitignored). The public F sentence includes screen, tile, seed, a short signature, recent actions, and a repo-relative replay one-liner (`python3 tools/play_agent_loop.py --replay .godot-smoke/play_agent_findings/<slug>.json`); it stays ≤1000 chars and still starts with `[agent-play]`. Packs and mp4 are not copied into the public F ZIP or GitHub issue.

## Trace events

New only: `play_agent_loop_started`, `play_agent_step_applied`, `play_agent_anomaly_observed`, `play_agent_file_skipped`, `play_agent_loop_passed`, `play_agent_loop_failed`. Existing `feedback_*` events fire unchanged when F runs.

Turn budget 96 commands. Wall clock 180s. One file attempt per novel finding per session. Overworld mons are live for this scenario so contact battles can start.
