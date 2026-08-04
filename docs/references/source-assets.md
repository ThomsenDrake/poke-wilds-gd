Status: current
Last verified: 2026-08-04
Review cadence days: 45
Source paths: pokewilds/pokemon/pokemon, pokewilds/pokemon/moves.asm, pokewilds/pokemon/spec_phys_lookup.txt, pokewilds/i18n, pokewilds/tiles, pokewilds/player, pokewilds/title_bg1.png, scripts/domain/biome_defs.gd, scripts/domain/biome_encounters.gd, scripts/runtime/player_sprite_frames.gd

# Source Assets

The checked-in `pokewilds/` subtree is treated as an imported source-data and content snapshot.

## Parsed directly by the runtime

- `pokewilds/pokemon/pokemon/*/(base_stats.asm|evos_attacks.asm)`
- `pokewilds/pokemon/moves.asm`
- `pokewilds/pokemon/spec_phys_lookup.txt`
- `pokewilds/i18n/attack.properties`
- `pokewilds/i18n/pokemondisplayname.properties`

## Referenced directly by scenes or runtime

- `pokewilds/music/*.ogg`
- `pokewilds/player/ben-walking.png` + `pokewilds/player/ben-running.png` — the LIVE default avatar sheets (since before the title-flow slice; the earlier claim that kris is the default was stale). `player_sprite_frames.build(avatar_name)` (title-flow slice) resolves `res://pokewilds/player/<name>-walking.png` + `<name>-running.png` with the fallback chain: requested walk sheet → ben walk → kris walk → null; a missing run sheet falls back to the walk sheet.
- `pokewilds/player/kris-walking.png` — the LEGACY fallback in that chain (the pre-avatar-knob hardcoded sheet), kept so a missing requested + ben sheet still renders.
- the full `pokewilds/player/` family — all 24 shipped avatar sets (`ben`, `brendan`, `calem`, `chase`, `elaine`, `gloria`, `gold`, `hilbert`, `hilda`, `kate`, `kellyn`, `kris`, `leaf`, `lucas`, `lunick`, `lyra`, `mark`, `may`, `mint`, `nate`, `rosa`, `serena`, `summer`, `victor` — the sorted `AVATARS` const in `scripts/ui/avatar_picker.gd`) became avatar-picker content in the title-flow slice; only `-walking`/`-running` have consumers today, while the `-back`/`-sitting`/`-sleepingbag`/`-fishing` variants follow the identical `<name>-<variant>.png` grammar for future consumers (`player_sprite_frames.gd` header).
- `pokewilds/title_bg1.png` — the title screen background art (160x144), referenced by `scenes/ui/TitleScreen.tscn` (title-flow slice).
- `pokewilds/i18n/strings.properties` creation keys — `go` ("Go!"), `generating_please_wait` ("Generating... please wait..."), `shiny_rate` ("Shiny Rate"), `name` ("Name"), `player` ("Player"); the creation screen renders these keys' values as its step titles (`scripts/ui/creation_screen.gd`): `shiny_rate`/`name`/`player` UPPERCASED to the house menu style (:181/:185/:189), `go` cited VERBATIM ("Go!", :193), and `generating_please_wait` cited VERBATIM as the GO-step beat line (:30).
- battle sprites and world tiles under `pokewilds/pokemon/` and `pokewilds/tiles/`
- biome base and prop tiles under `pokewilds/tiles/` (water, sand, grass, savanna, desert, swamp, cave, ice, lava, mountain, trees, cacti, flowers, rocks) referenced by `scripts/domain/biome_defs.gd`

## Working rule

Treat `pokewilds/` as source content. Port behavior should be documented in repo-local specs and runtime code, not in assumptions about the original libGDX project.
