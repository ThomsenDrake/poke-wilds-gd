Status: current
Last verified: 2026-07-21
Review cadence days: 21
Source paths: scenes/app/Main.tscn, scripts/app/main.gd, scripts/app/smoke_scenarios.gd, scripts/app/phase0_scenarios.gd, scripts/app/snapshot_capture.gd, scripts/app/visual_sweep.gd, scripts/app/visual_sweep_baselines.gd, scripts/app/render_introspection.gd, scripts/runtime/world_view.gd, scripts/runtime/player_avatar.gd, scripts/runtime/music_router.gd, scripts/domain/world_generator.gd, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd

# Boot And Overworld

## Supported behavior

- The app boots into `res://scenes/app/Main.tscn`.
- The autoload runtime initializes source data, session state, and save state before the main scene starts normal play.
- The overworld is rebuilt from the saved seed and centered on the saved player tile.
- The player moves on a 16x16 tile grid with continuous hold-to-move stepping and a faster run modifier on `X`, rendered from the source `ben-walking.png` / `ben-running.png` sprite sheets with direction-correct frames. Draw order is y-sorted: the player renders behind tall prop canopies when standing north of them and in front when standing south.
- Grass tiles can trigger wild encounters. Water, trees, cacti, swamp trees, rock cliffs, snow trees, and lava block movement.
- Entering battle clears transient overworld message UI before the battle screen appears, plays the wild species' cry, and switches to the battle theme; when the battle ends, the fainted side's cry sounds (victory or defeat) and the biome track resumes.
- When movement is blocked the player avatar surfaces a biome-specific reason from the world view (for example "A tall tree blocks the way.").
- Each completed step advances the session clock by one minute and the step counter by one; both persist in the save. The world view tints for time of day (night, dawn, dusk) via `set_time_of_day`.
- The music router plays a biome-specific overworld track on boot and whenever the player crosses into a new biome, switches to the wild-battle theme during battle, and resumes the biome track afterward.

## Biomes and traversal

- The world is generated from a seeded elevation, moisture, and biome noise field.
- Biome selection is progressive: tiles near the origin favor plains and grassland; forests and savanna appear farther out; desert, swamp, and rock appear at greater distance; snow and lava appear deepest in the world. This makes rarer biomes harder to reach, matching the original exploration incentive.
- Biomes are defined in `scripts/domain/biome_defs.gd` as a pure data table: base texture, optional atlas region, encounter flag, walkability, block reason, and scatter props with their own block reasons.
- `world_generator.gd` picks a biome per tile and scatters biome props deterministically from the seed, then overrides high-elevation tiles with rock cliffs. Tile logic (`get_tile_logic`) is separated from texture loading (`get_tile`) so navigability and traversal probes run without touching the GPU.
- Traversal rules are data-driven: each blocked tile carries a human-readable `block_reason` with a hint and a `requires_field_move` key. Harvestable blockers (trees, cacti, swamp trees, snow trees, rock cliffs) open only by being cleared through harvesting; water opens passively while a surf-capable Pokemon is in the party. See [harvest-and-mutation.md](harvest-and-mutation.md).
- `world_view.gd` exposes `get_tile_biome`, `get_traversal_block_reason`, `tile_requires_field_move`, `set_time_of_day`, and `validate_world_invariants` for the player avatar and field-move flows, and emits a `biome_entered` trace whenever the center tile crosses into a new biome. Its per-tile data cache (`_tile_cache`) is window-evicted on every `sync_visible` pass — tiles outside the visible window are dropped AFTER the inactive-node cleanup, never mid-pass — so the cache stays bounded to the visible window (about 61×41 tiles) instead of growing without bound as the player walks; transient off-window audit queries are reclaimed on the next per-step sync.

## Navigable spawn

- `world_generator.find_walkable_spawn` searches outward from the origin in expanding rings and returns the first walkable tile that has at least two walkable neighbors and one non-encounter neighbor. New games spawn the player there instead of at `(0,0)`, which may be water or a blocked tile.
- `world_generator.reachable_walkable_count` performs a bounded flood fill from a start tile to prove the spawn is not walled off. `validate_invariants` asserts the spawn reaches at least `SPAWN_REACH_MIN` tiles within `SPAWN_REACH_BUDGET`.

