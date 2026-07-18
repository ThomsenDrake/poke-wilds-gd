Status: current
Last verified: 2026-07-17
Review cadence days: 21
Source paths: scenes/ui/StartMenu.tscn, scenes/ui/PartyScreen.tscn, scenes/ui/BagScreen.tscn, scenes/ui/MessageBox.tscn, scripts/ui/start_menu.gd, scripts/ui/party_screen.gd, scripts/ui/bag_screen.gd, scripts/ui/party_rows.gd, scripts/ui/message_box.gd, scripts/runtime/game_runtime.gd, scripts/runtime/session_state.gd, scripts/runtime/save_store.gd

# Menu And Save

## Supported behavior

- Pressing `Enter` opens the start menu while the player is not in battle.
- The start menu lists `POKEMON`, `BAG`, `SAVE`, `NEW GAME`, and `CLOSE`.
- The party screen lists party members with level, HP bar, and status abbreviation. Selecting a member offers `SWAP LEAD`, a `SUMMARY` panel (types, stats, moves with PP, EXP to next level), an eligible `FIELD MOVE` action, and `CANCEL`.
- A field move action appears only when the species can perform it and the move is not yet unlocked; choosing it emits `field_move_requested`, closes the menu, unlocks that move's traversal gating, and emits a `field_move_used` trace.
- The bag screen lists items with display names, counts, and descriptions. A Potion can be used on a chosen party member to heal 20 HP; unusable items report that they cannot be used here.
- Save writes the current runtime state to `user://godot_port_save.json` in save schema v2 (party, bag, field moves, time of day, total steps); v1 saves migrate on load with defaults.
- New Game resets the session with a new world seed, a starter Pokemon, a starting bag (5 Poke Balls, 3 Potions), and the clock at 10:00.
- Closing the menu emits a save and returns control to overworld movement.
- Transient message boxes yield to battle presentation instead of stacking over the combat UI.

## Smoke validation

- `menu_save` opens the menu, performs a save, closes the menu, and confirms the menu trace and save trace events.
- `field_move` finds a `cut`-gated tile, drives the field-move unlock path, and confirms the tile becomes walkable with the `field_move_used` trace.
