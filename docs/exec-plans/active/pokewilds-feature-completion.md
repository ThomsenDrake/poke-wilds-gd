Status: active
Last verified: 2026-07-27
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
8. **Local gate** (IMPLEMENTED, Workstream L.1): `python3 tools/verify_all.py` green — the four static gates + determinism pins/canary + the full headless playtest suite + the windowed pixel lanes (`ui_render_audit` + `visual_sweep`) + the legibility report, with mechanical refuse-on-mismatch/freshness refusals and four exit codes (0 GREEN / 1 STEP_FAILURE / 2 REFUSAL / 3 TOOL_ERROR; `--skip-windowed` for display-less envs). See `docs/RELIABILITY.md` § Local gate.

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

**Exit criteria**: zero audit defects open; `python3 tools/verify_all.py` (Workstream L.1, landed) green; tech-debt-tracker cleared of the above.

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

### Part A — Control-schema fixes (front-loaded; LANDED 2026-07-24)

- **A1 (behavior) — LANDED**: the two same-press double-fires killed at their shared root. `input_router.gd` gained a same-frame latch set by the camp menu's `closed` signal (which fires synchronously during the input phase, before `Main._process` polls): `poll_menu_toggle` skips on the latch and `poll_context_action` captures + resets it, so a press that closed the camp menu no longer also opens the start menu (Enter) or re-fires harvest/build on the bare former campfire tile (Z-on-Demolish). `main.gd` stays 220/220 on same-line edits only (bind the camp menu in `_ready`; `_toggle_menu` additionally guards on `$UI/CampMenu.visible` for direct-call paths; `smoke_context` exposes `camp_menu`). `camp_menu.gd` untouched; the router's visibility guard stays as defense-in-depth.
- **A2 (docs) — LANDED**: `bootstrap-and-overworld.md` § Input map gained the overworld context-Z row (harvest → camp-object interact → build precedence), the camp-menu-ownership/latch row (names both killed double-fires and the `Main._process` poll-order contract), and the build-mode keys row; README gained a Controls section; the build-cycle attribution fixed to the original's L/R shoulder cycle (`.firecrawl/house-building-scrape.md:259`) with the C/V dev-paint-tool distinction (`.firecrawl/github-readme.md:333`) in `building-and-placement.md` and `structure_layer.gd`; stale UI child-order comments fixed (`start_menu.gd`, `message_box.gd`: CampMenu is the last UI child since Phase 2).
- **A3 (party field moves) — LANDED**: capability-display with a clear message (chosen over silent degrade): `field_action_router.gd` gates the non-build FIELD MOVE branch on `HARVEST_ACTIONS` (cut/dig/smash keep the exact harvest path); any other move shows "X knows Y, but there's nothing here that needs it." instead of silently harvesting. `menu-and-save.md` records the classification with verified file-anchored species-flag counts (headbutt 57 / ride 32 / fly 30 / cut 10 / surf 6 / flash 6 / dig 2 / smash 2 / power 1 / paint 1; **build 0**) plus the audit-counts-differ note; `building-and-placement.md`'s FIELD:BUILD falsehood corrected (build never renders — the flag==1 filter, 0 species; the live build path is overworld Z with a FIGHTING-capable member).
- **A4 (ergonomic docs) — LANDED**: left-click activation on start/camp menu entries documented in `menu-and-save.md` (kept as a documented convenience, keyboard stays canonical); the bed demolition path documented in `building-and-placement.md` § Demolition and mirrored into `camping-crafting-survival.md`'s BED bullet (Z on a bed always rests; demolition is via party-screen FIELD MOVE with a Cut-capable mon).
- **A5 (regression scenario) — LANDED**: new `scripts/app/input_gate_scenario.gd` (`input_gate`, qa-dispatched, dispatcher save-guarded) drives REAL input-phase events via `Input.use_accumulated_input` (press and release in separate frames — `smoke_scenarios._press` presses+releases in one frame, which can never fire a poll) and proves (a) Enter with the camp menu open closes ONLY the camp menu (start menu stays shut, no `menu_opened`, avatar re-enabled, no dual control) and (b) Z-on-Demolish demolishes the campfire and does NOT re-fire harvest/build (no build mode, no `structure_placed`/`materials_consumed`/`field_move_used`, bag delta exactly the refund). Every tap carries an injection witness; the party is cut + build + dig-capable so a re-fire is LOUD (a bare dig-biome tile would otherwise degrade to an invisible refused dig). Verified red BEFORE the latch (both races reproduced through the real input path) and green AFTER. Registered in `qa_scenarios.gd`, `run_playtests.py`, `godot_dap_smoketest.py`, the `app_bootstrap` registry entry, and RELIABILITY.md.

