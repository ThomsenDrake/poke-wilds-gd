Status: current
Last verified: 2026-03-06
Review cadence days: 21
Source paths: scenes/app/Main.tscn, scripts/app/main.gd, scripts/runtime/world_view.gd, scripts/runtime/player_avatar.gd, scripts/domain/world_generator.gd

# Boot And Overworld

## Supported behavior

- The app boots into `res://scenes/app/Main.tscn`.
- The autoload runtime initializes source data, session state, and save state before the main scene starts normal play.
- The overworld is rebuilt from the saved seed and centered on the saved player tile.
- The player moves on a 16x16 tile grid with hold-to-move behavior and a faster run modifier on `X`.
- Grass tiles can trigger wild encounters. Water and tree props block movement.

## Input map

- Movement: arrow keys or `WASD`
- Confirm: `Z`
- Cancel / run: `X`
- Start menu: `Enter`

## Smoke validation

- `boot` proves the app reaches a ready state and rebuilds the world.
- `overworld_step` proves the player can take at least one safe step and persist movement state.
