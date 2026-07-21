Status: current
Last verified: 2026-07-21
Review cadence days: 21
Source paths: scripts/runtime/battle_runtime.gd, scripts/domain/battle_rules.gd, scripts/domain/battle_status.gd, scripts/domain/battle_text.gd, scripts/domain/type_chart.gd, scripts/domain/pokemon_rules.gd, scripts/ui/battle_view.gd, scripts/ui/battle_surface.gd

# Battle And Capture

## Supported behavior

- A wild battle can start from an encounter tile, playing the wild species' cry and the wild-battle theme.
- Battle presentation uses a native-resolution Crystal-style battle surface that scales to the largest INTEGER factor that fits, centered — fractional scales alias the pixel font.
- Move turns play their source animation sets (per-frame layer scripts, sprite translations, and per-move sound) when one exists for the move — 157 of 299 catalog moves — with a synthesized lunge/flash fallback for the rest; each played animation emits an `attack_animation_played` trace.
- The player may select one of up to four moves, use a Poke Ball, use a Potion, or run.
- The action box uses the baked `battle_screen2.png` command text for `FIGHT`, disabled `PKMN`, `ITEM`, and `RUN`.
- Battle menu selection supports both directional input plus `Z`/`X` and direct mouse clicks.
- HUD name plates show the full species display name when it fits at the battle font, falling back to the base-species first token for long alternate-form names; the `:L` level marker is redrawn dynamically after the measured name width, and a visible status tag reserves its width so level and status never collide.
- Battle sprites render the first frame of the source vertical strip sheets (frame cropping keyed by texture shape), with an intentional `?` placeholder when a species has no sprite art.
- The item box lists bag items single-column, GSC-style, so long item names can no longer overlap a second column.
- Move info text that is too wide for the baked side box's first row (`TYPE/<type>`) drops to the box's second row instead of crossing the border.
- Both HUD name plates show the active status condition (`BRN`/`PSN`/`PAR`/`SLP`/`FRZ`) when one is applied.
- Move mode uses `attack_screen1.png`, shows only learned moves plus `BACK`, and fills the side info box from the existing move `TYPE` and `PP current/max` snapshot data; the player HP bar and numbers stay visible (the name/level plate yields to the side window), and the HUD stays up during move animations.
- Item mode remains the current single-box layout; ball and potion counts reflect the live bag.
- Damage follows the mainline formula with STAB, an 18-type effectiveness chart (Gen VI+, including Fairy), critical hits, accuracy/evasion and stat stages (`-6..+6`), and a burn attack penalty. Turn order uses effective speed with paralysis applied.
- Status conditions are modeled end to end: poison and burn deal end-of-turn damage, paralysis can block movement and quarters speed, sleep lasts 1-3 turns, freeze thaws at 20% per turn. Volatile conditions are modeled too: confusion (2-5 turns, 33% self-hit), infatuation (50% immobilize against opposite gender), and partial trap (2-5 turns of residual damage that blocks escape).
- Move side effects (`effect`/`effect_chance` from the source move data) are applied for the status-hit, stat-stage, multi-hit, recoil, drain, heal, trap, rampage, protect, fury-cutter, encore, attract, and one-hit-KO families; turn order respects priority moves before speed; unhandled effects degrade to a plain hit and emit a `warning` trace with the effect id.
- Capture uses the mainline-style formula with species catch rate, ball modifier, and status bonus; captured Pokemon join the party when there is room. When the party is full, a successful capture is NON-LOSING: the overflow Pokemon is relocated to the player's campsite (a HOLD anchored at the last campsite, defaulting to spawn), the catch is still reported (`caught_box_full`), a `mon_relocated` trace fires with the species and campsite tile, and the Pokemon is retrievable later from the party screen. No Pokemon is ever dropped on a full-party capture.
- Victory awards EXP from the species base-exp yield and may level up the active party member; level-ups apply growth-rate curves and learn moves.
- A level-up that meets an evolution requirement evolves the party member in place (species identity, types, stats rebuilt with HP percentage preserved) and reports `evolved` in the battle response.
- Running ends the battle immediately.
- If the active party member faints, the next healthy party member is sent out. If none remain, the runtime heals the party — restoring HP AND clearing every member's status condition and `sleep_turns` — and returns the player to the origin tile, so a blackout always yields a clean party.

## Intentional limits

- Attack animation playback is a fixed first pass: frames and sounds play, but layer-script coverage may not match every original effect, and 142 moves use the synthesized fallback.
- No abilities, weather, held items, or trainer battles.
- No PC storage-box UI. A full-party capture is non-losing: the overflow Pokemon is held at the player's campsite and retrieved from the party screen (RETRIEVE action). The full storage-box system is a later phase.
- No move learning UI beyond replacing the oldest move when a fifth move would be learned.

## Smoke validation

- `wild_battle` opens a battle, drives the same menu navigation methods used by live input, performs one move if possible, and exits cleanly. It additionally asserts the Phase-0 data-integrity behaviors: a full-party capture relocates the overflow Pokemon to the campsite (party unchanged, `mon_relocated` fired, mon retrievable) instead of losing it, and the defeat/blackout path leaves the party with a clean status (no residual status condition or `sleep_turns` after the heal).
