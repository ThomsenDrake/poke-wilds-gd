Status: current
Last verified: 2026-07-18
Review cadence days: 21
Source paths: scripts/domain/world_overrides.gd, scripts/domain/field_moves.gd, scripts/runtime/harvest_resolver.gd, scripts/runtime/game_runtime.gd, scripts/app/harvest_flow_scenario.gd

# Harvest And Mutation

## Supported behavior

- The player can harvest the environment with field moves: `CUT` on tree, cactus, swamp-tree, and snow-tree props yields a log; `DIG` on walkable ground yields dry soil (plains/forest/savanna/swamp), dry sand (beach), or soft sand (desert); `SMASH` on rock cliffs yields a hard stone.
- Pressing `Z` in the overworld resolves the action for the faced tile when any party member is capable; the party screen's `FIELD MOVE` action resolves it with the chosen party member ("X can't use that here." on failure).
- Capability is party-based: a species flag of 1 always allows the move, a flag of 2 forbids it, and otherwise the move's auto-ability type decides (GRASS→cut, GROUND→dig, ROCK→smash, and so on). Surf additionally requires a Water type at its final evolution stage.
- Harvested tiles change permanently: cut and smashed tiles are cleared (prop removed, walkable), dug tiles lose tall grass and their encounter flag. Re-harvesting a harvested tile is refused.
- Blocked tiles report a hint with their reason ("A tall tree blocks the way. It could be CUT.").
- Surf is a passive gate: water is walkable while a surf-capable Pokemon is in the party. There are no stored unlocks; the old global-unlock model is gone.

## Persistence

- Overrides persist in save schema v3 (`world_overrides` keyed `"x,y"`, up to 10k entries) and survive save/load and world rebuilds. v1/v2 saves migrate; the legacy `unlocked_field_moves` key is dropped.

## Smoke validation

- `harvest_flow` proves refusal without a capable party member, then cut/dig/smash with yields and trace payloads, cleared logic, and save/reload persistence.
- `field_move` drives the resolver on a cut tile and proves blocked→cleared with a save round-trip.
- `world_consistency_audit` checks overridden tiles agree across logic, render, and collision, and appear in `overrides_for_save()`.
