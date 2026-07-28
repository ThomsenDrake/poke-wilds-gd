Status: current
Last verified: 2026-07-26
Review cadence days: 21
Source paths: scripts/domain/world_overrides.gd, scripts/domain/field_moves.gd, scripts/runtime/harvest_resolver.gd, scripts/runtime/harvest_runtime.gd, scripts/runtime/game_runtime.gd, scripts/app/harvest_flow_scenario.gd

# Harvest And Mutation

## Supported behavior

- The player can harvest the environment with field moves: `CUT` on tree, cactus, swamp-tree, and snow-tree props yields a log; `DIG` on walkable ground yields dry soil (plains/forest/savanna/swamp), dry sand (beach), or soft sand (desert); `SMASH` on rock cliffs yields a hard stone.
- **Dig bonus pool (Phase 5 stone acquisition; tech-debt item 11 RESOLVED).** A successful `DIG` yields its base material above UNCHANGED, then rolls a parallel bonus find (`harvest_resolver.bonus_for`, emitted as `dig_item_found {tile [x,y], item_id, biome}` with source `GameRuntime` alongside the unchanged `field_move_used`). The draw is a PURE step-counter function (`harvest_resolver._dig_draw`, an integer SplitMix over `total_steps` + tile) — NO shared `_rng` is consumed (the night_system determinism guarantee holds; `harvest_runtime.setup`'s signature is unchanged), gated by `DIG_BONUS_RARITY := 8`. Pools per biome (`harvest_resolver.DIG_BONUS_POOLS`):
  - **FAITHFUL — `SAND` (the beach):** `{big_pearl, water_stone, clear_glass, revive}` — the `fresh-beach.md` "## Dig Items" set in the exact wiki order/membership. This is the ONLY stone source the scrapes document; it is NOT a divergence.
  - **DIVERGENCE (port addition, flagged per-key in code + here — the scrapes cite NO non-Beach stone source):** `GRASSLAND [leaf_stone]`, `FOREST [leaf_stone, moon_stone]`, `SAVANNA [fire_stone, thunderstone]` (thunderstone underscore-free, `item.properties:83`), `DESERT [sun_stone]`, `SWAMP [dusk_stone]`.
  - **The rate is invented** even for the faithful Beach pool (`DIG_BONUS_RARITY := 8`): the wiki documents pool membership, no rate — water_stone lands on ~1/32 Beach digs, single-stone biomes on ~1/8. One tunable const.
  - **`PLAINS` is deliberately ABSENT** (documented dry_soil-only — keeps the `harvest_flow` PLAINS digs byte-identical, the regression guard). **`ice_stone` + `dawn_stone` are UNASSIGNED by design** — SNOW is not a diggable biome, so both stay scenario-grant-only (the item-11 residual; never papered over with a bad thematic fit).
  - `stone_pool_contract_clean()` audits every `DIG_BONUS_POOLS` stone against `stone_evolution_runtime.STONE_ITEM_IDS` (preloaded for the CONST ONLY, same layer, never instantiated — the single-source mandate); it fails on `hard_stone` (an unrelated building material), a misspelled `thunder_stone`, `log` (extending the `material_drops.gd` build-loop WITNESS INVARIANT — log→Cut / hard_stone→Smash must never be grantable, or a permitted wall-ring seal becomes a permanent self-trap — over this third item-granting table), or any stone outside the set. The Steel-type shiny_stone cadence drop is the OTHER half of stone acquisition and lives in [breeding-shinies-drops-fishing.md](breeding-shinies-drops-fishing.md) § Evolution stones (it reuses habitat's `item_dropped`, never the dig path).
- Pressing `Z` in the overworld resolves the action for the faced tile when any party member is capable; the party screen's `FIELD MOVE` action resolves it with the chosen party member ("X can't use that here." on failure).
- Capability is party-based: a species flag of 1 always allows the move, a flag of 2 forbids it, and otherwise the move's auto-ability type decides (GRASS→cut, GROUND→dig, ROCK→smash, and so on). Surf additionally requires a Water type at its final evolution stage.
- Harvested tiles change permanently: cut and smashed tiles are cleared (prop removed, walkable), dug tiles lose tall grass and their encounter flag. Re-harvesting a harvested tile is refused.
- Blocked tiles report a hint with their reason ("A tall tree blocks the way. It could be CUT.").
- Surf is a passive gate: water is walkable while a surf-capable Pokemon is in the party. There are no stored unlocks; the old global-unlock model is gone.

## Traversal & utility moves

Cut/Dig/Smash (above) and Build ([building-and-placement.md](building-and-placement.md)) are the harvest/placement field moves. The REMAINING eight field moves — Flash, Teleport (+ Way Stones), Ride, Fly, Attack, Charm, Repel, and Power — gained their runtime callers in Phase 4 and live in their own spec: [field-moves.md](field-moves.md). The capability model they all share (`field_moves.gd`: species flag 1 able / 2 unable, else auto-type; Surf = final-stage Water) is defined above and unchanged; `field-moves.md` records the fly/ride explicit-flag-only decision and the Phase 6/7 scope boundary (Attack/Charm hooks, Fly-to-visited-only, Teleport NOT world-edges).

## Persistence

- Overrides persist in save schema v3 (`world_overrides` keyed `"x,y"`, up to 10k entries) and survive save/load and world rebuilds. v1/v2 saves migrate; the legacy `unlocked_field_moves` key is dropped.

## Smoke validation

- `harvest_flow` proves refusal without a capable party member, then cut/dig/smash with yields and trace payloads, cleared logic, and save/reload persistence. Its digs are PLAINS (deliberately pool-less), so they stay the byte-identical regression guard for the base yield. It drives a SEEDED fresh game (`seed_for_smoke(SEED)` before `new_game`, the playtest `_fresh_game` idiom), not the boot wall-clock world: the smash target is an elevation cliff, and spawn sits in a flat basin, so the nearest cliff on the boot world is heavy-tailed in distance and a fixed-radius scan would flake — the fresh game guarantees cut/dig/smash within `SCAN_RADIUS` of spawn on every run.
- The dig BONUS pool is witnessed by `field_moves_flow`'s dig group (`scripts/app/field_moves_dig_checks.gd`, [field-moves.md](field-moves.md)): the `stone_pool_contract_clean` witness, a Beach SAND water_stone hunt predicted via `resolver.bonus_for` at `session.total_steps` (faithful pool — no rate assert on a single tile), the first-found divergent biome's pool membership pinned to the SHIPPED `DIG_BONUS_POOLS` table (a flagged port divergence, never the wiki), and a PLAINS negative control (no `dig_item_found`, all ten stone bags unchanged, dry_soil +1 only). `dig_acquisition_ok` rides `field_moves_passed`.
- `field_move` drives the resolver on a cut tile and proves blocked→cleared with a save round-trip.
- `world_consistency_audit` checks overridden tiles agree across logic, render, and collision, and appear in `overrides_for_save()`.
