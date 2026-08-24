Status: active
Last verified: 2026-08-24
Review cadence days: 14
Source paths: scripts/data/pokemon_catalog.gd, docs/registry/subsystems.toml, docs/references/source-assets.md, docs/product-specs/bootstrap-and-overworld.md, README.md, tools/verify_all.py

# PokeAPI Catalog Migration

Re-verified 2026-08-24: catalog still loads from `assets/data/catalog/`; `tools/import_pokeapi.py --check` remains the S4.5 static step; source paths above still exist. No runtime-half rollback.

## Goal

Replace runtime ASM/properties parsing with consolidated JSON generated offline from a pinned PokeAPI/api-data upstream checkout — mirroring the original PokeWilds' authoring-time relationship with its api-data fork, but with current data (Gen 9 / Legends Arceus). The runtime catalog schema, species ids, and all downstream consumers stay identical; boot drops the 990-folder ASM walk for three JSON reads.

## Data flow

Authoring time (local only): `tools/import_pokeapi.py` reads a pinned `PokeAPI/api-data` tarball (pin: `tools/api_data_pin.json`; gitignored cache `tools/.cache/`, fetched via `--refresh`), the vendored `assets/source/` tree's `wilds_data.asm` custom fields + sprite-folder presence (the art tree is the species allowlist), and `tools/import_overrides.json` (slug/item id maps, effect carry-forward, the former `RUNTIME_ITEM_SUPPLEMENTS`). It deterministically emits the committed catalog `assets/data/catalog/{species,moves,items}.json` plus reports (`docs/generated/pokeapi-import.md`, `catalog-parity.md` via `--diff-against-asm`). Runtime: `scripts/data/pokemon_catalog.gd` `load_all()` reads the three JSON documents (`FileAccess` + quiet `JSON.new().parse`, the `save_store.gd` fail-soft pattern) and rebuilds the identical dictionary schema; domain/runtime/ui are untouched.

## Execution (two halves, one schema contract)

