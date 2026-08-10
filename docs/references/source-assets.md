Status: current
Last verified: 2026-08-09
Review cadence days: 45
Source paths: assets/source/pokemon/pokemon, assets/source/pokemon/moves.asm, assets/source/pokemon/spec_phys_lookup.txt, assets/source/i18n, assets/source/tiles, assets/source/player, assets/source/title_bg1.png, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd, scripts/runtime/player_sprite_frames.gd, assets/data/catalog, tools/import_pokeapi.py, tools/api_data_pin.json

# Source Assets

The checked-in `assets/source/` tree is a vendored snapshot of the upstream PokeWilds project, treated as an imported source-data and content snapshot. Species/move/item DATA is the exception: since the PokeAPI catalog migration it is authoring-time generated into `assets/data/catalog/` (below), not parsed from this tree at runtime.

## Provenance

- Upstream project: `https://github.com/SheerSt/pokewilds`
- Pinned commit: `2e1ad7126e57bd293b5610def7d9dd04e0c555f1` (tag `v0.8.11`)
- Vendored: 2026-08-09 as a full tracked snapshot (commit `5c0c1f9`); the former `pokewilds/` git submodule is gone.

## Re-vendoring

Upstream stays on GitHub. To refresh the snapshot to a new pinned commit:

1. Fresh-clone upstream: `git clone https://github.com/SheerSt/pokewilds /tmp/pokewilds`
2. Replace the tree: `rm -rf assets/source && mkdir -p assets/source`
3. Export exactly the tracked files at the new pin: `git -C /tmp/pokewilds archive <sha> | tar -x -C assets/source`
4. Commit the result, then update the pinned commit in this file's Provenance section and in `THIRD_PARTY.md`.

## Generated Pokémon catalog (runtime source of truth for mon data)

Species, move, and item data are AUTHORING-TIME generated, never parsed at runtime:

- Upstream: `PokeAPI/api-data` (BSD-3-Clause), pinned by SHA in `tools/api_data_pin.json`. This mirrors the original PokeWilds' relationship with its own api-data fork: an offline import, never a runtime dependency.
- `python3 tools/import_pokeapi.py --refresh` fetches the pinned tarball into the gitignored `tools/.cache/` (the dump never enters the repo or the exported game); a plain run regenerates `assets/data/catalog/species.json`, `moves.json`, and `items.json` deterministically; `--check` is the committed-JSON freshness gate, wired into `tools/verify_all.py`'s static section.
- The importer also reads this vendored tree at import time only: each species folder's `wilds_data.asm` supplies the custom fields PokeAPI has no equivalent for (spawn biomes, field moves, overworld behavior, tmhm, dex entry, weight/height), and sprite-folder presence is the species allowlist (no art folder → never imported).
- `scripts/data/pokemon_catalog.gd` loads the three JSON documents at boot with the same dictionary schema and species ids the former ASM walk produced; the runtime never touches api-data.

## Parsed directly by the runtime

- `assets/source/i18n/fieldmove.properties` — field-move display names (the one i18n table the JSON migration does not cover).

## Read at import time only (no runtime consumers)

Formerly parsed by the runtime; since the PokeAPI catalog migration these feed only `tools/import_pokeapi.py` (and remain as upstream source content):

- `assets/source/pokemon/pokemon/*/(base_stats.asm|evos_attacks.asm|egg_moves.asm|wilds_data.asm)`
- `assets/source/pokemon/moves.asm` (the GSC move-effect carry-forward join)
- `assets/source/pokemon/spec_phys_lookup.txt`
- `assets/source/i18n/attack.properties`, `pokemondisplayname.properties`, `item.properties`, `itemdescription.properties` (display-name/description carry-forward)

## Referenced directly by scenes or runtime

- `assets/source/music/*.ogg`
- `assets/source/player/ben-walking.png` + `assets/source/player/ben-running.png` — the LIVE default avatar sheets (since before the title-flow slice; the earlier claim that kris is the default was stale). `player_sprite_frames.build(avatar_name)` (title-flow slice) resolves `res://assets/source/player/<name>-walking.png` + `<name>-running.png` with the fallback chain: requested walk sheet → ben walk → kris walk → null; a missing run sheet falls back to the walk sheet.
- `assets/source/player/kris-walking.png` — the LEGACY fallback in that chain (the pre-avatar-knob hardcoded sheet), kept so a missing requested + ben sheet still renders.
- the full `assets/source/player/` family — all 24 shipped avatar sets (`ben`, `brendan`, `calem`, `chase`, `elaine`, `gloria`, `gold`, `hilbert`, `hilda`, `kate`, `kellyn`, `kris`, `leaf`, `lucas`, `lunick`, `lyra`, `mark`, `may`, `mint`, `nate`, `rosa`, `serena`, `summer`, `victor` — the sorted `AVATARS` const in `scripts/ui/avatar_picker.gd`) became avatar-picker content in the title-flow slice; only `-walking`/`-running` have consumers today, while the `-back`/`-sitting`/`-sleepingbag`/`-fishing` variants follow the identical `<name>-<variant>.png` grammar for future consumers (`player_sprite_frames.gd` header).
- `assets/source/title_bg1.png` — RETIRED as the title background (GBC restyle wave 0): a pixel probe found it 160x144 with 19,200/23,040 px fully transparent — the ONLY content a 160x24 box-outline fragment strip across the top rows, unusable as full-screen art. The vendored file stays untouched; no repo code references it anymore (the title is composed art — the next bullet).
- GBC menu art consumed by the restyled title/creation stages (`scripts/ui/gbc_stage.gd` + `title_screen_stage.gd` / `creation_screen_stage.gd` / `gbc_widgets.gd`): `menu/gsc/background1.png` (160x144 title + creation background), `menu/frame1.png` (creation step dialog), `textbox_bg1.png` / `textbox_bg2.png` (hint band / title entry band), `battle/arrow_right1.png` + `arrow_right_white2.png` (black/white row cursors), and `fonts.ttf` at size 7 (the battle font contract, now shared by every menu label). Every load is guarded with a plate/black-backing degrade.
- `assets/source/i18n/strings.properties` creation keys — `go` ("Go!"), `generating_please_wait` ("Generating... please wait..."), `shiny_rate` ("Shiny Rate"), `name` ("Name"), `player` ("Player"); the creation screen renders these keys' values as its step titles (`scripts/ui/creation_screen.gd`): `shiny_rate`/`name`/`player` UPPERCASED to the house menu style (:181/:185/:189), `go` cited VERBATIM ("Go!", :193), and `generating_please_wait` cited VERBATIM as the GO-step beat line (:30).
- battle sprites and world tiles under `assets/source/pokemon/` and `assets/source/tiles/`
- biome base and prop tiles under `assets/source/tiles/` (water, sand, grass, savanna, desert, swamp, cave, ice, lava, mountain, trees, cacti, flowers, rocks) referenced by `scripts/domain/biome_defs.gd`

## Working rule

Treat `assets/source/` as source content. Port behavior should be documented in repo-local specs and runtime code, not in assumptions about the original libGDX project.
