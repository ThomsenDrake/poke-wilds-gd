Status: active
Last verified: 2026-07-21
Review cadence days: 14
Source paths: docs/product-specs, docs/registry/subsystems.toml, docs/QUALITY_SCORE.md, docs/RELIABILITY.md, scripts, scenes, tools

# PokeWilds Feature Completion

## Goal

Bring the Godot port to **single-player feature parity with the original PokeWilds** (SheerSt/libGDX), as verified by the July 2026 feature audit (22 features: 4 done, 7 partial, 11 absent), while preserving this repo's defining property: every behavior is spec'd, registered, traced, and covered by the local playtest suite.

The port has nailed presentation, data, and combat. What remains is the survival-crafting sandbox loop — placement, building, crafting, camping, breeding, habitat drops, overworld Pokémon, landmarks — plus the battle-system edges and the defect backlog. This plan sequences that work into nine phases plus one continuous local-verification workstream.

**Non-goals** (explicit): online multiplayer (the original never shipped its v0.9 MMO mode), weather and seasons (absent from the original), mobile/Android, and an in-game Pokédex (the original lacks one; parity does not require it — kept as an optional stretch in Phase 9).

**Operating constraint:** the playtest suite stays **local** for the foreseeable future. CI remains lint/contract-only; runtime verification is hardened locally instead (see the Local Verification workstream).

## Relationship to the active harness plan

`harness-engineering-reorientation.md` remains active and orthogonal — it owns legibility and harness health; this plan owns feature surface area. Both share the same doc contract, and every phase below pays it.

## Per-slice definition of done

Every phase is delivered as one or more **slices**, and a slice is not done until all of these hold:

1. **Spec**: a product spec in `docs/product-specs/` (new or extended) with `Supported behavior`, `Persistence`, and `Smoke validation` sections, matching the house format.
2. **Registry**: every new script/scene belongs to a registered subsystem in `docs/registry/subsystems.toml` with `validation_commands` and `required_trace_events` updated.
3. **Architecture**: layering rules and line budgets hold (`app`/`ui` ≤ 220 lines, other scripts ≤ 320, `.tscn` ≤ 250) — `check_architecture.py` passes. Files near budget are split *before* adding (see Phase notes).
4. **Traces**: new behaviors emit structured events; every new event is documented in `docs/references/trace-events.md`. No new silent fallbacks — degraded paths emit `warning` traces.
5. **Scenarios**: at least one new smoke/playtest scenario asserts the behavior end-to-end; save-backup/restore semantics preserved.
6. **Visuals**: new UI states or overworld visuals get committed baselines via `visual_sweep_update`, and changed shots get a vision review per `docs/references/vision-review-rubric.md`.
7. **Docs**: `docs/QUALITY_SCORE.md`, `docs/RELIABILITY.md`, and `docs/tech-debt-tracker.md` updated (this is mechanically enforced by `check_change_contract.py`).
8. **Local gate**: `python3 tools/verify_all.py` (Phase L) green: static checks + full playtest suite + windowed visual sweep + legibility lint.

## Phase 0 — Defect fixes & repo hygiene (no new features)

**Why**: the audit found six verified defects, two of which destroy player data. All are small; none should survive into the feature phases.

