# PokeWilds Godot Port Status

## Important constraint
The checked-in `pokewilds` repository currently contains game content/assets and localization files, but no libGDX Java source code (`.java`/Gradle project files are absent in history for this repo snapshot).  
This means the current port is a behavior reimplementation scaffold in Godot, not a direct code translation.

## Completed in this milestone
- Godot main scene bootstrapped at `res://scenes/Main.tscn`.
- Deterministic procedural overworld generation using seeded noise.
- Runtime tile rendering from existing PokeWilds textures.
- Grid-based player movement with hold-to-move behavior.
- Run modifier bound to `X` (matching legacy B/run behavior).
- Player walk animations from existing sprite sheet.
- Camera follow.
- Runtime input mapping for Arrow keys / Z / X / Enter.
- ASM/content-driven data runtime:
  - Species/base stats/learnsets parsed from `pokemon/pokemon/*/(base_stats|evos_attacks).asm`.
  - Move definitions parsed from `pokemon/moves.asm`.
  - Move category split parsed from `pokemon/spec_phys_lookup.txt`.
  - Display names from `i18n` property files.
- Global persistent game state via autoload:
  - Party, bag, world seed, player position.
  - Save/load to `user://godot_port_save.json`.
- Wild encounter system tied to grass tiles and map-distance level scaling.
- Battle MVP scene flow (overworld -> battle -> overworld):
  - Fight (move selection + PP + hit/accuracy + damage + KO).
  - Bag (Poké Ball capture and Potion healing).
  - Run.
  - Party auto-switch on faint when possible.
  - EXP rewards and level-ups after wins/catches.
- Start menu overlay:
  - Party viewer with lead swap.
  - Bag summary.
  - Save and New Game actions.
- Basic music routing:
  - Overworld and wild-battle track switching.
- DAP smoke-test hook for the running Godot editor (`tools/godot_dap_smoketest.py`).

## Not yet ported
- Full battle mechanics parity (status effects, abilities, weather, turn-order rules, move effects).
- Full party/inventory parity (PC storage, full item catalog, detailed party UI).
- Pokemon systems parity (natures, IV/EV, abilities, forms, breeding, evolutions runtime).
- NPC AI and interactions.
- World structures/building/field moves.
- Full audio manager parity (SFX routing, biome-aware playlists, battle variants).
- Multiplayer/networking.
- Full UI flow (title screen, menus, options, bag, PC, etc).

## Recommended next migration slice
1. Save file format + world chunk serialization.
2. Core data runtime for Pokemon/party/moves.
3. Turn-based battle MVP integrated with grass encounters.
4. UI navigation framework for menu screens.
