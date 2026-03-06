Status: current
Last verified: 2026-03-06
Review cadence days: 14
Source paths: docs/registry/subsystems.toml, scripts, scenes, tools

# Quality Score

Scores use `0-3` where `3` means strong, mechanically supported coverage.

| Subsystem | Layer | Quality bucket | Legibility | Validation | Architecture | Product completeness | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `app_bootstrap` | `app` | `bootstrap` | 3 | 2 | 3 | 2 | Boot and scene wiring are explicit and trace-backed. |
| `session_runtime` | `runtime` | `runtime` | 3 | 2 | 3 | 2 | Save/load, traces, and smoke scenario bootstrapping are centralized. |
| `world_runtime` | `runtime` | `world` | 2 | 2 | 3 | 2 | Overworld slice is present but still intentionally small. |
| `pokemon_data` | `data` | `data` | 2 | 1 | 3 | 2 | Parsing is explicit, but data-validation depth is still limited. |
| `pokemon_progression` | `domain` | `progression` | 2 | 1 | 3 | 2 | EXP and move progression are extracted into domain rules. |
| `battle_loop` | `runtime` | `battle` | 2 | 2 | 3 | 2 | Battle flow is split across runtime rules and UI with smoke coverage. |
| `menu_ui` | `ui` | `ui` | 3 | 2 | 3 | 2 | Menu behavior is small, direct, and trace-backed. |