| # | Item | Files | Acceptance |
|---|------|-------|-----------|
| 0.1 | Full-party capture permanently loses the Pokémon | `battle_runtime.gd:90-91`, `session_state.gd` | Overflow Pokémon is relocated to the player's **last campsite** (anchor defaults to spawn until Phase 2 adds rest sites); retrievable on return; `mon_relocated` trace; `wild_battle` scenario extended with a full-party capture assertion |
| 0.2 | NEW GAME wipes the save instantly with no confirmation and leaves the menu open | `start_menu.gd:124-126`, `main.gd:148-150` | Confirm step (message box) before reset; menu closes on reset; `menu_save` scenario covers confirm + cancel |
| 0.3 | Non-atomic save writes with per-step autosave | `save_store.gd:33-39` | Write to temp file + rename; corrupt/absent save recovery traced, not silent; soak scenario unchanged |
| 0.4 | Save schema version written but never checked on load | `session_state.gd:45-56` | Unknown future version refused with a `warning` trace; v1/v2→v3 migration gains a dedicated fixture scenario (`save_migration`) per RELIABILITY's own open risk |
| 0.5 | Blackout heal cures HP only | `session_state.gd:117-121` | `heal_party_full` clears status + `sleep_turns`; `wild_battle` defeat path asserts clean status |
| 0.6 | `world_view._tile_cache` grows unbounded | `world_view.gd:30, 252-260` | LRU/window eviction matching the visible window; `overworld_step` soak asserts bounded cache size after N steps |
| 0.7 | ObjectDB/resource leak at exit | boot path (found via `--verbose`) | `--headless --quit` exits with zero leak warnings |
| 0.8 | Repo hygiene | `.gitignore`, `.editorconfig`, repo root | Commit `.uid` files (Godot 4.4+ convention) and add them to subsystem `code_paths` where appropriate; move/remove the root screenshot; `.editorconfig` gains indent rules (tabs for `.gd`); resolve the `action_b`/`run` KEY_X double-bind in `input_router.gd` |
| 0.9 | Doc drift batch | `QUALITY_SCORE.md`, product specs, `README.md` | 113→114 items; settle 298 vs 299 moves; replace stale "unlock path" wording in bootstrap/menu specs with the capability model; refresh README "Current slice" |

**Exit criteria**: zero audit defects open; `verify_all.py` (once Phase L lands, else the manual suite) green; tech-debt-tracker cleared of the above.

## Phase 1 — Placement & building (original feature #8)

**Why**: building is the promised follow-up to the harvest slice, and it is the keystone — nothing downstream (campfires, beds, pens, storage boxes) exists without a placement system. It also gives the dead-end harvest economy its first consumers.

**New spec**: `docs/product-specs/building-and-placement.md`. **New subsystem**: `building_loop` (runtime + domain).

**Work**:
- `scripts/domain/structures.gd` (new, domain): structure definitions (wall, roof, door, partition, campfire pad, bed, storage box, pen fence), per-biome material costs, occupancy rules. Pure data + rules.
- `scripts/domain/world_overrides.gd`: extend the sparse override map to carry **placed structures** (not just cleared tiles). Watch the 10k cap policy — split stored overrides into `clears` vs `placements` if needed.
- `scripts/runtime/structure_layer.gd` (new, runtime): ghost-preview placement, occupancy queries, render of placed structures. **Do not extend `world_view.gd` (290/320 lines)** — compose it.
- Build field move becomes functional: `Z` on a walkable tile with a Build-capable party member (Fighting types) opens build mode; materials consumed from the bag (`session_state` item API).
- Structures: walls, roofs, interior partitions, doors (connected rooms), furniture (bed, storage box placeholders until Phases 2–3 fill them).
- Party-screen `FIELD MOVE` becomes real: `main.gd:135` must consume `move_id` instead of ignoring it.

**Traces**: `build_mode_entered`, `structure_placed`, `structure_refused` (with reason), `materials_consumed`.
**Scenario**: `placement_flow` — refuse without materials/capable mon, place wall+door, prove occupancy blocks pathing, persistence across save round-trip, world-consistency audit extended to placed structures.
**Baselines**: overworld with a built structure (new visual-sweep shot).

**Exit criteria**: a small house with a door is buildable from harvested materials; occupancy agrees across logic/render/collision; persists in save v3 (or v4 if the override schema changes — decide in spec).

## Phase 2 — Camping, crafting & night survival (original features #6, #9, #11, #12)

**Why**: this is the survival identity of PokeWilds: no Pokémon Centers, sleep to heal, light or die at night. It also consumes harvest outputs (crafting recipes), closing the economy loop Phase 1 opened.

**New spec**: `docs/product-specs/camping-crafting-survival.md`. **New subsystems**: `camping_loop`, `crafting` (or one `survival_loop` subsystem — decide in spec; prefer two if either crosses 320 lines).

