Status: current
Last verified: 2026-07-20
Review cadence days: 21
Source paths: scripts/app/render_introspection.gd, scripts/app/snapshot_capture.gd, scripts/app/ui_render_model.gd, scripts/app/visual_sweep.gd, tools/visual_region_diff.py

# Snapshot Sidecar

Each VALID `visual_sweep` capture writes a canonical JSON sidecar next to its PNG. Sidecars carry the semantic render state an agent needs to explain a pixel diff with NO vision: labels, draw order, palettes, expected regions, the canary rect. The schema is single-sourced by two suppliers: `scripts/app/render_introspection.gd` (the semantic collector — labels/draw order/cursor pairs/expected regions/canary rect/capture env/crafted state) and `scripts/app/snapshot_capture.gd` (the writer host — capture stamps, validity, palettes from the readback, `JSON.stringify` + file write). Spec context: [vision-fidelity.md](../product-specs/vision-fidelity.md).

## File naming and lifecycle

- Name: `<shot>.png.sidecar.json` — the FULL PNG filename plus the `.sidecar.json` suffix (pin this spelling), e.g. `09_battle.png.sidecar.json`. Always a sibling of its PNG.
- Fresh sidecars live in `.godot-smoke/shots/` (gitignored, rewritten every sweep); committed baseline sidecars live in `docs/generated/visual-baselines/` next to the baseline PNGs.
- Written by `snapshot_capture.capture()` for VALID captures only, when `options.metadata` is non-empty; path = `save_path + ".sidecar.json"`. `ui_render_audit` and `display_matrix` consume only `guard_readback()` + `classify()` — they never run the full `capture()` pipeline, emit NO `snapshot_captured` trace, and write no sidecars.
- Baseline sidecars are (re)written exactly when baselines are: `visual_sweep_baselines.gd` `_update_baselines` copies each sidecar alongside its PNG, the prune pass removes stale `*.sidecar.json`, and `clear_shots` removes them — PNG and sidecar can never desync. Regenerate on the same triggers as baselines (any `project.godot` rendering/display pin change, Godot binary bump, driver/renderer change, intentional visual change) via `python3 tools/run_playtests.py --scenario visual_sweep_update` — see [RELIABILITY.md](../RELIABILITY.md).

## Canonical form (byte-stability policy)

