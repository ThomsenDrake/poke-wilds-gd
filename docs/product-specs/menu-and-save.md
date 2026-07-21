Status: current
Last verified: 2026-07-21
Review cadence days: 21
Source paths: scenes/ui/StartMenu.tscn, scenes/ui/PartyScreen.tscn, scenes/ui/BagScreen.tscn, scenes/ui/MessageBox.tscn, scripts/ui/start_menu.gd, scripts/ui/party_screen.gd, scripts/ui/bag_screen.gd, scripts/ui/party_rows.gd, scripts/ui/message_box.gd, scripts/runtime/game_runtime.gd, scripts/runtime/session_state.gd, scripts/runtime/save_store.gd

# Menu And Save

## Supported behavior

- Pressing `Enter` opens the start menu while the player is not in battle.
- The start menu lists `POKEMON`, `BAG`, `SAVE`, `NEW GAME`, and `CLOSE`.
- The party screen lists party members with level, HP bar, and status abbreviation. Selecting a member offers `SWAP LEAD`, a `SUMMARY` panel (types, stats, moves with PP, EXP to next level), an eligible `FIELD MOVE` action, and `CANCEL`. When the campsite hold is non-empty and the party has room, the screen also offers a `RETRIEVE` action that pulls the oldest campsite-held Pokemon into the party and emits a `mon_retrieved` trace.
- A field move action appears for species-flag-eligible moves; choosing it closes the menu and resolves the harvest on the faced tile with that Pokemon ("X can't use that here." on failure). Overworld `Z` resolves with any capable party member. See [harvest-and-mutation.md](harvest-and-mutation.md).
- The bag screen lists items with display names, counts, and descriptions. A Potion can be used on a chosen party member to heal 20 HP; unusable items report that they cannot be used here.
- Save writes the current runtime state to `user://godot_port_save.json` in save schema v3 (party, bag, time of day, total steps, world overrides from harvesting, and the campsite hold — anchor tile plus held Pokemon). Writes are ATOMIC: the payload is written to a `.tmp` file and renamed over the live save, so a crash mid-write leaves the previous save intact; a failed rename emits a `warning` and keeps the old file. On load, a corrupt save is preserved to `.corrupt.bak` and a fresh start is recovered with a `save_recovery` trace (never silently); an absent save recovers the same way at event tier. A save whose `version` is newer than supported is REFUSED non-destructively: the file is renamed to `.newer.bak` and a `warning` fires BEFORE the runtime starts fresh, so the per-step autosave can never overwrite the newer save. v1/v2 saves migrate on load (additive backfill), dropping the legacy `unlocked_field_moves` key.
- Runtime audio is two services: the music router (biome and battle tracks) and the cry player (species cries keyed by dex number at battle start and on faint, with a warning trace for missing files).
- New Game is confirm-gated: choosing `NEW GAME` opens a message-box confirm (`Z` yes / `X` no). Confirming resets the session with a new world seed, a starter Pokemon, a starting bag (5 Poke Balls, 3 Potions), and the clock at 10:00, then CLOSES the menu; cancelling leaves the menu open. The reset (and its save wipe) is never applied without an explicit confirm.
- Closing the menu emits a save and returns control to overworld movement.
- Transient message boxes yield to battle presentation instead of stacking over the combat UI.

## Smoke validation

- `menu_save` opens the menu and drives the New Game confirm flow on both branches — cancel leaves the confirm box down, the menu open, and the existing save intact (no `session_created` since the cursor), and confirming starts a new game (`session_created`) and closes the menu. The SAVE-entry save-on-close path is exercised by `playtest_journey`, not this scenario.
- `field_move` finds a `cut`-gated tile, drives the party-capability field-move flow (species flags + type auto-ability; there is no stored unlock state), and confirms the tile becomes walkable with the `field_move_used` trace.
- `save_migration` writes v1 and v2 fixtures plus a future-version fixture to the live save path (inside the runner's backup/restore guard) and drives the runtime's real load path: it asserts v1→v3 and v2→v3 field migration (legacy item id remap, dropped `unlocked_field_moves`, backfilled stats/fields), the non-destructive refusal of the future version (empty payload, `.newer.bak` preserved with its contents intact, version-refusal `warning`), and emits `save_migration_passed`; it cleans up its `.newer.bak`/`.corrupt.bak`/`.tmp` artifacts so no fixture state leaks into sibling scenarios. `save_recovery` covers the corrupt/absent recovery path.
- `ui_render_audit` covers the start menu, party, and bag screens against the art-anchored render model.