## Biome-specific encounters

- `scripts/domain/biome_encounters.gd` builds encounter tables from the per-species `spawn_biomes` parsed out of the source `wilds_data.asm` files. Source biome tokens that differ from world biome ids (for example `DEEP_FOREST` or `TIDAL_BEACH`) are mapped through `SOURCE_BIOME_ALIASES`; species carrying the source `TYPE` sentinel (or no spawn data) fall back to the type-based biome table (for example `FOREST` draws from `BUG`, `GRASS`, `POISON`, `FLYING`).
- Encounter eligibility requires battle-viable species: battle sprites, a catch rate, base stats, and a learnset. The literal `EGG` never spawns.
- In grass biomes (GRASSLAND, FOREST, SAVANNA) encounters are tied to visible tall-grass patches scattered deterministically by the generator; other encounter biomes keep biome-wide encounters.
- `game_runtime.generate_wild_encounter` accepts an optional biome id and rolls from the filtered table. If no species match, the filter falls back to the full catalog and emits a `warning` trace so the escape hatch stays observable. If the catalog itself is empty, the encounter is skipped with a `warning` trace instead of fabricating a synthetic Pokemon.

## Input map

- Movement: arrow keys or `WASD`
- Confirm: `Z`
- Cancel (in menus/battle) / run modifier (in overworld): `X` — one physical key deliberately shared across two actions in mutually exclusive contexts. UI screens consume `action_b` via `_unhandled_input` only while visible; `run` is polled only during overworld movement (`is_action_pressed` while input is enabled). The contexts never overlap, so the shared key never collides (no rebind needed).
- Start menu: `Enter`

## Capture contract