**Work**:
- **Placeable camp objects** (on the Phase 1 placement system): campfire (light source + crafting station), sleeping bag (starting item, weaker rest), bed (crafted, full heal + status cure).
- **Campsite anchor**: resting establishes the campsite used by the 0.1 overflow relocation and blackout return (blackout returns to last campsite, not world origin — `battle_runtime.gd:292-294`).
- **Crafting at campfires**: recipe table in `scripts/domain/recipes.gd` (new): Poké Ball, Great Ball (Magnet + Hard Shell), Soft Bedding/bed, Old/Good/Super Rod. Craft UI is a campfire menu (new `ui` scene, ≤220 lines).
- **Rest/heal model**: sleeping heals party; beds cure status, sleeping bags don't (or partial — spec decides); time advances while resting.
- **Night danger**: without a lit light source (campfire, torch, Fire-type with Flash — Flash arrives in Phase 4, so campfire/torch first), Ghost-type encounters attack at night; shadow Pokémon block retreat until dawn unless sheltered by firelight.
- **Nocturnal spawns**: encounter selection gains a time-of-day filter (`biome_encounters.gd` + `game_runtime._pick_encounter_species`).
- **Time-of-day evolutions**: pass real time context into `check_level_evolution` (`battle_runtime.gd:259`, `pokemon_rules.gd:240-247`) so Espeon/Umbreon/Frosmoth gates actually gate.

**Traces**: `campfire_lit`, `rested`, `item_crafted`, `night_hazard_spawned`, `retreat_blocked`, `evolution_time_gate`.
**Scenarios**: `camp_survival` (rest heals, bed cures status, blackout→campsite), `craft_flow` (recipe refusal without mats, craft Great Ball, use it), `night_cycle` (seeded clock: ghost spawn without light, none with campfire).
**Baselines**: night-tinted overworld with lit campfire; craft menu.

**Exit criteria**: a player can survive nights indefinitely using harvested/crafted light; healing is fully self-sufficient; day/night has mechanical consequences, not just a tint.

## Phase 3 — Storage boxes & party management (original feature #10)

**New spec section** in `menu-and-save.md` (or new `storage.md`). **Subsystem**: extend `menu_ui`/`session_runtime`; new scene `scenes/ui/StorageScreen.tscn` (ui scenes may reference only ui).

