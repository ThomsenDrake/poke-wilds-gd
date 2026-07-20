Status: current
Last verified: 2026-07-17
Review cadence days: 14
Source paths: docs/registry/subsystems.toml, scripts, scenes, tools

# Quality Score

Scores use `0-3` where `3` means strong, mechanically supported coverage.

| Subsystem | Layer | Quality bucket | Legibility | Validation | Architecture | Product completeness | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `app_bootstrap` | `app` | `bootstrap` | 3 | 3 | 3 | 2 | Boot and scene wiring are explicit, trace-backed, and smoke scenarios are extracted into `smoke_scenarios.gd`. The oracle suite runs four lanes: journey/soak playtests, nav/texture/data/layout audits, world-consistency and UI-render-model audits, and a deterministic visual sweep with baseline diffing plus agent vision review. |
| `session_runtime` | `runtime` | `runtime` | 3 | 3 | 3 | 2 | Save schema v2 (bag, time of day, steps) with v1 migration, biome/battle music routing, traces, and smoke scenario bootstrapping are centralized. |
| `world_runtime` | `runtime` | `world` | 3 | 3 | 3 | 3 | Progressive biome generation with data-driven traversal rules, species-level spawn tables with source-token aliases, navigable spawn with reachability proof, field-move-gated walkability, and day/night presentation. `validate_invariants` is exercised by the `biome_probe` smoke scenario. |
| `pokemon_data` | `data` | `data` | 3 | 2 | 3 | 3 | 954 species, 299 moves, and 113 items parsed from the source tree (base stats, evolutions, spawn biomes, field-move flags, dex data); parsing is split into single-purpose parsers with a summary warning trace. |
| `pokemon_progression` | `domain` | `progression` | 2 | 2 | 3 | 3 | Growth-curve EXP, level-up move learning, level/item/happiness evolution checks, and gender assignment from species ratios (drives infatuation) are extracted into pure domain rules. |
| `battle_loop` | `runtime` | `battle` | 3 | 3 | 3 | 3 | Battle runs on mainline formulas (type chart, stat stages, status and volatile conditions, capture, EXP yield, level evolution, priority turn order) with per-move source animations (frame-paced and deterministic, KO blows included), species cries, integer-scaled crisp presentation, and scenario coverage (`wild_battle`, `battle_anim`, `ui_render_audit`). |
| `menu_ui` | `ui` | `ui` | 3 | 2 | 3 | 3 | Start menu now hosts a full party screen (swap lead, summary, field moves) and bag screen (item use on party), trace-backed and cooperating with battle transitions. |
| `harvest_loop` | `runtime` | `harvest` | 3 | 3 | 3 | 2 | Harvesting resolves cut/dig/smash on faced tiles with party capability, permanent sparse overrides, and save v3 persistence; building placement is the follow-up that will raise completeness. |
