Status: current
Last verified: 2026-07-17
Review cadence days: 14
Source paths: scripts/runtime/battle_runtime.gd, scripts/data/pokemon_catalog.gd, scripts/app/main.gd, scripts/app/smoke_scenarios.gd, scripts/domain/world_generator.gd, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd

# Tech Debt Tracker

## Open items

- 141 of 298 catalog moves have no source animation set and use the synthesized lunge/flash fallback; extend coverage or enrich the fallback.
- Forced moves (rampage/encore) spend PP on the chosen slot rather than the forced move; the domain exposes `forced_move` for a future runtime fix.
- One unreproduced anomaly: a single `visual_sweep` battle shot showed an enemy level of 0 while every code path clamps levels to >= 1 and the encounter trace agreed with the HUD in 3 subsequent runs. Keep an eye on battle HUD level text.
- Field moves unlock traversal globally per move id; the original clears individual tiles. Revisit per-tile clearing when the building/harvesting slice lands.
- Replace remaining dictionary-heavy runtime contracts with more explicit typed boundaries once the gameplay slice stabilizes.
- Add subsystem entries and specs immediately when new systems such as NPCs, PC storage, or building are introduced.

## Resolved this cycle

- Removed the synthetic `SMOKE_MON` fallback: the catalog reliably loads 954 species, and an empty catalog now skips encounters with a `warning` trace instead of fabricating a Pokemon.
- Battle mechanics replaced the simplified damage math with mainline formulas: 18-type effectiveness chart, stat stages, status effects, capture formula with catch rates, growth-curve EXP, and level/item/happiness evolution.
- Encounter tables are species-level, parsed from source `wilds_data.asm` spawn biomes with a source-token alias map; type-based matching remains the fallback.
- Save schema v2 persists the bag, time of day, and step count, with v1 migration on load; the session clock advances per step and drives day/night presentation.
- The start menu grew real party and bag screens with swap-lead, summary, field-move, and item-use flows.
- Player avatar renders from the source walking/running sprite sheets; biome music and the wild-battle theme are wired through the music router.
- Automated playtesting: `playtest_journey` scripts the full player loop with a save round-trip check, and `playtest_soak` runs a seeded bot asserting HP/PP/bag invariants every iteration; `tools/run_playtests.py` executes the suite over DAP or headless and writes a JSON report.
- Visual verification: `visual_sweep` captures 16 screenshots per run. Its first pass caught real defects the trace suite could not: source tile/prop PNGs use white/black backgrounds the original engine color-keyed (now flood-fill keyed at load with caching, composited over per-biome ground colors), sprite-less species could enter battle (now filtered from encounter tables, with an intentional `?` placeholder as backstop), battle message text overflowed into the command box, species names garbled the baked `:L` glyph (level markers now redraw dynamically after measured name width), the moves screen overlapped sprites and HUD plates, the menu dim double-stacked over sub-screens, and bag items showed raw ids (`Poké Ball` now resolves).
- Housekeeping: every smoke scenario now backs up and restores the player's save file (no more test-state clobbering); input routing is extracted into `scripts/app/input_router.gd` so `main.gd` has headroom again; bag item ids are canonical i18n keys (`poke_ball`) with legacy-save migration; the legacy music-router wrappers are deleted.
- Audit suite: `nav_audit` (traversal agreement, battle/menu reachability, model/cursor consistency), `texture_audit` (all 633 battle sprites + 27 overworld textures through the real loaders), `data_audit` (encounter-pool battle viability, instance integrity, bag/catalog resolution), and `layout_audit` (worst-case label fit + cursor alignment) run headlessly in seconds. `visual_sweep` is now deterministic (fixed seed, crafted party with a strip-sprite canary, fixed battle) and diffs against committed baselines via `tools/visual_diff.py` (0.5% pixel threshold; `visual_sweep_update` accepts intentional changes).
- Model-based oracle lanes (spec: docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md): `world_consistency_audit` (tile logic/render/collision three-way plus spatial, z-order, and tall-grass contracts) and `ui_render_audit` (art-anchored expected strings, label overlap, cursor pairs, plus a calibrated pixel lint whose findings are quarantine-tier). The soak asserts per-step spatial invariants. First runs caught and fixed: player drawing over tree canopies (now y-sorted), item-menu two-column text overlap, HUD status/level collision, and wide TYPE values bleeding over the side-box border.
- Agent vision review: `docs/references/vision-review-rubric.md` structures a per-state visual read of every sweep shot; findings land in `.godot-smoke/vision-review.json` (quarantine-tier). First pilot: zero defects, plus one coverage note — no deterministic state yet places the player north of a tall prop, so the canopy contract lacks a pixel canary.
- Battle presentation: attack animations play from the source metadata (157 of 298 moves with sets; synthesized fallback for the rest), species cries sound at battle start and on faint, and the top ten unhandled move-effect families (confusion, heal, trap, rampage, protect, fury cutter, encore, attract, OHKO, priority) are implemented with soak warnings measurably reduced.
- Battle surface scales to the largest integer factor (fractional scales aliased the pixel font at some window sizes), and KO blows now play their animation before the battle screen closes instead of skipping it.
- The player HP bar now stays visible during move selection (name/level yields to the side window) and during attack animations (the source's healthbar-hide metadata is deliberately unhonored since the port's animation frames carry no replacement HUD).
- First audit pass caught and fixed: 5 non-conformant sprite strips (COTTONEE, MINIOR, WHIMSICOTT, two ROTOM backs) that defeated frame detection; sprite-less-data species with zero catch rates or empty learnsets in encounter pools (EGG, GMRMIME, ROTOM forms, CORSOLA_GALARIAN, SHELLOS_*) — eligibility now requires battle viability; `potion` missing from the source i18n (runtime item supplement added); long alternate-form names overflowing the GSC HUD (short-form fallback with measured metrics); moves-screen cursor/row misalignment; the battle font now matches the baked art (source `fonts.ttf` at 7px); tall grass is real patches that own encounters.
