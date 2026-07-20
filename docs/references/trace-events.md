Status: current
Last verified: 2026-07-20
Review cadence days: 21
Source paths: scripts/core/trace_logger.gd, scripts/runtime/game_runtime.gd, scripts/runtime/battle_runtime.gd, scripts/runtime/world_view.gd, scripts/app/main.gd, scripts/app/smoke_scenarios.gd, scripts/app/snapshot_capture.gd
# Trace Events

All runtime traces are JSONL records with `event`, `ts_msec`, `source`, and `payload`.

| Event | Source | Meaning |
| --- | --- | --- |
| `boot_started` | `App.Main` | Main scene startup has begun. |
| `boot_ready` | `App.Main` | Main scene finished boot wiring and is ready for play. |
| `session_loaded` | `GameRuntime` | Existing save state loaded successfully. |
| `session_created` | `GameRuntime` | A new session was created because no valid save was available. |
| `world_rebuilt` | `App.Main` | World view rebuilt around the current seed and tile position. |
| `biome_entered` | `WorldView` | Player crossed into a different biome; payload carries biome id and tile. |
| `traversal_blocked` | `App.Main` | Player attempted to move onto a blocked tile; payload carries tile, reason, and required field move. |
| `biome_probe_passed` | `SmokeScenarios` | The `biome_probe` smoke scenario confirmed world-generation invariants (determinism, ring progression, navigable spawn, reachability); payload carries seed, spawn, and reachable count. |
| `menu_opened` | `App.Main` | The start menu became visible. |
| `menu_closed` | `App.Main` | The start menu was closed and control returned to the overworld. |
| `encounter_started` | `GameRuntime` | A wild battle started. |
| `battle_finished` | `BattleRuntime` | A battle ended with a final outcome payload. |
| `attack_animation_played` | `BattleView` | A battle move animation played (source set or synthesized fallback); payload carries move_id, anim_key, frames, sound, fallback. |
| `battle_anim_passed` | `SmokeScenarios` | The `battle_anim` scenario verified a scripted animated move plays its frame set with sound and resolves its turn. |
| `display_matrix_passed` | `SmokeScenarios` | The `display_matrix` scenario verified battle content renders without scale degradation across a matrix of window sizes (block-uniformity plus round-trip consistency); payload carries sizes_checked and max drift percent. |
| `save_written` | `GameRuntime` | Runtime state was written to disk. |
| `field_move_used` | `GameRuntime` | A harvest field move cleared or dug a tile; payload carries move id, tile, and the yielded item id. |
| `field_move_scenario_passed` | `SmokeScenarios` | The `field_move` smoke scenario confirmed a cut-gated tile cleared and stayed walkable after a save round-trip; payload carries move id, tile, yield, and save check. |
| `harvest_flow_passed` | `SmokeScenarios` | The `harvest_flow` scenario verified harvest refusal without capability, cut/dig/smash yields, cleared logic, and save/reload persistence; payload carries the three tiles and save check. |
| `playtest_journey_passed` | `SmokeScenarios` | The `playtest_journey` scripted playthrough completed the full loop (new game, steps, battle, menu, save round-trip); payload carries outcome, steps, party size, and save check. |
| `playtest_soak_passed` | `SmokeScenarios` | The `playtest_soak` seeded bot completed its iteration budget with all invariants holding; payload carries seed, iterations, steps, battles, and outcome counts. |
| `nav_audit_passed` | `SmokeScenarios` | The `nav_audit` scenario verified traversal agreement (blocked/walkable tiles and field-move gates), battle menu reachability and model/cursor consistency, and start-menu navigation; payload carries per-area check counts. |
| `texture_audit_passed` | `SmokeScenarios` | The `texture_audit` scenario verified every battle sprite (frame-crop shape/ink) and every overworld tile/prop texture (keying, no opaque borders) through the real loaders; payload carries species, frame, and tile counts. |
| `data_audit_passed` | `SmokeScenarios` | The `data_audit` scenario verified encounter-pool battle viability (sprites, catch rate, learnset, known types), instance integrity across levels, and starting-bag catalog resolution; payload carries biome, species, and instance counts. |
| `layout_audit_passed` | `SmokeScenarios` | The `layout_audit` scenario verified worst-case label fit and cursor/row alignment across battle, start menu, party, and bag screens; payload carries label, cursor, and screen counts. |
| `world_consistency_audit_passed` | `SmokeScenarios` | The `world_consistency_audit` scenario verified tile logic/render/collision agreement plus spatial, z-order, and tall-grass contracts around spawn; payload carries tiles_checked, movement_checked, spatial_checked, failures. |
| `ui_render_audit_passed` | `SmokeScenarios` | The `ui_render_audit` scenario verified expected strings, label overlap, and cursor pairs against the art-anchored render model across battle and menu states; payload carries states_checked, labels_checked, cursors_checked, quarantined. |
| `quarantine_finding` | `SmokeScenarios` | A quarantined heuristic pixel check reported a possible visual defect; payload carries state, kind (`low_ink`/`forbidden_ink`/`garble`/`lint_unavailable`), and region. Never fails a scenario until graduated. |
| `snapshot_captured` | `App.SnapshotCapture` | A windowed capture passed the validity oracle; payload carries shot, shot_seq, ts_msec, trace_cursor (join key into user://logs/agent_trace.jsonl — the record lands at cursor+1), window [w, h], renderer, and godot_version. sidecar_path is reserved for Slice 3 and absent from Slice 1 payloads. |
| `capture_invalid` | `App.SnapshotCapture` | A capture failed the validity oracle or a duplicate pair differed; payload carries shot, kind (blank/uniform/magenta/undersize/headless/nondeterministic_pair), classification (transport/regression — magenta is always regression), luminance (0.0-1.0), and detail with the identified cause. Warning tier: never fails a scenario on its own. |
| `visual_sweep_passed` | `SmokeScenarios` | The `visual_sweep` scenario captured its deterministic screenshot set and matched baselines within threshold (or updated them in update mode); payload carries shots, compared, mismatched, max drift percent, mode, window, and dup_checked. |
| `warning` | multiple | Non-fatal warnings worth surfacing to agents. |
