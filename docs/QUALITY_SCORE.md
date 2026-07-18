Status: current
Last verified: 2026-07-17
Review cadence days: 14
Source paths: docs/registry/subsystems.toml, scripts, scenes, tools

# Quality Score

Scores use `0-3` where `3` means strong, mechanically supported coverage.

| Subsystem | Layer | Quality bucket | Legibility | Validation | Architecture | Product completeness | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `app_bootstrap` | `app` | `bootstrap` | 3 | 3 | 3 | 2 | Boot and scene wiring are explicit, trace-backed, and smoke scenarios are extracted into `smoke_scenarios.gd` with biome probe, traverse, and field-move coverage. Automated playtests (`playtest_journey`, `playtest_soak`) run through `tools/run_playtests.py`. `main.gd` is at the line budget ceiling; split before the next app-layer addition. |
| `session_runtime` | `runtime` | `runtime` | 3 | 3 | 3 | 2 | Save schema v2 (bag, time of day, steps) with v1 migration, biome/battle music routing, traces, and smoke scenario bootstrapping are centralized. |
| `world_runtime` | `runtime` | `world` | 3 | 3 | 3 | 3 | Progressive biome generation with data-driven traversal rules, species-level spawn tables with source-token aliases, navigable spawn with reachability proof, field-move-gated walkability, and day/night presentation. `validate_invariants` is exercised by the `biome_probe` smoke scenario. |
| `pokemon_data` | `data` | `data` | 3 | 2 | 3 | 3 | 954 species, 299 moves, and 113 items parsed from the source tree (base stats, evolutions, spawn biomes, field-move flags, dex data); parsing is split into single-purpose parsers with a summary warning trace. |
| `pokemon_progression` | `domain` | `progression` | 2 | 2 | 3 | 3 | Growth-curve EXP, level-up move learning, and level/item/happiness evolution checks are extracted into pure domain rules. |
| `battle_loop` | `runtime` | `battle` | 2 | 2 | 3 | 2 | Battle runs on mainline formulas (type chart, stat stages, status effects, capture, EXP yield, level evolution) with smoke coverage; attack animations and battle audio are still missing. |
| `menu_ui` | `ui` | `ui` | 3 | 2 | 3 | 3 | Start menu now hosts a full party screen (swap lead, summary, field moves) and bag screen (item use on party), trace-backed and cooperating with battle transitions. |