- Windowed screenshot captures in `visual_sweep`, `ui_render_audit`, and `display_matrix` delegate to `scripts/app/snapshot_capture.gd` (subsystem `vision_fidelity`; see [vision-fidelity.md](vision-fidelity.md)) for a `RenderingServer.frame_post_draw` readback guard (always ADDED AFTER each scenario's existing settle waits, never a substitute), a validity oracle (minimum PNG size, luminance floor, uniform-color and magenta-frame checks), and a root-viewport-crop fallback when the battle SubViewport readback is magenta/stale (Godot 4.6 regression #115402).
- Valid captures emit `snapshot_captured`; invalid captures emit a quarantine-tier `capture_invalid` warning trace classified `transport` (headless display) or `regression` (windowed, including all magenta frames). `visual_sweep` still fails red on an invalid capture in a windowed run; `ui_render_audit` pixel-half findings route per `GRADUATED_STATES` (Slice 4; Slice 6 flipped all four battle keys true on five consecutive clean windowed runs recorded in `docs/generated/graduation-ledger.json`) — red for a graduated battle state, quarantine-tier otherwise; menu/party/bag have no keys and can never graduate. The flip changes the verification harness's finding tiering only, never game behavior (see [vision-fidelity.md](vision-fidelity.md) § Legibility oracles).
- `visual_sweep` additionally writes a canonical semantic sidecar next to each valid shot PNG (`<shot>.png.sidecar.json`; schema in [../references/snapshot-sidecar.md](../references/snapshot-sidecar.md), built by `scripts/app/render_introspection.gd` from the existing `smoke_context()` ctx dict — no `main.gd` edits), and committed sidecars sit alongside the baseline PNGs. `visual_sweep_passed` carries `sidecar_paths` and `invalid_captures`; the per-region verdict fields (`region_failures`, `clusters_explained`, `clusters_unexplained`, `region_artifacts`) are recorded by the playtest runner into `.godot-smoke/playtest-report.json` — NOT the JSONL trace — by the `tools/visual_region_diff.py` post-step (see [vision-fidelity.md](vision-fidelity.md) § Explainable per-region diff).
- Under `PLAYTEST_FORCE_HEADLESS=1`, windowed-only scenarios are reported skipped-with-reason instead of failed; the playtest report is stamped with `head_sha` plus `godot_version`/`window`/`renderer` harvested from `snapshot_captured` traces (null when no windowed capture ran).

## Smoke validation

- `boot` proves the app reaches a ready state and rebuilds the world.
- `overworld_step` proves the player can take at least one safe step and persist movement state, and asserts the world view's `_tile_cache` stays bounded to the visible window after N steps (window eviction reclaims off-window tiles).
- `save_migration` drives the runtime's real load path against v1/v2/future-version fixtures written to the live save path (inside the runner's backup/restore guard), asserting field migration and the non-destructive refusal of a newer schema; it emits `save_migration_passed`. See [menu-and-save.md](menu-and-save.md).
- `biome_probe` drives `world_view.validate_world_invariants` and emits `biome_probe_passed` when the generated world satisfies determinism, ring progression, navigable spawn, and reachability invariants.
- `biome_traverse` walks the player across a biome boundary (or teleports across one), triggers a traversal-gate block on a field-move-locked tile, then starts a biome-aware wild battle. Requires `biome_entered` or `traversal_blocked` plus a completed `encounter_started`/`battle_finished` pair.
- `field_move` finds a `cut`-gated tile, drives the party-capability field-move flow from the party screen (species flags + type auto-ability; there is no stored unlock state), and confirms the tile becomes walkable with the `field_move_used` trace.
- `world_consistency_audit` samples tiles around spawn and proves logic/render/collision agreement, player-vs-prop spatial contracts, z-order, and tall-grass/encounter alignment.
- `ui_render_audit` verifies battle and menu screens against the art-anchored render model (expected strings, label overlap, cursor pairs). Its windowed pixel half now calls the `vision_fidelity` glyph template oracle (`scripts/app/text_oracle.gd`) per battle state — expected strings rasterized to ink masks and XOR-matched at the modeled rects, with per-glyph bboxes and min-stroke checks — merged with the existing visual lint into one findings list. Findings route per `GRADUATED_STATES`: a graduated battle state's glyph mismatch / garble / low_ink fails red, non-graduated states stay quarantine-tier; at Slice 6 all four battle states graduated on recorded evidence — `battle_moves` + `battle_item` (anchor, glyph template match) and `battle_action` (lint cleanliness on ACTION_ROWS) on five consecutive clean windowed runs (`tools/graduation_ledger.py` runs 1-5 at HEAD 7b733946), `battle_message` last (box mode, lint cleanliness; glyph match excluded by design, with the documented engine-owned ~1px pen judgment in the ledger flips[] entry) — while menu/party/bag never graduate (Godot default-theme font at 12/14/20 — a different raster than fonts.ttf@7, no equivalence proof; a future author must not add menu keys). The flip is an in-place constant edit to `ui_render_audit.gd` that changes the verification harness's tiering, not the game. A zero-glyph-mismatch run emits the coded `text_oracle_passed` trace. WCAG contrast (`tools/contrast_check.py`) and color-vision-deficiency simulation (`tools/cvd_sim.py`) evidence is reported via `tools/generate_legibility_report.py` (Contrast + CVD sections) and the `visual_sweep` runner post-step; see [vision-fidelity.md](vision-fidelity.md) § Legibility oracles for the full contract.
- `display_matrix` resizes the window across six sizes and proves the battle surface renders without scale degradation at each; `visual_sweep` applies a canonical 1152x648 window size so baselines are window-size-stable. All three capture through the capture contract above but at different depths: `visual_sweep` runs the full pipeline, so every shot emits `snapshot_captured` or a quarantine-tier `capture_invalid`; `ui_render_audit`'s pixel half runs the guard plus oracle and emits `capture_invalid` only on an invalid verdict (a valid pixel-half shot emits no per-shot trace); `display_matrix` adopts the guard alone. `visual_sweep_passed` carries the canonical `window` plus `dup_checked`, `sidecar_paths`, and `invalid_captures`.
