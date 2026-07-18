Status: current
Last verified: 2026-07-17
Review cadence days: 45
Source paths: pokewilds/pokemon/pokemon, pokewilds/pokemon/moves.asm, pokewilds/pokemon/spec_phys_lookup.txt, pokewilds/i18n, pokewilds/tiles, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd

# Source Assets

The checked-in `pokewilds/` subtree is treated as an imported source-data and content snapshot.

## Parsed directly by the runtime

- `pokewilds/pokemon/pokemon/*/(base_stats.asm|evos_attacks.asm)`
- `pokewilds/pokemon/moves.asm`
- `pokewilds/pokemon/spec_phys_lookup.txt`
- `pokewilds/i18n/attack.properties`
- `pokewilds/i18n/pokemondisplayname.properties`

## Referenced directly by scenes or runtime

- `pokewilds/music/*.ogg`
- `pokewilds/player/kris-walking.png`
- battle sprites and world tiles under `pokewilds/pokemon/` and `pokewilds/tiles/`
- biome base and prop tiles under `pokewilds/tiles/` (water, sand, grass, savanna, desert, swamp, cave, ice, lava, mountain, trees, cacti, flowers, rocks) referenced by `scripts/domain/biome_defs.gd`

## Working rule

Treat `pokewilds/` as source content. Port behavior should be documented in repo-local specs and runtime code, not in assumptions about the original libGDX project.
