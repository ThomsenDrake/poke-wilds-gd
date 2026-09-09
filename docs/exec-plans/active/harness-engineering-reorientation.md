Status: active
Last verified: 2026-09-07
Review cadence days: 14
Source paths: README.md, AGENTS.md, ARCHITECTURE.md, scripts, scenes, tools

# Harness-Engineering Reorientation

Source review (2026-09-07): the layer layout, registry, trace hooks, and mechanical checks remain present. The world now uses the climate field described in `docs/product-specs/infinite-world.md`; the earlier radial progression is retired. Runtime revalidation is pending the full `python3 tools/verify_all.py` gate; this plan remains active.

## Goal

Keep the Godot port game-focused while making the repository progressively easier for agents to navigate, validate, and maintain.

## Delivered in this plan

- Root navigation docs and a `docs/` system of record.
- Fixed `app/runtime/domain/data/ui/core` code layout.
- Structured trace events and DAP smoke scenarios.
- Mechanical repo, architecture, change, and quality checks.
- Weekly legibility-garden automation and debt reporting.

## Follow-up work

- Tighten runtime warning coverage where behavior still falls back silently.

## Progress this cycle

- World generation rewritten around coherent progressive biomes with data-driven traversal rules. New `scripts/domain/biome_defs.gd` carries biome textures, encounter flags, walkability, block reasons, and `requires_field_move` keys so the field-moves slice can unlock traversal later. `world_view.gd` exposes biome/traversal accessors and emits a `biome_entered` trace.
- World generation split into pure tile logic (`get_tile_logic`) and texture loading (`get_tile`) so navigability probes run without GPU access. `find_walkable_spawn` places new games on a walkable, neighbor-rich tile; `reachable_walkable_count` and `validate_invariants` prove the spawn is not walled off and the world is deterministic with the current elevation-band and climate-field invariants.
- Biome-specific encounters added via `scripts/domain/biome_encounters.gd`, filtering the species catalog by Pokemon type per biome. `world_view.is_tile_walkable` checks party Surf capability for water; Cut and Smash obstacles become passable only after clearing. Smoke scenario orchestration extracted into `scripts/app/smoke_scenarios.gd` with `biome_probe` and `biome_traverse` scenarios.