**New spec section** in `menu-and-save.md` (or new `storage.md`). **Subsystem**: extend `menu_ui`/`session_runtime`; new scene `scenes/ui/StorageScreen.tscn` (ui scenes may reference only ui).

**Work**:
- Craftable **Storage Box** structure (Phase 1 placement) — each box is an **independent, non-shared** container (faithful to the original: no shared PC). Box contents persist per-box in the save (schema bump to **v4**: `structures` gain `contents`; migration path for v3).
- Deposit/withdraw UI; release mechanic (with confirmation — we just fixed one destructive action in 0.2, don't add another).
- Overflow-capture routing from 0.1 gains a box-aware policy if the player is at a campsite with boxes (spec decides priority: campsite ground vs box).
- Party screen: arbitrary reorder (currently swap-lead-only) + deposit.

**Traces**: `mon_deposited`, `mon_withdrawn`, `mon_released`, `box_opened`.
**Scenario**: `storage_flow` — craft box, deposit/withdraw round-trip, per-box independence (two boxes don't share), persistence.

**Exit criteria**: no Pokémon is ever lost to a full party; boxes behave as independent objects in the world and in the save.

**LANDED 2026-07-24 (scenarios + baselines)**: `storage_flow` (qa-dispatched, dispatcher save-guarded; all ten groups green three consecutive runs — box open, deposit/withdraw with exact payloads incl. the `deposit_to_nearest` party-screen path, every `storage_refused` reason + `demolish_refused{box_not_empty}` then the empty-box Cut, BOTH confirm-gated release branches via real injected keys, two-box independence in the world AND across the save round-trip, v4 persistence + corrupt-`contents` normalization, the overflow NO-ROUTING proof, the dynamic witness guard, and the MOVE reorder commit/cancel/persist) — its input-driven half lives in `storage_flow_party_checks.gd` (app line-budget extraction, the `placement_flow` rationale). `save_migration` extended: v3 fixture gains a contents-less `storage_box` (asserts the empty backfill) + campsite-hold keys; v4 fixture round-trips `contents` and normalizes a `"garbage"` contents to an empty box (`v4_ok` in the pass payload; `wild_battle` extracted to `wild_battle_scenario.gd` to make room). Baselines: `visual_sweep_storage` shots `18_storage_box` + `19_storage_screen` (windowed; byte-identical across consecutive runs AND vs the committed baselines; the shared `_foreign_shot` prune/report guard extended to `18_`/`19_` — main + camping sweeps re-verified green with the new baselines co-present) + the `ui_render_audit` `storage` state (menu audit, `bag_names` extracted to `ui_render_model.gd` for the budget). The scenario surfaced and killed a same-SIGNAL double-fire the code builders missed: `MessageBox.confirmed` is shared — `start_menu._on_new_game_confirmed` + `storage_screen._on_release_confirmed` are now gated on their own `_awaiting_confirm` (a RELEASE confirm used to reset the game). **LANDED 2026-07-24 (Phase 3 final-review fixes — the six review-found majors)**: the storage box's overworld Z-route + `_overlay_open` gate in `field_action_router.gd` are WIRED — the campfire-pattern `BOX_ID` arm (disable avatar + `open_screen(tile)`; `closed` → re-enable + save), `_overlay_open` covering BOTH overlays, and the StorageScreen visibility in `main.gd`'s `overworld_idle` + `_toggle_menu` (four same-line main.gd edits total: the `bind_ui_consumers` line, the `_field_router.setup` argument, the `overworld_idle` check, the `_toggle_menu` guard). `storage_flow` now drives the box loop through the REAL Z seam (the `set_battle` poll-gate workaround is gone). The camp-only same-frame latch is GENERALIZED (`input_router.bind_ui_consumers` connecting the argless closed/confirmed/cancelled signals of CampMenu, StartMenu, MessageBox, AND StorageScreen — one latch set by every producer, consumed by both polls), closing the three leak paths the camp-only latch missed: a start-menu CLOSE, a MessageBox NEW GAME confirm, and an inert party-screen FIELD MOVE no longer re-fire the faced-tile harvest/build on their closing/confirming frame (`input_gate_menu_checks.gd`, parts C/E/D). The S2 release-confirm mouse-bypass is gated at `storage_screen.gd`'s `_on_entry_clicked` (`storage_release_mouse_check.gd`); the S1 party-screen DEPOSIT resolves through `box_tile_near`'s `{found, tile}` shape (already landed). New shared extraction `smoke_tap.gd` (real-input-phase taps). Overflow policy landed as decided: no box routing (campsite hold is canonical). The latch's BATTLE-END arm landed the same day (the surviving leak the menu arm left open — a press that ENDS A BATTLE re-fired the same-frame overworld context action, the harvest toast superseding "Got away safely!"): `input_router.gd`'s public `note_press_consumed()` is called on `main._on_battle_finished`'s `_in_battle = false` line (one same-line edit, main.gd stays 220/220), set UNCONDITIONALLY at the single `battle_finished` endpoint so every end path is covered, and the new `battle_end_input` regression scenario (real input-phase taps via the shared `smoke_tap.gd`, `seed_for_smoke`-pinned, proven red-before/green-after) proves the escape AND capture end-presses no longer re-fire (the faced cut trees stand, the escape/capture toasts survive) AND that a fresh deliberate press the next frame still harvests (no over-suppression — `poll_context_action` resets the latch unconditionally).

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
**Baselines**: mounted overworld.

**Exit criteria**: all 12 original field moves have runtime effects and scenario coverage; the party-screen FIELD MOVE action is meaningful.

## Phase 5 — Pokémon systems: shinies, breeding, habitat drops, fishing, evolutions (original features #13, #14, #15 + shiny half of #5)

**New spec**: `docs/product-specs/breeding-shinies-drops-fishing.md`. **New subsystems**: `breeding_loop` (runtime+domain — incl. the habitat-drops runtime/domain) and `fishing` (runtime+domain); evolution-stone wiring in `pokemon_progression`.

**Work**:
- **Shinies**: 1/256 roll at instance creation (`pokemon_rules.create_pokemon_instance` gains `is_shiny`), palette-variant rendering in battle (`battle_surface.gd`) and overworld, **shiny status visible on eggs before hatch** (faithful), user-adjustable odds hook (original FAQ notes this as planned).
- **Breeding**: penned females lay eggs near a compatible male (same Egg Group — data already parsed at `species_file_parser.gd:114-118`), with proper **habitat tiles** (type-matched pen environment); egg moves from father; Ditto breeds with anything. The original's legendary/genderless breedability workaround: the port ships the FAITHFUL default — genderless/Undiscovered/legendaries do NOT breed even with Ditto (`ALLOW_UNDISCOVERED_BREEDING := false`, wiki Note b v0.8.9-0.8.11; no scrape documents the workaround in the original); the breedable variant stays one flagged const flip away. Pens are Phase 1 fences + Phase 5 habitat-tile rules.
- **Habitat happiness & drops**: happiness rises when penned in type-matched habitat (dual-types need both tiles — `biome_defs` tile types); happy penned Pokémon periodically drop items/materials (Miltank→Moo Moo Milk et al.). This consumes the `happiness` field that already exists.
- **Evolution stones**: bag-use **LANDED 2026-07-26** — the new `scripts/runtime/stone_evolution_runtime.gd` behind `game_runtime.use_stone_on_mon` calls the previously-uncalled `check_item_evolution` (`pokemon_rules.gd:176-183`); the bag screen's stone branch reuses the party picker; `breed_flow`'s stone group arms on the seam. ACQUISITION **SATISFIED 2026-07-26 (tech-debt item 11 RESOLVED)**: "items from Dig drops and Steel-type drops" was the design, and the faithful table is thinner than sketched — the only scrape-cited source is Beach Dig → Water Stone (`fresh-beach.md`) — so it landed as an honest faithful/divergent split. FAITHFUL: the Beach (SAND) Dig pool `{big_pearl, water_stone, clear_glass, revive}` (exact wiki order; `dig_item_found`). FLAGGED PORT ADDITIONS (each divergence-flagged in code + docs): the other-biome Dig pools (GRASSLAND/FOREST/SAVANNA/DESERT/SWAMP), the invented `DIG_BONUS_RARITY := 8` rate, and the Steel-type shiny_stone cadence drop (`wiki-materials.md:393` documents Steel = Metal Coat only, kept faithfully as the daily material; the exec plan's "Steel-type drops" being uncited intent). The "needs a seeded rng threaded into the harvest loop" blocker was solved WITHOUT consuming the shared `_rng` — every draw is a pure step-counter function (`harvest_resolver._dig_draw` over total_steps+tile; `habitat_drops.steel_stone_due` over types+day+last_stone_day), so the night_system determinism guarantee holds and NO build pins were re-stamped (seven scenarios byte-identical). RESIDUAL (still open, by design): ice_stone + dawn_stone have no world source (SNOW isn't diggable) and stay scenario-grant-only.
- **Fishing**: craftable rods (Phase 2 recipes) + water encounters by rod tier (`player_avatar`/`game_runtime` fishing state).

**Traces**: `shiny_rolled`, `egg_laid`, `egg_hatched`, `habitat_happiness_changed`, `item_dropped`, `evolution_stone_used`, `fish_hooked`.
**Scenarios**: `breed_flow` (seeded pairing→egg→hatch with egg move), `shiny_odds` (statistical check over seeded rolls — deterministic, not flaky), `habitat_drops` (penned Miltank drops milk), `fishing_flow`, `playtest_breed_soak` (bot soak over pen breeding + drops + fishing invariants), `visual_sweep_pokemon` (windowed egg-in-pen + shiny-battle baselines); `field_moves_flow` also proves Dig stone acquisition (faithful Beach water_stone + flagged divergent-biome pools).
**Baselines**: shiny battle sprite; egg in pen.

**Exit criteria**: the breed→hatch→shiny-hunt loop works end-to-end; penned Pokémon produce; stone evolutions trigger from the bag — **SATISFIED 2026-07-26** (`use_stone_on_mon`); stone ACQUISITION from the world — **SATISFIED 2026-07-26** (tech-debt item 11 RESOLVED: the faithful Beach-Dig Water Stone pool + flagged port additions — the other-biome Dig pools + the Steel-type shiny_stone cadence drop; ice/dawn stones stay grant-only as the item-11 residual).

**LANDED 2026-07-26 (Phase 5 review fixes + the stone slice)**: the six review-found majors closed and the deferred stone exit criterion implemented. (1) The breeding lay gate was UNIFIED onto the drops comfort model — the divergent second habitat table in `breeding.gd` was deleted (zero external consumers after the mandated grep) and both subsystems now ride ONE scan (`HabitatDrops.pen_habitat_tags`, interior + one-tile ring) + `HabitatDrops.types_satisfied` per parent, so drops-comfortable ⟺ lay-gate passes by construction; `breed_flow` gained the proof cases — a FLYING pair penned around a live tree prop lays (`phase5_sites.find_feature_pen_site`), and WATER is proven at the domain layer with a no-water control (runtime MAGIKARP pen auto-arms on a seeded pond site — today a named skip, `skipped_no_water_site`). (2) The pasture store is ONE session key held BY REFERENCE (`breeding_runtime._pastures` IS `session.pastures`; habitat reads/writes in place), so the daily +10 reaches the 220 lay gate the same step — the deep-copy publish (and its rollback of habitat progress) is gone; the withdraw erase guard now requires BOTH mons and eggs empty. (3) `breed_flow` gained the wrong-egg-group negative (`run_wrong_group_case`: happy EEVEE×ABRA — both basic-recessive so the habitat gate cannot confound — with catalog-asserted disjoint groups AND catalog-asserted habitat-neutrality, nothing laid across eight cadences). (4–6) Doc reconciliation (this batch). Stone slice: `stone_evolution_runtime.gd` (validate→consume→swap→trace; stats/max_hp/current_hp/catch_rate recompute off the target entry — the exact `battle_runtime._try_evolve` level path) behind the one-line `game_runtime.use_stone_on_mon` seam + the bag-screen stone branch; `evolution_stone_used` (registry-required on `pokemon_progression`) has its first live caller; thunderstone and all ten ids resolve from `item.properties:80-89`. All Phase-5 scenarios double-run byte-identical; the shiny_odds 6/1024 pin holds.

## Phase 6 — Overworld Pokémon (original features #3, #4)

**Why**: the original's signature interaction — visible roaming Pokémon, friendly ones recruitable via dialogue, hostile ones battled, Alphas guarding nests. The port currently uses random grass encounters, the *opposite* model. This is the highest-design-risk phase; spec it first and prototype the entity layer before committing.

**New spec**: `docs/product-specs/overworld-pokemon.md`. **New subsystem**: `overworld_mons` (runtime + domain + ui dialogue).

**Work**:
- Overworld Pokémon entities: spawn/despawn rules per biome and time of day, roaming behavior, flee/aggro dispositions. Render layer composes with y-sort depth (`world_draw_order` contract must be extended and audited).
- Interaction model: **Charm**-recruit friendly mons (Phase 4 hook), **Attack** triggers battle with hostile mons, dialogue-style recruitment for a recruitable subset.
- **Nests & eggs**: wild egg nests guarded by **Alpha Pokémon** (buffed overworld mons); stealing an egg provokes the guardian (forced battle). Eggs hatch via Phase 5 incubation.
- Random grass encounters remain as the background encounter source (the original has both roaming mons *and* biome encounters) — spec the rate balance explicitly.

**Traces**: `overworld_mon_spawned`, `overworld_mon_despawned`, `recruit_attempted`, `recruit_succeeded`, `nest_found`, `egg_stolen`, `alpha_provoked`. — **ALL SEVEN LANDED** (source `"OverworldMonsRuntime"`), plus the symmetric `overworld_mons_passed`/`overworld_mons_failed` scenario markers (miss-002), the `visual_sweep_overworld_passed` sweep marker, and two documented payload-variant auxiliaries (`mon_provoked`, `egg_cleared`) — payloads documented exactly-as-emitted in `docs/references/trace-events.md`.
**Scenarios**: `overworld_mons` (spawn determinism on seed, charm-recruit, hostile engage, egg-steal→alpha battle). — **LANDED**: the gate scenario (+ two check splits for the app budget) pins the determinism contract twice over (byte-identical `entity_set_hash` across a seeded double run + the CONTROL that seeded wild draws are identical with entities active vs inert — the shared `_rng` provably unconsumed), per-biome spawn off the live catalog with the named wiki dispositions, charm-recruit + the :262 full-party refusal, the provoked:false/+3 forced-seam battles (:280/:284) under Repel, the :248 egg Attack/TAKE binary, the level-5 hatch, EVERY-creation `shiny_rolled{origin: "overworld"}`, and the transient save round-trip.
**Baselines**: overworld with roaming mons; nest + Alpha. — **LANDED**: `22_roaming_mons` + `23_nest_alpha` (png + sidecar; numbered after `21_shiny_battle`, 09-12 stay battle-reserved) via the new `visual_sweep_overworld` (+ update variant), captured with NO rng in the capture path.

**Exit criteria**: every biome shows roaming Pokémon with correct dispositions — **SATISFIED 2026-07-27** (all 11 biomes yield live roamers at deterministic band anchors; dispositions resolve off the LIVE catalog via the first-form + wiki-override table, asserted by name in both the scenario and the audit); recruitment and egg-stealing work — **SATISFIED 2026-07-27** (dialogue-recruit of friendly mons, Charm calm-then-interact, TAKE→`egg_stolen`+provocation+guardian forced battle, Attack-on-egg shiny-check with zero provocation); `world_consistency_audit` and `world_spatial_audit` extended to mon entities — **SATISFIED 2026-07-27** (the clears/mutation lane + the new entity lane live in the extracted `world_entity_audit.gd`, folded back by a 2-line call; `audit_z_order` scans entity sprites for the NAN `y_sort_key` chain-break and the north/south `draws_over` contract).

**LANDED 2026-07-27 (Phase 6)**: spec first (`docs/product-specs/overworld-pokemon.md`), then the entity-layer prototype (deterministic spawn from `(world_seed, total_steps)`, pure step-tick roam double-run-identical with NO `_rng`, y-sort composition proven before any disposition/nest logic committed). New files: `scripts/domain/overworld_mons.gd` (pure rules: slot/cell spawn draws, disposition resolution, Charm gate, egg-provocation rule, nest/Alpha rolls, the pinned constants), `scripts/runtime/overworld_mons_runtime.gd` (entity lifetime + every trace + the forced-battle pending seam — its `setup()` takes NO rng parameter, making the night-system determinism guarantee STRUCTURAL) with the step engine extracted to `overworld_mons_sim.gd`, the y-sort render node `scripts/runtime/entity_layer.gd` (a static self-wired `Main.tscn` child after Player — ZERO lines in main.gd/world_view.gd), `scripts/app/overworld_entity_actions.gd` (context-Z entity arms + the fence pen action moved out of `field_action_router.gd` for the entity-first precedence), the scenario + check splits, `scripts/app/world_entity_audit.gd`, and `scripts/app/visual_sweep_overworld.gd`. Budget walls were paid by EXTRACTION FIRST: `game_runtime.gd` freed `pick_wild_species` into `encounter_selection.gd` and its `fish_caught` block into `fishing_runtime.note_battle_finished` before the Phase-6 wiring; `world_consistency_audit.gd` shed its mutation lane. Persistence is TRANSIENT by explicit spec decision — NO save keys, NO `SAVE_VERSION` bump (v5 stays reserved for Phase 7); entities re-derive from `(world_seed, total_steps)` + clock at load, recruits/taken eggs persist via the party. Grass encounters REMAIN the background source unchanged (0.12/step); Repel wards the grass stream only (zero-code by construction — entity spawns never enter `generate_wild_encounter`). FLAGGED DIVERGENCES (14, consolidated in the spec + code comments; the highest-risk item first): (1) the nest + Alpha guardian model is NOT scrape-backed — shipped per this plan's mandate, justified against the +3-stage buff (:284) and the stationary-rematch rule (:224), with the faithful strewn single egg kept the common case and the TAKE/Attack binary faithful to the letter; (2) ALL spawn/despawn numbers (8×8 cells, 25% slot presence, 3-cell despawn, roam cadence 4 — Diglett/Dugtrio at 2); (3) ALL aggro/flee radii and cadences (spot 6 / spook 3 / chase 8 / catch 1 / flee 6; Ride halves chase cadence, making the mount counter-play real); (4) the disposition TABLE (wiki gives examples only; IRRITABLE default + first-forms friendly are synthesis); (5) egg-provocation scope = parents AND egg-group sharers within radius 6; (6) Charm→recruit calm-then-interact (scrapes document Charm as prevention only); (7) Repel ignores roaming mons (inference); (8) the grass/roaming rate balance (none published); (9) evolved-variant surfacing deferred; (10) night ghosts aggressive on SWAMP/FOREST (the soil-dwell ported); (11) white-out hostility drop read as chase→idle on EVERY white-out/escape; (12) transient persistence + the pen-egg sparkle staying the SOLE overworld-shiny visual divergence (wild entities render faithful-silent, :230); (13) the :250 wild-egg BATTLE path dropped (the scrape contradicts itself — :248 Attack-clears vs :250 battling-an-egg; the port ships Attack = shiny-check + clear, NO reachable egg battle, hatch level stays 5); (14) wild mons can spawn inside a fenced pen (pen interiors stay walkable; fresh worlds have no pens, pens stay abstract). POST-REVIEW FIX PASS (2026-07-27): deleted the dead `egg_battle`/`wild_egg_battle_payload` + the unreachable `note_battle_outcome` egg branch and reconciled spec §41/CONTROLS.md/trace-events.md onto the shipped :248 Attack-clears behavior; made `world_entity_audit`'s tile-validity sublane non-vacuous (re-sync at center + an empty-sample loud-fail guard) and added a no-two-mons-share-a-tile guardrail; sim roam/chase/flee now exclude occupied tiles + the player tile (pure given the input script); the `visual_sweep_overworld` nest shot re-derives its window via `note_player_step` (no longer band-luck) and refuses a silent partial pass; vestigial `charm_pacifies` removed (the live gate is `field_move_runtime.gd:254`). Baselines 22/23 stayed byte-identical (0.0 drift). Calibration: verify_all.py GREEN (10 PASS / 0 FAIL / 1 advisory WARN mapping to green); `overworld_mons` 4× double-run stable, `breed_flow`/`shiny_odds` (6/1024) pins hold, all 24 pre-existing committed baselines byte-identical under the one-line activation opt-out (`smoke_scenario_runner.gd:18` — only `{overworld_mons, visual_sweep_overworld(+update)}` run entities active). TECH DEBT carried (out of lane, documented in the scenarios report): `battle_view._run_smoke_battle` waits a fixed 0.2s, so a one-shotting (overleveled) smoke battle leaks the in-flight attack-animator playback at exit — the proper fix is a wall-clock drain, not a frame wait under uncapped headless; the fresh starter save keeps smoke battles non-one-shot so the gate is green.

## Phase 7 — World depth: landmarks, legendaries, world chaining (original features #2, #17)

**New spec**: `docs/product-specs/world-depth.md`. **Subsystem**: extend `world_runtime`; new `landmarks` domain module.

**Pre-Phase-7 suite prerequisites (user-approved FULL deep-dive expansion; built 2026-07, Verify-phase godot confirmation pending)** — the verification suite expanded to pin the interacting-systems determinism surface BEFORE this phase's world-depth work:
- Four new miss-002-compliant scenarios (symmetric `<name>_passed` / `<name>_failed{failures}` markers): `rng_joint_pin` (ONE `seed_for_smoke` seed; a fixed interleaving of encounter draws + fishing casts (fishing shares `game_runtime._rng`) + harvest dig steps (step-pure), asserted byte-stable across two in-scenario runs), `save_stability` (scripted v4-surface mutations — deposit/withdraw, craft, repel_steps, pastures, stone/rod bag → save → reload → save → byte-compare of canonicalized save JSON (key-sorted, ts/version-stripped) + a committed golden v4 fixture `docs/generated/golden-saves/v4_golden.json` whose load + canonical form are asserted stable), `playtest_entity_soak` (a new `playtest_bot_entity.gd` bot band EXTRACTED from the at-320-budget `playtest_bot.gd`, like `playtest_bot_breeding.gd`: steal-egg/provoke-Alpha/charm-recruit/flee-despawn over hundreds of seeded iterations; postconditions — sprite count bounded, y-sort keys never NaN, pending seam never left armed, despawn hygiene, zero `entity_at` on the player tile), and the `visual_sweep_fishing` satellite (shots 26/27, seed 2026072804, fixed Beach water tile via ring-scan, Old Rod through the real resolver, encounter_chance 0, pending seam disarmed at capture).
- New shots 24-30: `24_dusk` (tod≈1080) + `25_night_boundary` (tod=269) in the MAIN day/night group; `28_stone_picker` + `29_party_egg_summary` in the MAIN menu group (ui_render_model expected strings extended); `30_night_roamers` (tod=0, entities ACTIVE) in the overworld satellite. Shot 17 formally RETIRED (camping-reserved, never committed — the sole whitelisted numbering gap). Shot allocation SINGLE-SOURCED in a shot-range registry const in `visual_sweep_baselines.gd` (per-sweep ranges + per-sweep seeds + retired numbers; the satellites' `_foreign_shot` guards derive from it; biome-shots floor ≥3 loud-fail).
- New verify_all lanes: a double-run determinism lane AFTER S6 (six rng consumers — `playtest_journey`, `playtest_soak`, `overworld_mons`, `shiny_odds`, `fishing_flow`, `breed_flow` — twice headless, ts-stripped canonical trace JSONL + payloads compared via a new `determinism_verify.py cmp` verb extending the unwired `cmd_cmp`, scoped from the `smoke_scenario_dispatched` boundary marker (boot rides the wall-clock seed); 90s-bounded runs + 10s compare — the ≤90s TOTAL proved structurally unreachable for six cold-start headless scenarios ×2; miss-002 mismatch payload); S9 gains the four satellite sweep families (shots 15-23 windowed-diffed one command) + the fishing satellite; a per-soak WARNING-COUNT TRIPWIRE (≤ a committed pin file under `docs/generated/`, exceedance RED with the warning list); and a RED sidecar `crafted_state.world_seed`/`shot_seq` equality gate in the `run_playtests` region-gate post-step (`--update` validates the source sidecar BEFORE the baseline rewrite). `visual_sweep_fishing(+_update)` joins PLAYTEST_SCENARIOS / WINDOWED_SUBPROCESS_SCENARIOS / WINDOWED_ONLY_SCENARIOS.
- `seed_for_smoke` (`game_runtime.gd:207`) also pins `player_avatar._rng` (wall-clock previously; `player_avatar.gd:42,47`; trigger draw :205); `boot`/`overworld_step`/`menu_save` gain seed calls.
- Rubric: the five menu-group model-only questions converted to deterministic answerers over sidecar `expected_regions.strings` (existing deterministic kind — no new machinery, no new model questions; the two overworld_mons questions stay flagged with a bank-on-VLM-restoration note).
- Static gates: `check_repo_contracts` gains the no-`RandomNumberGenerator`-in-`*_sim.gd`-setup rule (codifying `overworld_mons_sim.gd:11`) and a shot-numbering completeness check consuming the registry (retired 17 whitelisted).

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

1. **One-command local gate** — **LANDED** (Workstream L.1): `tools/verify_all.py` ORCHESTRATES the existing tools via subprocess (never forks their logic, stdlib-only) — static gates (`check_repo_contracts`, `check_architecture`, `check_quality_docs`, `check_change_contract`) → determinism (`determinism_verify.py pins` + `canary`) → full headless suite (`PLAYTEST_FORCE_HEADLESS=1 run_playtests.py --include-smoke`, `visual_sweep` transport-skipped honestly) → the windowed pixel lanes (`ui_render_audit`, then `visual_sweep` LAST so the stamp-bearing report + freshest shots/vision-review are the final artifacts) → legibility report (generate-only). Run-all by default (full picture, not fast-fail) with four exit codes — 0 GREEN / 1 STEP_FAILURE / 2 REFUSAL (stale/mismatched evidence, never a silent pass) / 3 TOOL_ERROR — precedence TOOL_ERROR > REFUSAL > STEP_FAILURE > GREEN. Refusals R1–R6 mechanize the refuse-on-mismatch + freshness rules (report `head_sha`==HEAD; windowed `godot_version`/`renderer`/`window` vs baseline `capture_env` + canonical window; windowed entries present + correct transport; `ui_render_audit` not headless; `vision-review.json` fresh via `review_is_fresh`). `--skip-windowed` reports the windowed lanes SKIP, never PASS (honest display-less path). Documented as *the* pre-push ritual in RELIABILITY.md § Local gate and AGENTS.md; stays a LOCAL ritual (CI unchanged).
2. **Transport honesty** — **LANDED** (Slice): the runner marks windowed-only scenarios skipped (not failed) under `PLAYTEST_FORCE_HEADLESS`, reporting `19/19 (1 skipped-headless)` rather than a lying `18/19`; `verify_all` relies on this (a transport skip is never a failure).
3. **Artifact freshness** — **LANDED**: `playtest-report.json` carries the HEAD sha (Slice 1 report stamps) and per-scenario `result-*.json` staleness (the stale red `result-visual_sweep.json`) is swept on each run; `verify_all.py` (L.1, landed) REFUSES (exit 2, refusal R1) to certify any report whose `head_sha` is older than HEAD, plus R3 stamp-vs-environment and R6 vision-review freshness refusals.
4. **Lane 4 automation** — **LANDED** (Slice 5): `tools/vision_review.py` drives a reviewer over changed shots after each sweep and writes `.godot-smoke/vision-review.json` per the rubric/schema — fulfilling the oracle spec's "findings file on every sweep" criterion locally; its `review_is_fresh` is the freshness authority `verify_all`'s R6 refusal consumes.
5. **Graduate the pixel lint**: graduation machinery **landed** (Slice 6 of the legibility/vision plan). `tools/graduation_ledger.py` (`record`/`status`/`calibration`) banks each windowed `ui_render_audit` run — head_sha, boot-delimited session identity, per-state finding counts, `text_oracle_passed` payload — into the **committed evidence binder** `docs/generated/graduation-ledger.json`; streaks and flippability are computed from recorded entries, never asserted, and unstamped historical sessions are never backfilled into flip-qualifying streaks. Per-state flips of `GRADUATED_STATES` (`ui_render_audit.gd:16`) proceed on that recorded evidence only — **5 consecutive clean windowed runs at the current HEAD**, in the documented order (battle_moves + battle_item FIRST — ANCHOR glyph-template match; battle_action NEXT — lint cleanliness on ACTION_ROWS; battle_message LAST — BOX mode with a required documented judgment) — and each flip graduates the state's entire pixel lint (glyph + lint findings go red together; the flip changes the harness's tiering, not the game). Calibration rides the same pipeline (the quarantine→graduation loop **is** the free VLM calibration): the first cycle is the baseline with honest zero-denominators; a two-cycle trend needs the next legibility-garden cycle (weekly, Mon 14:00 UTC). An optional `uv` extra (`vision = [scikit-image]`, `tools/vision_metrics.py` SSIM-map corroboration) ships quarantine-forever and never gates CI. Graduate phase **complete** (2026-07-21, HEAD 7b733946): all four battle states flipped on five consecutive clean windowed runs recorded in the ledger (moves + item first, action next, message last with its documented box judgment); the seeded-defect proof went RED via the graduated gate and the same defect class stayed quarantine in a temporarily un-graduated state; calibration cycle 1 committed as the honest zero-denominator baseline. Every phase keeps adding baselines for its new states.
6. **Bot coverage**: the playtest bot gains capabilities as phases land — harvesting (already promised in the harvest design spec), then building, crafting, breeding checks — so `playtest_soak` exercises the new loops at 150-iteration depth. The pre-Phase-7 expansion added the `playtest_entity_soak` band (`playtest_bot_entity.gd`, extracted from the at-budget `playtest_bot.gd` like `playtest_bot_breeding.gd`) looping steal-egg/provoke-Alpha/charm-recruit/flee-despawn at hundreds-of-iterations depth over the Phase-6 entity surface, gated by a committed per-soak warning-count pin.
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
- `tools/verify_all.py` (Workstream L.1, landed) is green on HEAD, with a fresh report stamped with the HEAD sha — mechanized by its R1 refusal, which refuses to certify a report whose `head_sha` ≠ HEAD (never a silent pass).
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

Phase 0 in full (≈6 defects + hygiene) + Workstream L.1–L.3 (`verify_all.py`, transport honesty, artifact freshness — all LANDED: L.2/L.3 via the transport-honest runner and Slice-1 report stamps, L.1 via `tools/verify_all.py`) + the Phase 1 spec written and reviewed. This clears the data-loss bugs, makes the local gate a single command, and sets up the keystone phase without committing its implementation yet.