**Work**:
- Craftable **Storage Box** structure (Phase 1 placement) — each box is an **independent, non-shared** container (faithful to the original: no shared PC). Box contents persist per-box in the save (schema bump to **v4**: `structures` gain `contents`; migration path for v3).
- Deposit/withdraw UI; release mechanic (with confirmation — we just fixed one destructive action in 0.2, don't add another).
- Overflow-capture routing from 0.1 gains a box-aware policy if the player is at a campsite with boxes (spec decides priority: campsite ground vs box).
- Party screen: arbitrary reorder (currently swap-lead-only) + deposit.

**Traces**: `mon_deposited`, `mon_withdrawn`, `mon_released`, `box_opened`.
**Scenario**: `storage_flow` — craft box, deposit/withdraw round-trip, per-box independence (two boxes don't share), persistence.

**Exit criteria**: no Pokémon is ever lost to a full party; boxes behave as independent objects in the world and in the save.

## Phase 4 — Field move completion (original feature #7)

**Why**: 8 of 12 field moves currently have rules with zero callers. Several are prerequisites for later phases (Flash→night, Charm/Attack→overworld Pokémon, Teleport/Way Stones→world depth, Ride/Fly→traversal).

**Updated spec**: `harvest-and-mutation.md` grows a `Traversal & utility moves` section (or a new `field-moves.md`).

**Work** (per move, each with a caller + scenario assertion):
- **Flash**: light source alternative to campfire/torch (completes Phase 2's night design).
- **Teleport + Way Stones**: placeable/registered warp points; teleport to last way stone. (Teleport Beacons for world edges land in Phase 7.)
- **Ride**: mount a Ride-capable party member for faster overworld movement (`player_avatar.gd` speed mode + mount sprite).
- **Fly**: aerial travel to visited way stones; edge-fly is the Phase 7 chaining trigger.
- **Attack / Charm**: overworld combat and pacify/recruit actions — the hooks Phase 6 consumes.
- **Repel**: suppress wild encounters for N steps (session state counter).
- **Power**: strength tasks (moveable boulder props — smallest scope; tie to a landmark gate in Phase 7 if useful).
- `field_moves.gd:6` `AUTO_TYPES` gains fly/ride mappings; capability model unchanged.

**Traces**: `flash_lit`, `teleport_used`, `waystone_registered`, `mount_summoned`, `fly_used`, `overworld_attack`, `charm_used`, `repel_active`.
**Scenarios**: `field_moves_extended` (each move's happy path + refusal), added to the soak bot's repertoire.
**Baselines**: mounted overworld; Fly menu.

**Exit criteria**: all 12 original field moves have runtime effects and scenario coverage; the party-screen FIELD MOVE action is meaningful.

## Phase 5 — Pokémon systems: shinies, breeding, habitat drops, fishing, evolutions (original features #13, #14, #15 + shiny half of #5)

**New spec**: `docs/product-specs/pokemon-systems.md`. **New subsystems**: `breeding_loop` (runtime+domain), evolution-stone wiring in `pokemon_progression`.

**Work**:
- **Shinies**: 1/256 roll at instance creation (`pokemon_rules.create_pokemon_instance` gains `is_shiny`), palette-variant rendering in battle (`battle_surface.gd`) and overworld, **shiny status visible on eggs before hatch** (faithful), user-adjustable odds hook (original FAQ notes this as planned).
- **Breeding**: penned females lay eggs near a compatible male (same Egg Group — data already parsed at `species_file_parser.gd:114-118`), with proper **habitat tiles** (type-matched pen environment); egg moves from father; Ditto breeds with anything; the original's legendary/genderless breedability workaround. Pens are Phase 1 fences + Phase 5 habitat-tile rules.
- **Habitat happiness & drops**: happiness rises when penned in type-matched habitat (dual-types need both tiles — `biome_defs` tile types); happy penned Pokémon periodically drop items/materials (Miltank→Moo Moo Milk et al.). This consumes the `happiness` field that already exists.
- **Evolution stones**: items from Dig drops and Steel-type drops; bag-use calls the already-implemented-but-uncalled `check_item_evolution` (`pokemon_rules.gd:169-176`).
- **Fishing**: craftable rods (Phase 2 recipes) + water encounters by rod tier (`player_avatar`/`game_runtime` fishing state).

**Traces**: `shiny_rolled`, `egg_laid`, `egg_hatched`, `habitat_happiness_changed`, `item_dropped`, `evolution_stone_used`, `fish_hooked`.
**Scenarios**: `breed_flow` (seeded pairing→egg→hatch with egg move), `shiny_odds` (statistical check over seeded rolls — deterministic, not flaky), `habitat_drops` (penned Miltank drops milk), `fishing_flow`.
**Baselines**: shiny battle sprite; egg in pen.

**Exit criteria**: the breed→hatch→shiny-hunt loop works end-to-end; penned Pokémon produce; stone evolutions trigger from the bag.

## Phase 6 — Overworld Pokémon (original features #3, #4)

**Why**: the original's signature interaction — visible roaming Pokémon, friendly ones recruitable via dialogue, hostile ones battled, Alphas guarding nests. The port currently uses random grass encounters, the *opposite* model. This is the highest-design-risk phase; spec it first and prototype the entity layer before committing.

**New spec**: `docs/product-specs/overworld-pokemon.md`. **New subsystem**: `overworld_mons` (runtime + domain + ui dialogue).

**Work**:
- Overworld Pokémon entities: spawn/despawn rules per biome and time of day, roaming behavior, flee/aggro dispositions. Render layer composes with y-sort depth (`world_draw_order` contract must be extended and audited).
- Interaction model: **Charm**-recruit friendly mons (Phase 4 hook), **Attack** triggers battle with hostile mons, dialogue-style recruitment for a recruitable subset.
- **Nests & eggs**: wild egg nests guarded by **Alpha Pokémon** (buffed overworld mons); stealing an egg provokes the guardian (forced battle). Eggs hatch via Phase 5 incubation.
- Random grass encounters remain as the background encounter source (the original has both roaming mons *and* biome encounters) — spec the rate balance explicitly.

**Traces**: `overworld_mon_spawned`, `overworld_mon_despawned`, `recruit_attempted`, `recruit_succeeded`, `nest_found`, `egg_stolen`, `alpha_provoked`.
**Scenarios**: `overworld_mons` (spawn determinism on seed, charm-recruit, hostile engage, egg-steal→alpha battle).
**Baselines**: overworld with roaming mons; nest + Alpha.

**Exit criteria**: every biome shows roaming Pokémon with correct dispositions; recruitment and egg-stealing work; `world_consistency_audit` and `world_spatial_audit` extended to mon entities.

## Phase 7 — World depth: landmarks, legendaries, world chaining (original features #2, #17)

**New spec**: `docs/product-specs/world-depth.md`. **Subsystem**: extend `world_runtime`; new `landmarks` domain module.

**Work**:
- **Landmarks**: multi-tile structure generator (the current world places only single-tile props — `biome_defs.gd:64-94`). Pokémon Mansion (key item + statue switch puzzle), desert Ruins (glowing statues, high-level mons like Volcarona), Heart Tower. Map the dormant `PKMNMANSION`/`RUINS_*` encounter tokens (`biome_encounters.gd:14`).
- **Legendary placement**: rarity-aware encounter filtering — 7 legendaries exclusive to distant/hard biomes (SNOW/LAVA rings); the legendary battle music (`music_router.gd:33`) finally gets callers.
- **World chaining** (highest risk — spec separately within the phase): surf/fly off a map edge generates an adjacent world; Teleport Beacons (Phase 4 way-stone tech) at edges. **Save schema v5**: world identity (`world_id`) prefixes overrides and campsite anchors; migration from v4. Determinism: per-world seeds derived from a root seed so chains are reproducible.

**Traces**: `landmark_entered`, `puzzle_state_changed`, `legendary_encounter`, `world_edge_crossed`, `world_chained`, `beacon_placed`.
**Scenarios**: `landmark_flow` (Mansion puzzle solved on a fixed seed), `legendary_spawn` (ring-gated spawn proof, extends `biome_probe`), `world_chain` (edge crossing + return + per-world override persistence).
**Baselines**: Ruins interior; mansion; beacon.

**Exit criteria**: the world has destinations, not just terrain; legendaries are rare and distance-gated; chained worlds persist independently.

## Phase 8 — Battle completeness (original feature #5 edges)

**Why**: the engine is mature but deliberately trimmed. These are independent of the world phases and can run **in parallel** with Phases 3–7.

**Updated spec**: `battle-and-capture.md`.

**Work** (each a small, scenario-backed slice):
- In-battle party switching (un-disable PKMN in `battle_surface_layout.gd:176`; add switch rules to `battle_runtime`).
- **Struggle** at 0 PP (currently moves just disable — `battle_surface_layout.gd:197`; enemy 'has no moves left' pass loop at `battle_runtime.gd:165-167`).
- **Capture presentation**: ball throw + wiggle shakes (per-wiggle checks from the existing formula), using the existing `pokeball_wiggleSheet1_color.png` assets.
- **Ball tiers live**: Great/Ultra balls become craftable (Phase 2) and usable (`battle_runtime.gd:6` BALL_ID is hardcoded; item menu lists only poke_ball at `battle_surface_layout.gd:207-212`).
- **Move effect families**: close the 111/141 gap in usage order — screens (Reflect/Light Screen), weather, multi-hit, Substitute, Baton Pass, Thief, Counter/Mirror Coat, Solar Beam charge, Rapid Spin, Mean Look. Each effect that still degrades must keep its `warning` trace until handled. `battle_runtime.gd` is at 319/320 lines — **split effect resolution into `scripts/domain/move_effects.gd` before adding any**.
- Accurate growth curves: Erratic/Fluctuating instead of the MEDIUM_SLOW approximation (`pokemon_rules.gd:36-38`).
- Keep the documented modernizations (Gen VI+ chart, phys/spec split, 1/24 crit) — they are deliberate spec deviations, not bugs.

**Traces**: `battle_switched`, `struggle_used`, `ball_wiggle`, `move_effect_applied` (per family).
**Scenarios**: `battle_switch_struggle`, `capture_wiggle` (scripted shake counts), effect-family scenarios per batch.
**Baselines**: wiggle animation frames; switch menu.

**Exit criteria**: no move in the 299-move catalog silently no-ops beyond an explicit, traced design decision; capture has presentation parity.

## Phase 9 — Meta, localization & ship-readiness

**Work**:
- **Localization wiring**: the dump ships ES/FR/DE/PT-BR properties (unused — `pokemon_catalog.gd:6-10` hardcodes English; no `TranslationServer` usage). Wire a translation layer over the parsed catalogs; locale selection in the start menu.
- **Missing display names**: 104/990 species render as humanized slugs — source or generate proper names.
- **Determinism pinning**: FastNoiseLite output is stable per engine version but not contractually pinned across upgrades. Add a golden-hash scenario (`worldgen_golden`) asserting fixed seeds produce fixed tile hashes; record the engine version (4.6.1) in RELIABILITY. An engine upgrade then fails loudly instead of silently regenerating worlds and stranding saves.
- **Licensing decision**: ~55k ripped Gen 2 sprites + 1.5k audio ride in a submodule with no upstream LICENSE (`THIRD_PARTY.md` disclaims, not clears). Decide and document the distribution posture: private fan project only, or asset-replacement path for public distribution. This is a project-owner decision; the plan's job is to force it before any release.
- **Quality pass**: every `QUALITY_SCORE.md` row to 3/3/3/3; close all tech-debt-tracker items; archive completed superpowers plans into `docs/exec-plans/completed/` (currently empty).
- **README & docs refresh**: README "Current slice" matches reality; `docs/exec-plans/completed/` gets the finished phase plans.
- Optional stretch: in-game Pokédex (exceeds the original; only if time allows).

**Exit criteria**: the project's own definition of done (below) holds.

## Workstream L — Local verification hardening (continuous, per the stay-local constraint)

CI stays lint/contract-only. The local suite absorbs the enforcement role instead:

1. **One-command local gate**: `tools/verify_all.py` — static checks (`check_repo_contracts`, `check_architecture`, `check_quality_docs`, `check_change_contract`) → full playtest suite (`run_playtests.py --include-smoke`, windowed so `visual_sweep` runs its real transport) → legibility report. Single nonzero exit on any failure. Documented as *the* pre-push ritual in RELIABILITY.md and AGENTS.md.
2. **Transport honesty**: fix the `visual_sweep` forced-headless failure mode — the runner should mark windowed-only scenarios as skipped (not failed) under `PLAYTEST_FORCE_HEADLESS`, and report `19/19 (1 skipped-headless)` rather than a lying `18/19`.
3. **Artifact freshness**: `playtest-report.json` gains the HEAD sha; `verify_all.py` refuses to certify a report older than HEAD; per-scenario `result-*.json` staleness (the stale red `result-visual_sweep.json`) is swept on each run.
4. **Lane 4 automation**: `tools/vision_review.py` drives a vision-capable reviewer over changed shots after each sweep and writes `.godot-smoke/vision-review.json` per the existing rubric/schema — fulfilling the oracle spec's "findings file on every sweep" criterion locally.
5. **Graduate the pixel lint**: graduation machinery **landed** (Slice 6 of the legibility/vision plan). `tools/graduation_ledger.py` (`record`/`status`/`calibration`) banks each windowed `ui_render_audit` run — head_sha, boot-delimited session identity, per-state finding counts, `text_oracle_passed` payload — into the **committed evidence binder** `docs/generated/graduation-ledger.json`; streaks and flippability are computed from recorded entries, never asserted, and unstamped historical sessions are never backfilled into flip-qualifying streaks. Per-state flips of `GRADUATED_STATES` (`ui_render_audit.gd:16`) proceed on that recorded evidence only — **5 consecutive clean windowed runs at the current HEAD**, in the documented order (battle_moves + battle_item FIRST — ANCHOR glyph-template match; battle_action NEXT — lint cleanliness on ACTION_ROWS; battle_message LAST — BOX mode with a required documented judgment) — and each flip graduates the state's entire pixel lint (glyph + lint findings go red together; the flip changes the harness's tiering, not the game). Calibration rides the same pipeline (the quarantine→graduation loop **is** the free VLM calibration): the first cycle is the baseline with honest zero-denominators; a two-cycle trend needs the next legibility-garden cycle (weekly, Mon 14:00 UTC). An optional `uv` extra (`vision = [scikit-image]`, `tools/vision_metrics.py` SSIM-map corroboration) ships quarantine-forever and never gates CI. Graduate phase **complete** (2026-07-21, HEAD 7b733946): all four battle states flipped on five consecutive clean windowed runs recorded in the ledger (moves + item first, action next, message last with its documented box judgment); the seeded-defect proof went RED via the graduated gate and the same defect class stayed quarantine in a temporarily un-graduated state; calibration cycle 1 committed as the honest zero-denominator baseline. Every phase keeps adding baselines for its new states.
6. **Bot coverage**: the playtest bot gains capabilities as phases land — harvesting (already promised in the harvest design spec), then building, crafting, breeding checks — so `playtest_soak` exercises the new loops at 150-iteration depth.
7. **Scenario backlog from the audit**: evolution, battle status inflict/cure, and night mechanics get scenarios as soon as their phases exist (Phases 2 and 5 own them).

**Deferred optional capture spikes (explicitly off the critical path — recorded, not built).** Four Slice 6 options stay **DEFERRED**: the Movie Writer PNG-burst motion lane (quarantine-tier motion evidence for `battle_anim`, windowed at exactly 1152×648); the DAP `godot/put_msg` bridge; ScriptBacktrace (#91006) structured frames in error traces; and the live NDJSON-over-TCP introspection endpoint. The endpoint is specced as built **ONLY IF** in-process sidecars prove insufficient, and they have not — semantic sidecars + the explainable per-region diff + trace correlation already deliver the structured-observation value with zero new runtime surface. None gates CI; each would ship behind its own registry entry if ever adopted.

## Sequencing & dependencies

```
Phase 0 (defects)
   │
   ▼
Phase 1 (placement & building) ──► Phase 2 (camping/crafting/survival)
                                       │
                        ┌──────────────┼──────────────┐
                        ▼              ▼              ▼
                  Phase 3 (storage) Phase 4 (field moves) Phase 8 (battle edges)  ◄── parallelizable
                        │              │
                        ▼              ▼
                  Phase 5 (breeding/shinies/drops/fishing — needs pens + rods)
                                       │
                                       ▼
                        Phase 6 (overworld Pokémon — needs Charm/Attack)
                                       │
                                       ▼
                        Phase 7 (landmarks/legendaries/world chaining)
                                       │
                                       ▼
                        Phase 9 (meta, localization, ship-readiness)

Workstream L runs continuously under every phase.
```

Phases 3, 4, and 8 are mutually independent and can proceed in parallel (or in any order) once Phase 2 lands. Phase 7's world-chaining item may be deferred past Phase 9 if the save-schema-v5 design proves costly — landmarks and legendaries do not depend on it.

## Project definition of done

The rewrite is **finished** when:

- All 22 audit features are `done` (world chaining may be an explicitly documented deferral).
- `tools/verify_all.py` is green on HEAD, with a fresh report stamped with the HEAD sha.
- Every `QUALITY_SCORE.md` row is 3/3/3/3; tech-debt-tracker has no `blocker`/`major` items.
- Vision review shows zero unaddressed defects; pixel lint graduated and gating.
- The licensing decision is documented; README, specs, registry, and RELIABILITY describe the game that actually exists.

## Risks

| Risk | Mitigation |
|------|-----------|
| **Line-budget pressure**: building, breeding, and move effects all want large files | Split first: `structures.gd`, `recipes.gd`, `move_effects.gd`, `structure_layer.gd` are pre-named in the phases; `battle_runtime.gd` (319 lines) must not grow |
| **Save-schema churn**: Phases 3, 7 bump v3→v4→v5 | Each bump ships a migration fixture scenario (`save_migration` from 0.4 becomes a pattern); version check from 0.4 makes bad loads loud |
| **Worldgen determinism across engine upgrades** | Phase 9 golden-hash scenario pins it; submodule is already pinned |
| **Overworld-Pokémon design risk** (Phase 6 inverts the current encounter model) | Spec + prototype the entity layer before implementation; keep grass encounters as the background source |
| **Scope creep in world chaining** | Explicitly deferrable past Phase 9; landmarks/legendaries stand alone |
| **Licensing** | Phase 9 forces a documented decision before any distribution |
| **Playtest determinism as systems interact** | Every phase extends the seeded soak with its invariants (Workstream L.6); crafted-state baselines keep visuals honest |

## First sprint (suggested cut)

Phase 0 in full (≈6 defects + hygiene) + Workstream L.1–L.3 (`verify_all.py`, transport honesty, artifact freshness) + the Phase 1 spec written and reviewed. This clears the data-loss bugs, makes the local gate a single command, and sets up the keystone phase without committing its implementation yet.
