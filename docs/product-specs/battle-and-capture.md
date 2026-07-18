Status: current
Last verified: 2026-07-17
Review cadence days: 21
Source paths: scripts/runtime/battle_runtime.gd, scripts/domain/battle_rules.gd, scripts/domain/battle_status.gd, scripts/domain/battle_text.gd, scripts/domain/type_chart.gd, scripts/domain/pokemon_rules.gd, scripts/ui/battle_view.gd, scripts/ui/battle_surface.gd

# Battle And Capture

## Supported behavior

- A wild battle can start from an encounter tile.
- Battle presentation uses a native-resolution Crystal-style battle surface that scales to the largest centered fit while preserving aspect ratio.
- The player may select one of up to four moves, use a Poke Ball, use a Potion, or run.
- The action box uses the baked `battle_screen2.png` command text for `FIGHT`, disabled `PKMN`, `ITEM`, and `RUN`.
- Battle menu selection supports both directional input plus `Z`/`X` and direct mouse clicks.
- HUD name plates show the full species display name when it fits at the battle font, falling back to the base-species first token for long alternate-form names; the `:L` level marker is redrawn dynamically after the measured name width.
- Battle sprites render the first frame of the source vertical strip sheets (frame cropping keyed by texture shape), with an intentional `?` placeholder when a species has no sprite art.
- Both HUD name plates show the active status condition (`BRN`/`PSN`/`PAR`/`SLP`/`FRZ`) when one is applied.
- Move mode uses `attack_screen1.png`, shows only learned moves plus `BACK`, and fills the side info box from the existing move `TYPE` and `PP current/max` snapshot data.
- Item mode remains the current single-box layout; ball and potion counts reflect the live bag.
- Damage follows the mainline formula with STAB, an 18-type effectiveness chart (Gen VI+, including Fairy), critical hits, accuracy/evasion and stat stages (`-6..+6`), and a burn attack penalty. Turn order uses effective speed with paralysis applied.
- Status conditions are modeled end to end: poison and burn deal end-of-turn damage, paralysis can block movement and quarters speed, sleep lasts 1-3 turns, freeze thaws at 20% per turn. Move side effects (`effect`/`effect_chance` from the source move data) are applied for the status-hit, stat-stage, multi-hit, recoil, and drain families; unhandled effects degrade to a plain hit and emit a `warning` trace with the effect id.
- Capture uses the mainline-style formula with species catch rate, ball modifier, and status bonus; captured Pokemon join the party when there is room, otherwise the capture result is reported without party insertion.
- Victory awards EXP from the species base-exp yield and may level up the active party member; level-ups apply growth-rate curves and learn moves.
- A level-up that meets an evolution requirement evolves the party member in place (species identity, types, stats rebuilt with HP percentage preserved) and reports `evolved` in the battle response.
- Running ends the battle immediately.
- If the active party member faints, the next healthy party member is sent out. If none remain, the runtime heals the party and returns the player to the origin tile.

## Intentional limits

- No attack animations or per-move sound effects yet (the source animation metadata is parsed in a later slice).
- No abilities, weather, held items, or trainer battles.
- No PC storage when the party is full.
- No move learning UI beyond replacing the oldest move when a fifth move would be learned.

## Smoke validation

- `wild_battle` opens a battle, drives the same menu navigation methods used by live input, performs one move if possible, and exits cleanly.
