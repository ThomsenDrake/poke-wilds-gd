Status: current
Last verified: 2026-07-17
Review cadence days: 21
Source paths: scripts/core/trace_logger.gd, scripts/runtime/game_runtime.gd, scripts/runtime/battle_runtime.gd, scripts/runtime/world_view.gd, scripts/app/main.gd, scripts/app/smoke_scenarios.gd
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
| `save_written` | `GameRuntime` | Runtime state was written to disk. |
| `field_move_used` | `App.Main` | A field move was used from the party screen; payload carries the move id, and traversal gating for that move is now unlocked. |
| `field_move_scenario_passed` | `SmokeScenarios` | The `field_move` smoke scenario confirmed a field-move-gated tile became walkable after the unlock; payload carries move id, tile, and whether the move was already unlocked. |
| `playtest_journey_passed` | `SmokeScenarios` | The `playtest_journey` scripted playthrough completed the full loop (new game, steps, battle, menu, save round-trip); payload carries outcome, steps, party size, and save check. |
| `playtest_soak_passed` | `SmokeScenarios` | The `playtest_soak` seeded bot completed its iteration budget with all invariants holding; payload carries seed, iterations, steps, battles, and outcome counts. |
| `nav_audit_passed` | `SmokeScenarios` | The `nav_audit` scenario verified traversal agreement (blocked/walkable tiles and field-move gates), battle menu reachability and model/cursor consistency, and start-menu navigation; payload carries per-area check counts. |
| `texture_audit_passed` | `SmokeScenarios` | The `texture_audit` scenario verified every battle sprite (frame-crop shape/ink) and every overworld tile/prop texture (keying, no opaque borders) through the real loaders; payload carries species, frame, and tile counts. |
| `data_audit_passed` | `SmokeScenarios` | The `data_audit` scenario verified encounter-pool battle viability (sprites, catch rate, learnset, known types), instance integrity across levels, and starting-bag catalog resolution; payload carries biome, species, and instance counts. |
| `layout_audit_passed` | `SmokeScenarios` | The `layout_audit` scenario verified worst-case label fit and cursor/row alignment across battle, start menu, party, and bag screens; payload carries label, cursor, and screen counts. |
| `visual_sweep_passed` | `SmokeScenarios` | The `visual_sweep` scenario captured its deterministic screenshot set and matched baselines within threshold (or updated them in update mode); payload carries shots, compared, mismatched, max drift percent, and mode. |
| `warning` | multiple | Non-fatal warnings worth surfacing to agents. |
