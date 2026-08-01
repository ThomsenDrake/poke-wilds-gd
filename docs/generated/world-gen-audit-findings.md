Status: current
Last verified: 2026-08-01
Review cadence days: 90
Source paths: scripts/domain/world_gen_audit.gd, scripts/domain/world_gen_cohesion.gd, scripts/domain/world_gen_spawns.gd, scripts/domain/world_gen_dungeons.gd, scripts/runtime/world_gen_audit_runner.gd, scripts/app/world_gen_audit_scenario.gd

# World-Generation Audit — Findings

The comprehensive world-gen audit (`world_gen_audit` scenario) mechanically measures the
procedural world across a fixed 9-seed list (`1337, 1, 42, 20260101, 31337, 999983,
2026072907, 2026072913, 2026073001`), consuming no rng (a pure function of code + catalog +
seeds). It scans a Manhattan disc of radius 110 (~24,421 tiles/seed) plus the playable disc
(radius 96) for dungeon sites. **Enforcing-tier** invariants (green today, gate on
regression) are separated from **advisory-tier** findings (future-fix gaps, warning-tier,
never gate). This document is the curated companion to the per-run
`res://.godot-smoke/world-gen-audit-findings.json`.

Numbers below are from the 2026-08-01 run. Counts (hostile adjacency, specks, intrusions) are
the WORST value across the 9 seeds; distributions/values are from a representative seed —
re-run the scenario for the current numbers.

## Enforcing invariants (all GREEN — the gate)

| Invariant | Result |
| --- | --- |
| Disc determinism density (two same-seed generators agree tile-for-tile) | 0 mismatches |
| Ring admission (inner/mid/outer biome gates) | 0 violations |
| Pool legendary/EGG no-leak (11 biomes × DAY/NIGHT) | 0 leaks |
| Landmark footprints inside the playable extent (ring + half-diagonal < 96) | 0 out of extent |
| Spawn reachability (flood from spawn) | ≥ 12 tiles (5000-cap saturated) |

## Goal 1 — Cohesion & blending (ADVISORY — no blending exists today)

Biomes are **hard-edged step-function regions**: `_pick_biome` consults only the tile's own
position (no neighbor lookup, no transition tiles), `biome_defs.gd` has no adjacency rules,
and the renderer composites each tile independently (no autotiling/feathering). Measured:

- **Hostile adjacencies:** up to **6** hard-hostile biome edges per seed (declared hostile
  pairs: SNOW↔LAVA, LAVA↔WATER, DESERT↔SNOW, LAVA↔GRASSLAND, SNOW↔SAVANNA). Most common
  adjacent pairs: SAND|WATER (572), DESERT|SWAMP (365), FOREST|GRASSLAND (229).
- **Diamond ring seams:** radial-vs-tangential biome churn spikes at the admission rings
  (ring 10: **0.363**, ring 28: 0.284, ring 60: 0.274 vs control rings) — the geometric
  candidate-list re-quantization produces systematic biome jumps along the Manhattan diamonds
  at rings 10/28/60, independent of terrain shape.
- **Fragmentation:** ~61 same-biome regions, **26 specks** (< 8 tiles) — salt-and-pepper
  blobs from the single biome-noise scalar.
- **Missing moisture channel (spec drift):** `bootstrap-and-overworld.md:22` claims a
  "seeded elevation, **moisture**, and biome noise field," but the code has only THREE
  channels (elevation, tall-grass, biome) — no moisture/temperature. DESERT/SWAMP/ROCK all
  compete for bands of the SAME scalar, tending toward parallel striping rather than cohesive
  climate regions.
- **Visual edge-blending:** recorded as a named advisory; its pixel probe rides the later
  blending fix's windowed verification (nothing to measure before blending exists).

**Fix:** transition bands between contrasting biomes + ban hostile adjacencies + a
moisture/temperature channel to separate climate biomes + visual edge feathering. Promotes
`hostile_adjacency`/`ring_seam` to enforcing + adds a windowed edge-delta probe.

## Goal 2 — Wild spawns vs stats (ADVISORY — stats play no role today)

Species are chosen by type/biome + source spawn-lines; encounter level is purely distance
(`clampi(2 + distance/24, 2, 80)` + jitter). **Base-stat-total was computed nowhere in the
codebase before this audit** (`world_gen_spawns.bst_of` is the first). Measured over the
954-species catalog (battle-viable BST range **180–720**):

