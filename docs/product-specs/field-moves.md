Status: current
Last verified: 2026-07-25
Review cadence days: 21
Source paths: scripts/domain/field_moves.gd, scripts/runtime/night_system.gd, scripts/runtime/player_avatar.gd, scripts/domain/structures.gd, scripts/runtime/session_state.gd, scripts/app/field_action_router.gd, scripts/runtime/game_runtime.gd, scripts/runtime/build_runtime.gd, scripts/runtime/harvest_runtime.gd

# Field Moves (Traversal & Utility)

Phase 4 (feature-completion plan feature #7) gives runtime callers to the field moves that previously had capability rules but zero runtime effect, and completes the night design Phase 2 started. The port has **thirteen** field moves in total (the exec plan's "12" is an off-by-one): five are already live from Phases 1-3 — **Cut / Dig / Smash** (harvest, [harvest-and-mutation.md](harvest-and-mutation.md)), **Surf** (passive water gate, [bootstrap-and-overworld.md](bootstrap-and-overworld.md)), and **Build** (placement, [building-and-placement.md](building-and-placement.md)) — and this spec owns the eight that were rules-only: **Flash, Teleport (+ Way Stones), Ride, Fly, Attack, Charm, Repel, and Power**. `headbutt`/`paint`/`follow` appear in the source `wilds_data.asm` flag block but are NOT in the ported move set.

The capability MODEL is unchanged and lives in [harvest-and-mutation.md](harvest-and-mutation.md) (`scripts/domain/field_moves.gd`): a species flag of `1` always allows a move, `2` forbids it, otherwise the move's auto-ability type decides. This spec adds the CALLERS + traces + scenarios for the eight moves and the two new world objects they ride on (the **Way Stone** warp point and the movable **boulder** prop). Runtime orchestration is EXTRACTED into a NEW `scripts/runtime/field_move_runtime.gd` — `game_runtime.gd` is at its 320-line budget and is NOT extended (one same-line instantiation/`setup` beside `battle_runtime`/`build_runtime`, sharing the injected `_rng` for determinism). Player-facing entry stays in `field_action_router.gd` (`building_loop`-owned, has room) with same-line `main.gd` edits only (`main.gd` is 220/220).

## Supported behavior

### The all-moves party (playtest fixture)

The field-move and building playtests run with a single shared party that collectively knows ALL thirteen field moves. The minimum cover is **six species** (proven optimal by a bitmask set-cover over the encounter-eligible catalog using `field_moves.can_perform` semantics). The pinned fixture keeps the user-named trio (Rhyperior / Charizard / Machop) and fills the rest:

| Species | Types | Explicit flags | Moves covered |
| --- | --- | --- | --- |
| `RHYPERIOR` | GROUND/ROCK | surf=1, ride=1 | dig (GROUND auto), smash (ROCK auto), surf (flag), ride (flag) |
| `CHARIZARD` | FIRE/FLYING | fly=1 | flash (FIRE auto), fly (flag) |
| `MACHOP` | FIGHTING/FIGHTING | — | build (FIGHTING auto) |
| `CALYREX` | PSYCHIC/GRASS | — | cut (GRASS auto), teleport (PSYCHIC auto) |
| `DEDENNE` | ELECTRIC/FAIRY | — | charm (FAIRY auto), power (ELECTRIC auto) |
| `DRAPION` | POISON/DARK | — | attack (DARK auto), repel (POISON auto) |

`FIELD_MOVES_PARTY := ["RHYPERIOR","CHARIZARD","MACHOP","CALYREX","DEDENNE","DRAPION"]` lives in a single shared fixture, `scripts/runtime/field_moves_party.gd` (class `FieldMovesParty`, `PARTY_LEVEL := 50`), that every field-move/building scenario and the soak bot import — exactly one cover list. It is a CONSTANT + SWAP-IN helper, NOT a save fixture (a save fixture resets bag/clock/steps and never re-seeds the generator — the torn-world pitfall `harvest_flow`'s header documents): scenarios drive it through `smoke_scenario_runner.swap_party(runtime, FieldMovesParty.FIELD_MOVES_PARTY, level)` or `FieldMovesParty.swap_in(runtime)` (returning the prior party for `restore` on every exit), leaving the seeded generator + bag intact. An alternative DP-optimal six (also all encounter-eligible) is AMPHAROS/CAMERUPT/CARBINK/CRAWDAUNT/CROBAT/GALLADE; the pinned list above is authoritative.

**Precondition witness (anti-drift):** because the cover is computed from the raw `.asm` and approximates `species_file_parser.gd`, every scenario's FIRST act (after swap-in) asserts `FieldMovesParty.verify(runtime) == []` — all six species resolve in the live catalog, the party is six strong, and `runtime.party_has_field_move_ability(mv)` is true for ALL thirteen moves — failing loud (the problem list) if any is false. Catalog/AUTO_TYPES drift becomes a named red, never a vacuous pass on a silently-short party. CALYREX's catch_rate=3 only affects wild capture, not instantiation — the fixture instantiates, never wild-captures.

**Activation reality (documented):** the party-screen `FIELD MOVE` menu lists species-flag `1` moves ONLY (`party_screen._eligible_field_moves`). For this party that renders only **Fly** (Charizard), **Ride** + **Surf** (Rhyperior); the auto-typed moves (cut/dig/smash/flash/build/charm/repel/attack/teleport/power) never appear as menu entries. The scenarios therefore drive moves through (a) the overworld `Z` context seam (cut/dig/smash/build, and the new auto-typed moves the router now routes), (b) the new `field_move_runtime` seams, and/or (c) `smoke_context()["field_move"]`. The exec-plan exit criterion "the party-screen FIELD MOVE action is meaningful" holds for the flag-1 moves (fly/ride/surf here) — see [menu-and-save.md](menu-and-save.md).

### Flash (FIRE) — light, completing the Phase 2 night design

- The FAITHFUL effect is PASSIVE and already live from Phase 2: a Flash-capable (Fire-type) party member is a traveling light at `LIGHT_RADIUS = 4` — "the same range as a campfire" (`night_system.gd`; [camping-crafting-survival.md](camping-crafting-survival.md) § Night danger). The original is explicit that Flash "can't be selected like most field moves such as Cut" — its overworld effect IS the light.
- Phase 4 adds a field-move CALLER on `field_move_runtime` (so the move has a runtime entry point and a trace), a `flash_lit` trace, and a scenario proving a Flash-only party (no campfire/torch) keeps `night_system.has_light_at` true and suppresses the unlit-night ghost. The passive light is KEPT as the faithful mechanic; the active caller is a port convenience that must NOT diverge from "lights tiles around you, same range as a campfire" (the lit radius equals a campfire's: true at Manhattan 4, false at 5).

### Teleport (PSYCHIC) + Way Stones — registered warp points

- A **Way Stone** is a new placeable structure (`structures.gd` `IDS += "way_stone"`, with a cost table entry, sprite, and walkable flag) that REGISTERS a warp point when built/registered. The way-stone registry IS the set of placed `way_stone` entries themselves — they ride the existing `structures` save key (no separate `session_state` key), so a registered stone persists for free as a placement. Trace `waystone_registered {tile}`.
- **Teleport** warps the player to the LAST-REGISTERED Way Stone (`field_move_runtime.way_stone_tiles` is registration-step-ordered; player tile set to the registered tile, avatar resynced). Trace `teleport_used {from, tile}` (`tile` = the destination Way Stone).
- **Scope boundary:** this is INTRA-world warp only. The original gates world travel on "Teleport Beacons" you build and select; those **world-edge Teleport Beacons are Phase 7** (world chaining). The naming/scope split is deliberate and airtight: **Way Stones** = Phase-4 intra-world warp points; **Teleport Beacons** = Phase-7 world-edge chaining. You cannot Teleport between worlds in Phase 4.

### Ride (explicit flag) — faster overworld movement

- Mount a Ride-capable party member (explicit `ride = 1` flag — Rhyperior here) for FASTER overworld movement: a mount speed mode on `player_avatar.gd` beyond the existing 0.09s run step, plus a mount sprite. Trace `mount_summoned {species_id, mounted}` (`mounted` true on summon, false on dismount). Dismount restores the walk/run modes.
- **Scope boundary:** traversal SPEED only. The original's "ride up ledges" ledge-climbing is NOT scoped (no ledge terrain in the port).

### Fly (explicit flag) — aerial travel to VISITED Way Stones

- Fly (explicit `fly = 1` flag — Charizard here) flies the player to the LAST-REGISTERED (**VISITED**/registered) Way Stone, reusing the Way-Stone registry (`field_move_runtime.way_stone_tiles` is registration-step-ordered). Trace `fly_used {from, tile}`. Fly REFUSES an unvisited/unregistered stone (empty result / refusal), so "to visited way stones only" holds in both directions. (The original's way-stone SELECTION MENU is not built in this slice — the destination is the last-registered stone; a selection list is tracked in the tech-debt tracker.)
- **Scope boundary:** Fly-to-visited-Way-Stone only. The original's "Surf/Fly off a map edge travels worlds" — **edge-fly as the world-chaining trigger is Phase 7**, NOT built here.

### Attack (DARK) / Charm (FAIRY) — overworld-combat and pacify/recruit HOOKS

- These are the HOOKS Phase 6 (overworld Pokémon) consumes; the overworld-Pokémon ENTITIES they target do NOT exist yet. Phase 4 wires the field-move side so Phase 6 plugs in.
- **Attack** fires the overworld-combat hook + `overworld_attack {tile, target_species_id}` trace. With no entity present it REFUSES gracefully (no target, well-formed payload) rather than crashing.
- **Charm** fires the pacify/recruit hook + `charm_used {tile, target_species_id, level_gate_met}` trace. Faithful to the original: Charm stops timid Pokémon fleeing and "can prevent the attack altogether if the Pokemon using it is at a high enough level" — so the pacify is LEVEL-GATED (the hook records whether the level gate was met). Phase 6 owns the entity behavior; Phase 4 asserts the hook is reached + traced, never any overworld-mon state.

### Repel (POISON) — suppress encounters for N steps

- Activating Repel sets a session-state step counter (`session_state.repel_steps`, additive) that suppresses wild encounters for N steps, decrementing per step and expiring to normal encounters. Trace `repel_active {steps}`.
- **Fidelity gap (documented deviation):** the ORIGINAL Repel is a CRAFTED ITEM (campfire: 1 Charcoal + 1 Manure; Max Repel = Poison Barb + Repel) that "repels low level Pokemon for a while." The port scopes the FIELD-MOVE version: suppress ALL encounters for N steps (not low-level-only, not an item). This is a deliberate simplification, recorded here and in the tech-debt tracker; the crafted-item Repel stays out (it conflicts with this field-move model — see [camping-crafting-survival.md](camping-crafting-survival.md) § Phasing decisions).

### Power (ELECTRIC) — strength tasks (movable boulders)

- The smallest scope: Power moves a **movable boulder prop** (a NEW prop, id `boulder` in `structures.gd`, DISTINCT from Smash's destructible `rock_small1.png` — Smash destroys rock for hard_stone; Power shoves a boulder one tile). The boulder is non-walkable ("A boulder blocks the way."), carries NO build cost (a natural prop, not a placed structure), and rides the **placements map** (the `structures` save key, like the Way Stone) so a pushed boulder survives save/reload. Trace on a successful shove (a `field_move_used`-style power payload). Power REFUSES with no boulder faced.
- **Scope boundary:** movable-boulder props only; tying boulders to a landmark gate is Phase 7 (landmarks), if useful.

### Capability decision: fly/ride stay explicit-flag-only

The exec plan notes "`AUTO_TYPES` gains fly/ride mappings." This spec resolves that as a fidelity DECISION: **fly and ride stay EXPLICIT-FLAG-ONLY.** `AUTO_TYPES` gains `fly` and `ride` KEYS, but their auto-type is the EMPTY string — so `can_perform` falls through to the species flag exactly as before (an empty auto-type returns false, never a type match). The real db models both as explicit flags only (verified rarity across the 990 parsed species: fly = 30, ride = 32; neither correlates with a single type); a `fly → FLYING` auto-type would broaden fly from 30 species to ALL ~100 Flying-types (a fidelity divergence), and ride has no natural type. The empty-key form satisfies the exec plan's wording (the keys exist) while preserving the faithful flag-gated behavior. The all-moves party is robust either way (Charizard `fly = 1` and Rhyperior `ride = 1` are explicit flags). If a future decision gives fly/ride a real auto-type, the precondition witness above keeps the fixture honest.

## Persistence

DECISION: every Phase-4 state is **ADDITIVE on save schema v4 — no version bump.** `SAVE_VERSION` stays 4; the v5 bump is RESERVED for Phase 7's `world_id` world-chaining schema. (A bump would be needed only for a non-additive change; all Phase-4 keys are additive, matching the v3/v4 additive pattern.)

- **Way Stone structure** rides the existing `structures` save key (a placement entry like any other — `world_overrides.is_valid_placement` checks only kind + structure_id, so it round-trips with zero validator changes). The way-stone REGISTRY (which stones are registered/visited) IS the placed `way_stone` entries themselves on that same `structures` save key — NOT a separate `session_state` key (a stone persists for free as a placement; `field_move_runtime.way_stone_tiles` reads them back in registration-step order).
- **Repel counter** persists as an additive `session_state.repel_steps` key (absent = 0). It decrements per step; the `verify_save_roundtrip` field-by-field assertion is extended to cover it additively.
- **Boulder prop** rides the **placements map** (the `structures` save key — `structures.gd` `BOULDER_ID`, no build cost) so a pushed boulder survives save/reload; a shove moves the placement entry one tile (original tile freed, destination carries the boulder).
- **Ride mount state** is RUNTIME-ONLY (not saved) — dismount on load; the mount is a session movement mode, like the run key.
- Migration is additive: v4 saves from before Phase 4 simply lack the new keys and backfill to defaults (repel 0, empty way-stone registry). No key is renamed or dropped.

## Scope boundary (Phase 6 / Phase 7 deferrals)

- **Attack / Charm are HOOKS only.** The overworld-Pokémon ENTITIES (spawn/roam/flee/aggro, recruit, nests, Alphas) land in Phase 6; Phase 4 wires the field-move side (the hook callable + trace) so Phase 6 plugs in. No overworld-mon state is asserted in Phase 4.
- **Fly is to-VISITED-Way-Stone only.** Edge-fly (Surf/Fly off a map edge generates an adjacent world) is the Phase 7 world-chaining trigger — NOT built here.
- **Teleport is intra-world only.** World-edge **Teleport Beacons** for world chaining are Phase 7; the Way-Stone (intra-world warp) / Beacon (edge warp) naming split is kept clean.
- **Ride is speed only** (no ledge-climbing); **Power is movable boulders only** (landmark-gate use is Phase 7).
- **Repel** is the field-move simplification (all encounters, N steps) — the faithful crafted-item, low-level-only Repel stays out.
- **Flash** keeps its faithful passive light; the active caller is a convenience that never diverges from "same range as a campfire."

## Smoke validation

Three new gate scenarios + a bot extension, all driven by the `FIELD_MOVES_PARTY` fixture (swapped in, restored on every exit), seed-pinned (`seed_for_smoke`), encounters zeroed in crafted state, dispatcher save-guarded, with symmetric `<name>_passed` + `<name>_failed` (miss-002 honesty). They deliver the exec plan's `field_moves_extended` coverage.

- **`field_moves_flow`** (`scripts/app/field_moves_flow_scenario.gd`, per-move checks split into `scripts/app/field_moves_checks.gd` for the app line budget): swaps `FIELD_MOVES_PARTY`, FIRST asserts the precondition witness (`party_has_field_move_ability` for all 13 moves — catalog drift fails loud), then runs eight move checks into one `field_moves_passed {flash_ok, teleport_ok, ride_ok, fly_ok, repel_ok, power_ok, charm_ok, attack_ok, seed}`:
  - **FLASH** — set the clock to unlit night on a crafted dark world (placements cleared); WITNESS the dark first by swapping to a NON-Flash control party (MACHOP — dark + ghost-prone) and contrasting the Flash party (lit + ghost-free). The proof keys on that PARTY CONTRAST + the `flash_lit` trace + `night_system.active_flash_lit()` — there is NO positional light delta, because the passive Fire-type party light is GLOBAL (true on every tile), so a flash mon present leaves no dark tile to delta against. RADIUS contract ("true at Manhattan 4, false at 5"): under the non-Flash party (passive read off, no placements) the check arms the active seam DIRECTLY and probes the campfire-equal edge — lit at the player's tile and at Manhattan 4 (axis + diagonal), dark at Manhattan 5 — the only window where the active branch decides anything, so its radius is proven, not assumed.
  - **TELEPORT ↔ WAY STONE** — build/register a Way Stone at a crafted tile (`waystone_registered {tile}`); teleport the player FAR away; invoke the teleport seam; assert the player tile == the registered stone (`teleport_used`); `save_and_reload` and assert the stone + registration survive.
  - **RIDE** — mount a Ride-capable mon; assert the avatar's speed mode changed (the new mount mode / mount sprite) + `mount_summoned`; dismount restores walk. Read avatar STATE, never wall-clock.
  - **FLY** — from a distant tile invoke the fly seam; assert the warp reaches a VISITED Way Stone (`fly_used`) AND refuses an unvisited/unregistered stone, proving "visited only" both ways.
  - **REPEL** — CONTROL: repel OFF, N `generate_wild_encounter` draws on the shared seeded `_rng` yield ≥1 mon (the tile/stream produces encounters). Re-seed to the SAME seed, activate Repel (`repel_active {steps}`), the SAME N draws yield EXACTLY 0 (STRUCTURAL — Repel short-circuits before consuming encounter rng). Step the counter down N times; the (N+1)th draw can encounter again (suppression expires). The hook is `runtime.generate_wild_encounter`/`_pick_encounter_species` (shared seeded `_rng`), NOT the avatar's private unseeded rng.
  - **POWER** — face a boulder; assert it moved one tile (original tile now prop-less/walkable, destination carries the boulder) + a power trace; assert Power REFUSES with no boulder faced; the boulder rides the placements map (`structures` save key) so it survives `save_and_reload`.
  - **CHARM / ATTACK** — invoke each seam; assert the hook is reached + the trace payload is well-formed (`charm_used` / `overworld_attack`), and that the move REFUSES gracefully with no target (no crash). NO overworld-mon state is asserted (Phase 6 entities absent).
- **`build_house_flow`** (`scripts/app/build_house_flow_scenario.gd`) — the building playtest, driven by `FIELD_MOVES_PARTY`: (a) HARVEST earns materials through the REAL resolver (`runtime.harvest_tile` — cut trees for log, dig plains for dry_soil, smash rock for hard_stone; `field_move_used` + exact bag gains, the harvest_flow pattern — logs EARNED not granted); (b) BUILD stamps a fixed HOUSE_PATTERN (roof cap + wall ring + ONE door — the door the only walkable tile in the ring ⇒ an enclosed interior) via `build_runtime.try_place`, asserting per-piece `structure_placed` + `materials_consumed` with exact `materials_for(id, biome)` cost drops; (c) OCCUPANCY — a wall tile is non-walkable + a step is rejected, the door tile is walkable + a step passes; (d) DEMOLISH + REFUND — demolish every placed piece (`build_runtime.try_demolish`), asserting `structure_demolished` + `materials_refunded` with the EXACT full `cost_for` returned and the tile reverting to open ground with its clear fact intact; bag after == bag before build. Emits `build_house_passed {harvest_ok, placed, door_walkable, refund_ok, save_ok}` + symmetric `_failed`.
- **`playtest_field_soak`** (`playtest_` prefix ⇒ self-guarded by `PlaytestBot.backup_save`/`restore_save` like journey/soak) — a seeded soak that EXERCISES field moves under `FIELD_MOVES_PARTY`. `playtest_bot.gd` gains `try_random_field_move(...)` (gated on `party_has_field_move_ability`, picks a legal field-move action off the seeded rng, drives the runtime seam, asserts the postcondition inline — repel sets/decrements its counter, flash lights the tile, teleport/fly return to the registered stone, ride toggles the speed mode — and tallies stats; a no-capable-move roll degrades to a walk so it never soft-locks). `playtest_scenarios.gd` grows `run_field_soak(ctx)` mirroring `run_soak` (backup → swap `FIELD_MOVES_PARTY` + restore on every exit → `seed_for_smoke(FIELD_SOAK_SEED)` → bounded loop interleaving the field-move band with the existing walk/battle/menu/save bands → invariants + `verify_save_roundtrip` + spatial_violations == 0 → restore → `playtest_field_soak_passed {seed, iterations, field_moves_used, ...}`). A SEPARATE scenario (not editing the green `run_soak`) avoids perturbing `playtest_soak`'s fresh-game starter-party invariants.
- **Registration:** `field_moves_flow` + `build_house_flow` are qa-dispatched (`qa_scenarios.gd` SCENARIOS); `playtest_field_soak` routes through `smoke_scenarios`' `playtest_` branch like journey/soak (NOT qa_scenarios). All three are added to `run_playtests.py` PLAYTEST_SCENARIOS + `SCENARIO_REQUIREMENTS` (pinning the DOMAIN events, not just the pass marker) and `godot_dap_smoketest.py`. Baselines (windowed): a mounted overworld shot.
