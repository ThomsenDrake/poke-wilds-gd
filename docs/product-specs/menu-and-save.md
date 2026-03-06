Status: current
Last verified: 2026-03-06
Review cadence days: 21
Source paths: scenes/ui/StartMenu.tscn, scenes/ui/MessageBox.tscn, scripts/ui/start_menu.gd, scripts/ui/message_box.gd, scripts/runtime/game_runtime.gd

# Menu And Save

## Supported behavior

- Pressing `Enter` opens the start menu while the player is not in battle.
- The start menu shows the current party and bag summary.
- The lead slot can be swapped to any selected party member.
- Save writes the current runtime state to `user://godot_port_save.json`.
- New Game resets the session with a new world seed and a starter Pokemon.
- Closing the menu emits a save and returns control to overworld movement.

## Smoke validation

- `menu_save` opens the menu, performs a save, closes the menu, and confirms the menu trace and save trace events.
