Status: current
Last verified: 2026-07-17
Review cadence days: 21
Source paths: scenes/app/Main.tscn, scripts/app/main.gd, scripts/app/smoke_scenarios.gd, scripts/runtime/world_view.gd, scripts/runtime/player_avatar.gd, scripts/runtime/music_router.gd, scripts/domain/world_generator.gd, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd

# Boot And Overworld

## Supported behavior

- The app boots into `res://scenes/app/Main.tscn`.
- The autoload runtime initializes source data, session state, and save state before the main scene starts normal play.
- The overworld is rebuilt from the saved seed and centered on the saved player tile.
- The player moves on a 16x16 tile grid with continuous hold-to-move stepping and a faster run modifier on `X`, rendered from the source `ben-walking.png` / `ben-running.png` sprite sheets with direction-correct frames. Draw order is y-sorted: the player renders behind tall prop canopies when standing north of them and in front when standing south.
- Grass tiles can trigger wild encounters. Water, trees, cacti, swamp trees, rock cliffs, snow trees, and lava block movement.
- Entering battle clears transient overworld message UI before the battle screen appears.
- When movement is blocked the player avatar surfaces a biome-specific reason from the world view (for example "A tall tree blocks the way.").
- Each completed step advances the session clock by one minute and the step counter by one; both persist in the save. The world view tints for time of day (night, dawn, dusk) via `set_time_of_day`.
- The music router plays a biome-specific overworld track on boot and whenever the player crosses into a new biome, switches to the wild-battle theme during battle, and resumes the biome track afterward.

## Biomes and traversal

- The world is generated from a seeded elevation, moisture, and biome noise field.
- Biome selection is progressive: tiles near the origin favor plains and grassland; forests and savanna appear farther out; desert, swamp, and rock appear at greater distance; snow and lava appear deepest in the world. This makes rarer biomes harder to reach, matching the original exploration incentive.
- Biomes are defined in `scripts/domain/biome_defs.gd` as a pure data table: base texture, optional atlas region, encounter flag, walkability, block reason, and scatter props with their own block reasons.
- `world_generator.gd` picks a biome per tile and scatters biome props deterministically from the seed, then overrides high-elevation tiles with rock cliffs. Tile logic (`get_tile_logic`) is separated from texture loading (`get_tile`) so navigability and traversal probes run without touching the GPU.
- Traversal rules are data-driven: each blocked tile carries a human-readable `block_reason` and a `requires_field_move` key naming the field move (`cut`, `surf`, `smash`) that would clear it. `world_view.is_tile_walkable` gates on unlocked field moves: a blocked tile becomes walkable when the runtime reports its field move as unlocked.
- `world_view.gd` exposes `get_tile_biome`, `get_traversal_block_reason`, `tile_requires_field_move`, `set_time_of_day`, and `validate_world_invariants` for the player avatar and field-move flows, and emits a `biome_entered` trace whenever the center tile crosses into a new biome.

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
- Cancel / run: `X`
- Start menu: `Enter`

## Smoke validation

- `boot` proves the app reaches a ready state and rebuilds the world.
- `overworld_step` proves the player can take at least one safe step and persist movement state.
- `biome_probe` drives `world_view.validate_world_invariants` and emits `biome_probe_passed` when the generated world satisfies determinism, ring progression, navigable spawn, and reachability invariants.
- `biome_traverse` walks the player across a biome boundary (or teleports across one), triggers a traversal-gate block on a field-move-locked tile, then starts a biome-aware wild battle. Requires `biome_entered` or `traversal_blocked` plus a completed `encounter_started`/`battle_finished` pair.
- `field_move` finds a `cut`-gated tile, drives the party-screen field-move unlock path, and confirms the tile becomes walkable with the `field_move_used` trace.
- `world_consistency_audit` samples tiles around spawn and proves logic/render/collision agreement, player-vs-prop spatial contracts, z-order, and tall-grass/encounter alignment.
- `ui_render_audit` verifies battle and menu screens against the art-anchored render model (expected strings, label overlap, cursor pairs) with a windowed pixel lint whose findings are quarantine-tier.