- `JSON.stringify(metadata)`: compact (indent `""`), keys sorted RECURSIVELY (Godot's JSON default, verified on 4.6.1), no trailing newline (`store_string`).
- All rects are INTEGER-truncated pixel rects via `UiRenderModel.map_region` (scale = `display_rect.size.x / 160.0`, `int()` truncation — the canonical int semantics for the whole file).
- Palettes are `#rrggbb` hex strings, sorted lexicographically, alpha dropped (frames are opaque).
- Godot prints ints as `5` and floats as `5.0`, so every numeric field except `validity.luminance` and `draw_order[].y_sort` is an int.
- The result is byte-stable per seed with TWO documented run-varying fields: `ts_msec` is `Time.get_ticks_msec()` — real ms since process BOOT — and drifts across runs (measured: shot 01 ts 1736 vs 1974 in two consecutive sweeps); `trace_cursor` is an absolute line number into the append-only `agent_trace.jsonl` and shifts each run by exactly the lines the PRIOR run appended (measured: constant delta 43 across all 16 shots between consecutive sweeps — structurally run-varying, not nondeterminism). Byte-stability verification normalizes exactly those two fields (`json.load` → pop `ts_msec` and `trace_cursor` → `json.dumps(sort_keys=True)`) and asserts every other byte matches; do NOT assume, verify. `ts_msec` and `trace_cursor` MUST equal the `snapshot_captured` payload's values or the trace join below lies. Committed baseline sidecars are written once per baseline regeneration, so git diffs stay clean.
- Of the two float fields, only `validity.luminance` depends on captured pixels; its string form is deterministic only because captured pixels are bit-identical per seed (it is a pure function of the image bytes). `draw_order[].y_sort` (the other float — `WorldDrawOrder.y_sort_key`'s `global_position.y`, or `null`) prints deterministically because world positions are grid-snapped. The DUPCHECK noise-floor gate (3 consecutive zero-delta runs; see [RELIABILITY.md](../RELIABILITY.md)) is the arming precondition that covers the luminance case.

## Field schema

| Field | Type | Supplier | Meaning |
| --- | --- | --- | --- |
| `shot` | String | `capture()` | Shot filename (`09_battle.png`); equals the sibling PNG name. |
| `shot_seq` | int | `capture()` | 1-based per SnapshotCapture instance (1..16 across a sweep). |
| `ts_msec` | int | `capture()` | `Time.get_ticks_msec()` at capture time (boot clock). One of two run-varying fields; equals the `snapshot_captured` payload `ts_msec`. |
| `trace_cursor` | int | `capture()` | `SmokeScenarioRunner.trace_log_line_count()` sampled BEFORE the readback. Join key: the `snapshot_captured` record sits at 1-based line `cursor+1` of `user://logs/agent_trace.jsonl`. The second run-varying field (append-only log: shifts per run by the prior run's line count, constant across all shots in a run). |
| `window` | [int, int] | `capture()` | `DisplayServer.window_get_size()` — canonical `[1152, 648]`. |
| `crafted_state` | Dictionary | introspection | The `visual_sweep` crafted state: `world_seed` (20260717), `time_of_day` (720), `party` (`[["DECIDUEYE", 20], ["CHIKORITA", 5]]`), `bag` (`{"poke_ball": 5, "potion": 3}`), `battle_rng_seed` (20260717), `wild` (`["DECIDUEYE", 18]`). |
| `capture_env` | Dictionary | introspection | Baseline provenance: `renderer` (ProjectSettings `rendering/renderer/rendering_method` — `RenderingServer.get_current_renderer()` absent on 4.6.1), `adapter_name` (`RenderingServer.get_video_adapter_name()`), `adapter_version` (`get_video_adapter_api_version()`), `driver_info` (PINNED `[]` — `get_video_adapter_driver_info()` absent on 4.6.1), `godot_version` (`Engine.get_version_info().string`, `4.6.1-stable (official)`). |
| `labels` | Array[Dictionary] | introspection | `{text: String, stage_rect: [int4], display_rect: [int4]}` per visible label (`UiRenderModel.visible_labels` + `ink_rect`, mapped). Roots selected per shot kind — see below. |
| `draw_order` | Array[Dictionary] | introspection | `{node: String, z: int, y_sort: float-or-null, rect: [int4] or [], texture: String}` composed from `WorldDrawOrder`. Battle: BattleStage CanvasItem children sorted by `draws_over`, rect = int stage global rect, texture = baked-art `resource_path` (stable). Overworld: `World/GroundLayer`, `World/PropLayer`, `Player` ordered via `draws_over`/`effective_z`/`y_sort_key` (bounded to layer nodes + player, not every tile sprite). Menu shots: `[]`. |
| `palettes` | Dictionary | `capture()` | `{"canary": [String], "hud": [String]}` — `#rrggbb` hex from a manual distinct-RGB scan (`RenderIntrospection.palette_colors`; `Image.get_used_colors()` does NOT exist on 4.6.1) over the introspection-supplied `palette_regions` (canary + hud interiors only — never full-frame without strided sampling). Non-battle: `{"canary": [], "hud": []}`. |
| `cursor_pairs` | Array[Dictionary] | introspection | `{id: String, cursor: [int4], row: [int4], live: [int4] or []}` — `UiRenderModel.expected()` pairs mapped via `map_region`, plus the live `$Cursor` TextureRect mapped global rect (`[]` when hidden). The `cursor` + `live` rects are the MASKED known-dynamic zones for the region diff; `row` is deliberately NOT masked (it spans the whole menu row and would cover label ink). |
| `expected_regions` | Dictionary | introspection | `{"ink": [[int4]], "forbidden": [[int4]], "strings": [{text: String, region: [int4], mode: String, avoid: [[int4]]}]}` — `UiRenderModel.expected(state, snapshot)` with all Rect2s mapped. Empty for non-battle states. |
| `canary_rect` | [int4] or [] | introspection | `EnemySprite` display rect — `(640, 68, 224, 224)` on battle shots 09-12 (the DECIDUEYE canary; see vision-fidelity.md § DECIDUEYE canary rect), `[]` on non-battle. The region gate compares PIXELS inside this rect, not the rect itself. |
| `validity` | Dictionary | `capture()` | `{luminance: float, uniform: bool, bytes: int}` from the `classify()` verdict: `luminance` = sampled Rec.709 mean (the only float in this dict), `bytes` = PNG byte size. `uniform` is ALWAYS `false` in a written sidecar — structurally, not by measurement: only valid captures write sidecars, and a `uniform` verdict invalidates the capture before the write. |

### Injection split

`RenderIntrospection.collect(ctx, shot_name, crafted_state)` builds `{crafted_state, capture_env, labels, draw_order, cursor_pairs, expected_regions, canary_rect, palette_regions}`. `capture()` injects `{shot, shot_seq, ts_msec, trace_cursor, window, validity}` and converts the intermediate `palette_regions` spec into `palettes` by scanning the readback image, then stringifies and writes. `sidecar_path` (`""` when none) also joins the `snapshot_captured` trace payload and `capture()`'s return dict. The collector consumes the existing `smoke_context()` ctx dict from `main.gd` — `main.gd` stays untouched.

### Label roots per shot kind

`UiRenderModel.shown()` walks parents only UP TO a Viewport, so a HIDDEN `BattleView` root does NOT mask labels inside its SubViewport — stale battle HUD labels would read as "shown" and poison the label join (spurious `label_moved`/`label_deleted`) if introspection walked `battle_view` outside battle. Roots are therefore selected per shot kind:

- Battle shots (09-12): `[BattleViewport/BattleStage]` (the Control hosting all battle Labels + `$Cursor` + `$EnemySprite`). `stage_rect` = int-truncated `ink_rect` (SubViewport 160x144 1:1 = stage coords); `display_rect` = `map_region(stage_rect, BattleDisplay.get_global_rect())` with `BattleDisplay` at `(256, 36, 640, 576)` under the canonical 1152x648 window (integer scale k=4).
- Menu shots (06-08): `[ctx.start_menu]`. Root-viewport labels: `stage_rect == display_rect` == int-truncated `ink_rect` (identity mapping, window px).
- Overworld shots (01-05): `[]` (the message box is hidden; do NOT walk `battle_view`).

### Battle state derivation

`expected_regions` reads the LIVE view: `_menu_state` `"moves"` → `battle_moves`, `"item"` → `battle_item`, `"action"` → `battle_message` if `_message != ""` else `battle_action`; the snapshot is the view's snapshot merged with `{"message": _message}`. `UiRenderModel.expected` returns empty lists for overworld/menu states.

## Correlation protocol (PNG ↔ sidecar ↔ agent_trace.jsonl ↔ playtest-report.json)

Correlation is total:

1. **PNG ↔ sidecar** — sibling naming: `<shot>.png.sidecar.json` sits next to `<shot>.png` and `sidecar.shot` equals the PNG filename. Every committed baseline PNG has a committed sidecar sibling; `check_repo_contracts.py` enforces region coverage (sidecar carries `expected_regions` + `canary_rect` keys; battle shots 09-12 carry a non-empty `canary_rect` and non-empty `labels`).
2. **Sidecar ↔ agent_trace.jsonl** — read 1-based line `sidecar.trace_cursor + 1` of `user://logs/agent_trace.jsonl` (`~/Library/Application Support/Godot/app_userdata/PokeWilds-Godot/logs/agent_trace.jsonl`). That record MUST be `snapshot_captured` with `payload.shot == sidecar.shot`, `payload.ts_msec == sidecar.ts_msec`, `payload.trace_cursor == sidecar.trace_cursor`, and `payload.sidecar_path` naming this sidecar. Nothing emits a trace between the cursor sample and `snapshot_captured`, so the record lands at cursor+1 (verified 32/32 on pre-Slice-3 logs; re-proven through the sidecar fields for shots 01/09/12 in the Slice 3 validation pass). Note the trace ENVELOPE stamps its own `ts_msec` at write time (e.g. 1765 vs payload 1736) — the sidecar mirrors the PAYLOAD `ts_msec`, not the envelope's.
3. **Sidecar ↔ playtest-report.json** — `tools/visual_region_diff.py` joins fresh shot sidecars (`.godot-smoke/shots/`) against committed baseline sidecars (`docs/generated/visual-baselines/`) and the playtest runner records the verdict on the `visual_sweep` scenario entry: `region_failures` (`[{shot, kind, region: [int4], detail}]` with kind one of `canary_absent`/`canary_shifted`/`palette_dropped`/`label_deleted`/`label_moved`/`label_overlap_sprite`/`string_drift`/`region_ink_lost`/`global_backstop` — the exact vocabulary `tools/visual_explain.py` emits), `region_quarantine` (same record shape; kind `region_drift` for non-red/unexplained clusters, or `sidecar_absent` when a baseline sidecar is locally missing and the shot's gate degrades to the global backstop — a surfaced warning, never a failure), `clusters_explained`, `clusters_unexplained`, `region_artifacts`. These fields are REPORT-TIER ONLY — the engine never runs the region diff, so they are never emitted in the JSONL trace. Non-red drift and unexplained clusters are additionally recorded in the report quarantine section as `quarantine_finding` kind `region_drift`.
4. **Freshness / provenance** — the report carries `head_sha`/`godot_version`/`window`/`renderer` stamps; each sidecar's `capture_env` duplicates renderer/adapter/godot_version per shot for baseline provenance. A baseline captured under a different binary or driver must not be diffed — refuse-on-mismatch is human/agent-enforced policy until `tools/verify_all.py` mechanizes it.
