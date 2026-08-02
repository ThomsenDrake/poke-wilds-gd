Status: current
Last verified: 2026-08-02
Review cadence days: 90
Source paths: scripts/domain/biome_field.gd, scripts/domain/world_gen_audit.gd, scripts/domain/world_gen_cohesion.gd, scripts/domain/world_gen_spawns.gd, scripts/domain/world_gen_dungeons.gd, scripts/runtime/world_gen_audit_runner.gd, scripts/app/world_gen_audit_scenario.gd

# World-Generation Audit — Findings

The comprehensive world-gen audit (`world_gen_audit` scenario) mechanically measures the
procedural world across a fixed 9-seed list (`1337, 1, 42, 20260101, 31337, 999983,
2026072907, 2026072913, 2026073001`), consuming no rng (a pure function of code + catalog +
seeds). It scans a Manhattan disc of radius 110 (~24,421 tiles/seed) for cohesion metrics, a
radius-400 stride-4 window (~20k samples) for the biome-distribution contract, and the
playable disc (radius 96) for dungeon sites. **Enforcing-tier** invariants (green today, gate
on regression) are separated from **advisory-tier** findings (future-fix gaps, warning-tier,
never gate). This document is the curated companion to the per-run
`res://.godot-smoke/world-gen-audit-findings.json`.

Numbers below are from the 2026-08-02 run — the FIRST run under the infinite-world slice-2
climate field (`biome_field.gd`: temperature/moisture/volcanism channels; WATER/SAND/ROCK
stay elevation-driven). The radial ring model (biome candidates at Manhattan 10/28/60) is
RETIRED, and with it the ring-admission, ring-seam, and landmark-in-extent checks. Counts
(hostile adjacency, specks, intrusions) are the WORST value across the 9 seeds;
distributions/values are from a representative seed — re-run the scenario for the current
numbers.

## Enforcing invariants (all GREEN — the gate)

| Invariant | Result |
| --- | --- |
| Disc determinism density (two same-seed generators agree tile-for-tile) | 0 mismatches |
| Biome distribution — ten common biomes present per 400-radius seed window | 0 missing |
| Biome distribution — LAVA present cross-seed (`LAVA_WINDOWS_MIN := 6`) | 8 of 9 windows |
| Pool legendary/EGG no-leak (11 biomes × DAY/NIGHT) | 0 leaks |
| Spawn reachability (flood from spawn) | ≥ 12 tiles (5000-cap saturated) |

The LAVA cross-seed shape is the honest one for a rare clustered joint tail (~0.02-0.9% of
tiles per seed, measured across the audit's 9 windows): a single cold-climate window
legitimately lacks it, so per-seed absence is NOT a failure — presence in MOST windows is the contract.

## Goal 1 — Cohesion & blending (ADVISORY — no blending exists today)

Biomes are **hard-edged step-function regions**: `BiomeField.biome_from` consults only the
tile's own position (no neighbor lookup, no transition tiles), `biome_defs.gd` has no
adjacency rules, and the renderer composites each tile independently (no
autotiling/feathering). Measured under the climate field:

- **Hostile adjacencies: 0 on all 9 seeds** (declared hostile pairs: SNOW↔LAVA, LAVA↔WATER,
  DESERT↔SNOW, LAVA↔GRASSLAND, SNOW↔SAVANNA) — the climate field's correlated temperature
  axis eliminates the radial model's hard band crossings (measured 6/seed before). Most
  common adjacent pairs: SAND|WATER (572), DESERT|SAVANNA (255), DESERT|SAND (233),
  SAND|SNOW (200), PLAINS|SNOW (159).
- **Fragmentation:** ~75 same-biome regions, **24 specks** (< 8 tiles) per seed —
  salt-and-pepper at climate-region borders.
- **Distribution (representative seed, 110-disc):** SAND 4440, DESERT 3654, SNOW 3131,
  WATER 2812, PLAINS 2316, SWAMP 2042, GRASSLAND 1838, SAVANNA 1597, FOREST 1551, ROCK 1040,
  LAVA 0 (present in the seed's 400-window — the disc reads as one climate region).
- **RESOLVED — the missing-moisture-channel drift:** the previous finding ("DESERT/SWAMP/ROCK
  compete for bands of the SAME scalar") is fixed by construction: temperature + moisture +
  volcanism are independent channels, so climate regions form cohesively (DESERT hot-dry,
  SWAMP wet, SAVANNA hot-middling, SNOW cold).
- **Visual edge-blending:** recorded as a named advisory; its pixel probe rides the later
  blending fix's windowed verification (nothing to measure before blending exists).

**Fix (still open):** transition bands between contrasting biomes + visual edge feathering.
Promotes `hostile_adjacency`/border-sharpness to enforcing + adds a windowed edge-delta probe.

## Goal 2 — Wild spawns vs stats (ADVISORY — stats play no role today)

Species are chosen by type/biome + source spawn-lines; encounter level is purely distance
(`encounter_selection.level_from_distance`, `OverworldMons.level_for` — orthogonal to biome
assignment). With ring tiers retired, "depth" no longer exists for biomes — ANY biome can
occur near origin, so the measurements are per-biome:

- **BST by biome (DAY pools, battle-viable):** medians 400-465 across land biomes, but every
  biome's tail reaches high values (max 600-680; e.g. DESERT p90 530, FOREST max 680) — no
  stats↔difficulty gating anywhere.
- **Level-band strength:** dozens of high-BST (≥540) species (ARCANINE, DRAGONITE, TYRANITAR,
  MEW, ARCEUS, ...) sit in land pools and are reachable at level 2-5 wherever their biome
  touches the inner region — encounter level ignores strength today. (ARCEUS's pool presence
  also explains the entity soak's honest overworld-sprite placeholder warning, re-pinned with
  the slice.)
- **Type coherence holds** (enforcing): no pool leaks a legendary/EGG; no biome currently
  falls back to the full catalog (`biomes_with_fallback = 0`), so the fallback-disjoint leak
  check is vacuously clean today.

**Fix (still open):** stats-aware spawn gating (BST vs distance or a climate difficulty
gradient) + level-vs-strength shaping. Promotes `level_band_strength` toward enforcing.

## Goal 3 — Dungeon placement sites (ADVISORY — placement slice pending)

- **Site availability (RUINS_SIZE footprint fits, radius-96 window):** every land biome hosts
  sites (PLAINS 450, SWAMP 419, GRASSLAND 426, FOREST 330, DESERT 699, SNOW 390, SAVANNA 154,
  ROCK 152) except LAVA on 7 of 9 seeds — LAVA pockets are small (a handful to a few hundred
  tiles), so a 15×11 footprint rarely fits. On an infinite plane larger pockets exist farther
  out; the future dungeon slice should either accept small-pocket sites (smaller LAVA
  footprints) or bias site selection toward the pocket core.
- **Legendary anchors:** all seven resolve on most seeds (worst seed: 4 NO_ANCHOR — rare
  LAVA pockets in that reach box). The guided min-margin scan + sibling-exclusion chain keeps
  anchors distinct and inside the 300-probe budget, ring ≥ 60 (the progression floor).
- **Spawn-disc intrusion:** 1 landmark footprint reaches within Manhattan 24 of origin on one
  seed (the gen-time exclusion gate is unimplemented — advisory, spec §19(c)).
- **Landmark reachability:** not_verified for all three (the §19(c) gen-time gate is
  unimplemented).

**Fix (still open):** the dungeon placement slice (regi areas, towers, pre-generated
structures) + the §19(c) reachability gate + the LAVA-pocket site policy above.
