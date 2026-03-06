Status: current
Last verified: 2026-03-06
Review cadence days: 21
Source paths: scripts/runtime/battle_runtime.gd, scripts/domain/battle_rules.gd, scripts/domain/pokemon_rules.gd, scripts/ui/battle_view.gd

# Battle And Capture

## Supported behavior

- A wild battle can start from an encounter tile.
- The player may select one of up to four moves, use a Poke Ball, use a Potion, or run.
- Damage uses a simplified physical/special split and accuracy roll.
- Running ends the battle immediately.
- Captures add the wild Pokemon to the party when there is room, otherwise the capture result is reported without party insertion.
- Victory awards EXP and may level up the active party member.
- If the active party member faints, the next healthy party member is sent out. If none remain, the runtime heals the party and returns the player to the origin tile.

## Intentional limits

- No status effects, abilities, weather, or full Gen accuracy yet.
- No PC storage when the party is full.
- No move learning UI beyond replacing the oldest move when a fifth move would be learned.

## Smoke validation

- `wild_battle` opens a battle, performs one move if possible, and exits cleanly.