1. **Importer half (tools/, parallel)**: pin + `--refresh` fetch, slug/id mapping with hard-fail coverage report, `moves.json`/`items.json`/`species.json` emission, `--diff-against-asm` parity mode, and `--check` (committed JSON == regeneration from the pinned cache; non-zero — incl. a missing `tools/.cache` — prints the `--refresh` remedy).
2. **Runtime half (this doc's file set, LANDED 2026-08-09)**: `pokemon_catalog.gd` rewritten as the JSON loader (identical schema + `encounter_species` battle-viable rule over sorted keys, identical `Species catalog load complete.` warning payload `{parsed, skipped, moves, items}`, JSON type re-pinning to the ASM parsers' int/float/PackedStringArray types, additive `held_items`/`abilities` + move `priority`/`target`/`ailment` + item `cost`/`pocket`/`category` pass-through, `RUNTIME_ITEM_SUPPLEMENTS` retired into the importer's overrides); `species_file_parser.gd` + `move_file_parser.gd` deleted (git history preserves them); field-move display names stay runtime-parsed from `assets/source/i18n/fieldmove.properties` (NOT part of the migration); registry/spec/provenance docs updated; `--check` wired into `tools/verify_all.py`'s static section (S4.5, any non-zero = FAIL).

## Validation

- Static gates green on the runtime-half tree: `python3 tools/check_architecture.py` + `python3 tools/check_repo_contracts.py` (registry `code_paths` drop the deleted parsers; `validation_commands` gains `python3 tools/import_pokeapi.py --check`).
- Interim state until the importer half lands: verify_all's new S4.5 step is RED (missing tool/cache/catalog) BY DESIGN — the freshness gate arms the moment `tools/import_pokeapi.py` exists.
- Gate phase (both halves landed): `python3 tools/import_pokeapi.py` regenerate → `python3 tools/verify_all.py` full local gate (determinism, `data_audit`/`texture_audit`/`wild_battle`/`encounter_config`, `save_stability` golden — species ids unchanged, windowed visual sweep). Review `docs/generated/catalog-parity.md` first; accept baselines via `visual_sweep_update` only where learnset churn explains pixel diffs.

## Rollback

Revert the runtime-half commit: the deleted parsers return from git history and `pokemon_catalog.gd` resumes the ASM walk (the vendored `assets/source/` tree is untouched by this plan). The generated catalog JSON is additive and inert without the loader switch.

## Gate results (2026-08-09, gate phase)

Catalog certified at 954 species / 745 moves / 115 items; `import_pokeapi.py --check` green (S4.5). Contract notes all verified empirically (bare UPPERCASE-keyed JSON; lowercase-slug iteration order == old folder sort; Variant evo params with numeric coercion; no level<=0 learnset rows; 954-key parity with the old runtime).

Parity-explained re-pins (all traced to itemized `catalog-parity.md` classes, all via sanctioned flows):
- `visual_sweep_update`: battle PNGs 10/11/12 (learnset churn — DECIDUEYE's crafted moveset now from generated learnsets) + 28_stone_picker (display-name-fallback changed the worst-case fixture's longest name). miss-001 ledger PNG pins re-stamped; the four battle SIDECAR pins deliberately left to the in-flight battle-UI owner (pre-existing red).
- `visual_sweep_pokemon_update`: 21_shiny_battle (encounter-pool growth shifted the wild pick).
- `save_stability_update`: golden save re-pinned (learnset/stat/display-name churn in the crafted party); diff verified data-only.
- `breed_flow_scenario.gd` EGG_MOVE_ID CHARM→WISH (egg-move-churn: CHARM aged out of EEVEE's canon egg list; WISH is in both corpora).
- `playtest_entity_soak_scenario.gd` SOAK_SEED 2026072810→2026072812 (9 newly encounter-eligible species diluted the TIMID roster's share; new pin re-engages all four bands with the legendary witness intact, verified headless + dap).

Bugs found + fixed (scenario hermeticity, both exposed by the gate, both pre-existing classes):
- `playtest_entity_soak_scenario.gd`: the bot's whole-store walk started from the BOOT save's player tile (new_game moves the session tile, not the player node) — the soak's outcome was a function of the leftover user save. One `_runner.teleport_player(...)` to the soak spawn after new_game pins the walk.
- `save_stability_scenario.gd`: the crafted save inherited the boot session's creation identity (player_name/avatar/shiny_odds persist across new_game by design); pinned to the golden's AAA/ben/256.

Remaining REDs (all pre-existing in-flight work, attributed, untouched): dig_silence_scenario.gd registry coverage, 4× miss-001 battle sidecar pin drifts (09/10/11/12), battle_loop change-contract, check_architecture over-budget on field_action_router/battle_rules/creation_screen/party_rows.

NEEDS HUMAN DECISION: `ui_render_audit` windowed fails a graduated `forbidden_ink` quarantine at `Rect2(128,104,24,31)` in `battle_moves` — canon Gen-9 move names (BURNING JEALOUSY, 16 chars vs the old 13-char max) overflow the battle moves panel into the forbidden zone. The fix belongs to battle-UI files (off-limits to the gate): truncate/ellipsize in `battle_surface_layout.gd`, or revisit `ui_render_art.gd` MOVE_FORBIDDEN. Confirmed on the canonical windowed transport (1152x648, forward_plus).

verify_all tail: determinism double-run cmp flaked once (night_cycle pen-relocation insertion; standalone lane rerun x2 GREEN — the advisory-listed wall-clock class, not migration); headless suite 61/61 GREEN with the user save present; all six windowed sweep families + ui_render_audit's headless half green; visual_sweep_overworld needed a DAP-healthy editor (its embedded play window must be 1152x648 — game_embed_mode=Disabled gives the canonical standalone window) and then passed windowed.
