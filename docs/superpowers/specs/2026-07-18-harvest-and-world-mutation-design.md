Status: approved
Last verified: 2026-07-18
Review cadence days: 30
Date: 2026-07-18
Source paths: scripts/domain/world_generator.gd, scripts/runtime/world_view.gd, scripts/runtime/game_runtime.gd, scripts/runtime/session_state.gd, scripts/app/main.gd, scripts/ui/start_menu.gd

# Harvest & World Mutation — Design

## Purpose

PokeWilds is a sandbox: you reshape the world and use what it gives you. This
slice delivers the first half of that promise — a world-mutation layer and the
harvest loop (cut/dig/smash → materials) — on which the later building spec
will build. It also replaces the placeholder "global field-move unlock" model
with authentic per-tile clearing and party-capability checks.

## Decisions from brainstorming

- Scope: harvest-first. Mutation layer + save v3 + harvesting; building
  placement is a separate follow-up spec.
- Interaction: context action key (Z) as primary, party screen as secondary.
- Traversal: per-tile clearing only — the global unlock model dies.
- Harvested tiles are permanent (persisted), no regrowth.
- Mutation architecture: sparse override map (`Vector2i → override`) layered on
  the deterministic generator; the override dict is the save payload.

## Architecture (Section 1)

The base world stays a pure function of the seed. A runtime-owned
`world_overrides` dictionary — entries `{kind: "cleared"|"dug", by:
"cut"|"dig"|"smash", step: int}` — is applied in exactly one place, at the
`get_tile_logic` boundary: overrides move `walkable` to true, clear the prop,
clear the encounter flag for dug tiles, and stamp a `mutated` marker for
audits. Rendering, `is_tile_walkable`, encounters, and every audit read
post-override logic; there is no second source of truth. Accessors
`apply_overrides(dict)` and `overrides_for_save() -> Dictionary` keep session
code out of world internals; New Game empties the map.

Field-move capability flips from stored unlocks to party capability: a Pokemon
can perform a move when its species flag is `1`, or its type matches the move's
auto-ability type (GRASS→cut, GROUND→dig, ELECTRIC→power, ROCK→smash, final
WATER stage→surf, FIRE→flash, FIGHTING→build, FAIRY→charm, POISON→repel,
DARK→attack, PSYCHIC→teleport), unless its flag is `2` (force-unable).
`game_runtime.party_has_field_move_ability(move_id)` is the single check.
Traversal-only gates (water/surf) become passive party checks; harvestable
gates open only by being cleared.

## Harvesting rules (Section 2)

- CUT (GRASS-type or cut-flagged): targets tree/cactus/swamp-tree/snow-tree
  props. Tile becomes `cleared`. Yield: 1 log.
- DIG (GROUND-type or dig-flagged): targets walkable ground in PLAINS,
  GRASSLAND, FOREST, SAVANNA, SWAMP (1 dry_soil) and SAND (1 dry_sand) /
  DESERT (1 soft_sand). Tile becomes `dug`: walkable, tall grass and its
  encounter flag removed.
- SMASH (ROCK-type or smash-flagged): targets rock-cliff props. Tile becomes
  `cleared`. Yield: 1 hard_stone.

Out of scope for v1: headbutt, berry seeds, rare drops, quantities > 1,
cooldowns, dug-hole visuals, and all non-harvest field moves (build, flash,
charm, repel, attack, teleport, ride, fly, paint, power). Re-harvesting an
already-cleared or already-dug tile is a refusal with a message ("There is
nothing left here."), never a second yield.

## Interaction flow (Section 3)

One runtime `harvest_resolver` owns the interaction: given the faced tile it
finds the applicable action (CUT, then DIG, then SMASH), verifies capability,
applies the override, grants the yield, and returns the message ("The tree was
cut down! Got a log!"). Two triggers share it:

- Context-Z in the overworld: resolver on the faced tile; no action → today's
  no-op. Facing a blocked tile with no capable party member shows the tile's
  block reason with a hint ("A tall tree blocks the way. It could be CUT.").
- Party screen FIELD MOVE: invokes the resolver on the faced tile with the
  chosen mon enforcing its own capability ("Chikorita can't use that here.").

SURF has no resolver action; water is a passive party-capability gate. The
`field_move_used` trace payload becomes `{move_id, tile, yield}`.

## Persistence (Section 4)

Save schema v3 adds `world_overrides` (keys `"x,y"`) and `version: 3`, and
drops `unlocked_field_moves`. Migration: v1→v3 (existing backfills, empty
overrides), v2→v3 (keep bag/time/steps, drop the unlock key — uncut trees
simply remain), v3 native, corrupt/unknown → warning + fresh game. Defensive
cap of 10k override entries with a warning trace.

## Validation (Section 5)

- New `harvest_flow` scenario: refusal when the crafted party has no capable
  member, then cut/dig/smash via context-Z asserting trace, yields, cleared
  logic, and save/reload persistence; emits `harvest_flow_passed`.
- Reworked `field_move` scenario: clearing semantics with a save round-trip.
- `world_consistency_audit` extension: overridden tiles agree across
  logic/render/collision and appear in `overrides_for_save()`.
- nav_audit updated to party-capability gate semantics; soak invariants hold
  with bot harvesting enabled.
- v2→v3 migration probe (crafted save carrying `unlocked_field_moves`).

## Success criteria

- Full suite stays green including the new and reworked scenarios.
- A player can clear a grove, pocket the logs, reload, and find the grove
  still cleared — with every audit lane able to see that state.
- No path to walk through an unharvested tree or rock exists.