- **BST↔depth is flat:** per-depth-tier pool medians barely rise (tier 0: 420, tier 1: 405,
  tier 2: 455, tier 3: 460). **6 high-BST (≥540) mons sit in tier-0 (ring < 10) pools**:
  ARCEUS, BLISSEY, CELEBI, SLAKING, SNORLAX, VOLCARONA.
- **Level ignores strength:** **17 high-BST mons in tier-0/1 pools are reachable at level
  2–5** (ring-0 band), incl. ARCEUS, DRAGONITE, GARCHOMP, GYARADOS, SNORLAX, the legendary
  birds, URSHIFU, VOLCARONA.
- **Type coherence holds** (enforcing): no pool leaks a legendary/EGG; no biome currently
  falls back to the full catalog (`biomes_with_fallback = 0`), so the fallback-disjoint leak
  check is vacuously clean today.

**Fix:** gate high-BST mons to deep/high-ring biomes, keep near-origin biomes to low-BST
first-forms, and make encounter level track species strength (a BST-influenced level floor).
Promotes `fallback_disjoint` to enforcing + pins the BST thresholds this audit calibrates.

## Goal 3 — Dungeon placement sites (ADVISORY — gaps for future dungeons)

Landmarks use an elevation-only fit test (no biome/reachability requirement); legendaries
need an exact-biome anchor. Measured footprint-site availability per biome (15×11 footprint,
playable disc, stride 2): SWAMP 823, DESERT 702, FOREST 500, GRASSLAND 497, SAVANNA 283,
ROCK 204, PLAINS 14 — and **SNOW 0, LAVA 0**. (ROCK is a conservative LOWER BOUND: the public
tile-logic seam cannot distinguish an elevation cliff from a ROCK-biome rock prop, so
`is_land` reads both as non-land while the real elevation-only anchor rule counts rock props
as land — ~12% under-count on measured seeds; the LAVA/SNOW zeros are unaffected.)

- **LAVA site gap (headline):** LAVA **never generates on origin** (the biome-noise never
  reaches the LAVA quantization bin, region ≥ 8/9 ≈ 0.889), so **zero LAVA-dungeon sites
  exist** — any LAVA-affinity Regi area / dungeon has nowhere to spawn. (SNOW is also absent
  within the radius-96 disc on some seeds — its first ring can be ~160.)
- **Legendary anchor budget:** the bounded search walks rings 60–134; on seed 1337 **all
  seven** legendaries resolve `NO_ANCHOR` (even SNOW's three — its first ring exceeds 134
  there). Anchors resolving at ring ≥ 96 are unreachable by construction (the disc edge is
  96; none measured out-of-extent this run).
- **Spawn-disc intrusion:** on seeds 42 and 2026072913 a ring-34 landmark footprint reaches
  manhattan ≤ 24 of origin (the footprint's inner edge lands inside the spawn disc). The
  gen-time spawn-disc exclusion is NOT guaranteed by world gen.
- **Reachability unverified:** spec `world-depth.md` §19(c) claims footprints are
  reachability-checked at gen time, but that gate is **unimplemented** — all three landmarks
  report `not_verified`.

**Fix:** make LAVA generate in deep rings (re-pins `legendary_spawn_checks.gd`
`EXPECTED_LAVA_ABSENT` in lockstep), widen/raise the legendary anchor budget, add a gen-time
spawn-disc exclusion + footprint-reachability gate (implements §19(c)). Promotes the
LAVA-site + reachability checks to enforcing (the audit advisories are that re-pin's
regression net).

## Fix-slice punch-list (the advisory_findings)

1. `cohesion`: hostile_adjacency_count, ring_seam, speck_count, extreme_reach (SNOW/LAVA).
2. `spawns`: bst_depth, level_band_strength, fallback_disjoint.
3. `dungeons`: lava_site_gap, site_availability (SNOW/LAVA = 0), legendary_no_anchor,
   legendary_anchors_out_of_extent, spawn_disc_intrusion, landmark_reachability.

Each fix slice promotes its checks from advisory to enforcing as it lands; the enforcing
invariants above stay gated throughout.
