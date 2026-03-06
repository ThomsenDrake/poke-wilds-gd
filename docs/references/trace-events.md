Status: current
Last verified: 2026-03-06
Review cadence days: 21
Source paths: scripts/core/trace_logger.gd, scripts/runtime/game_runtime.gd, scripts/runtime/battle_runtime.gd, scripts/app/main.gd

# Trace Events

All runtime traces are JSONL records with `event`, `ts_msec`, `source`, and `payload`.

| Event | Source | Meaning |
| --- | --- | --- |
| `boot_started` | `App.Main` | Main scene startup has begun. |
| `boot_ready` | `App.Main` | Main scene finished boot wiring and is ready for play. |
| `session_loaded` | `GameRuntime` | Existing save state loaded successfully. |
| `session_created` | `GameRuntime` | A new session was created because no valid save was available. |
| `world_rebuilt` | `App.Main` | World view rebuilt around the current seed and tile position. |
| `menu_opened` | `App.Main` | The start menu became visible. |
| `menu_closed` | `App.Main` | The start menu was closed and control returned to the overworld. |
| `encounter_started` | `GameRuntime` | A wild battle started. |
| `battle_finished` | `BattleRuntime` | A battle ended with a final outcome payload. |
| `save_written` | `GameRuntime` | Runtime state was written to disk. |
| `warning` | multiple | Non-fatal warnings worth surfacing to agents. |
