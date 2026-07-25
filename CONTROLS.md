# Controls

Everything you need to play, on one page. The same keys work everywhere — what they do depends on where you are.

## Quick Reference

| Key | Action |
|---|---|
| Arrow keys / `W` `A` `S` `D` | Move (overworld); move the cursor or selection in menus and battle |
| `Z` | Confirm / activate; in the overworld, act on the tile you're facing |
| `X` | Cancel / go back; **hold** to run in the overworld |
| `Enter` | Open (or close) the start menu |
| Left mouse button | Click menu entries and battle options — see [Mouse](#mouse) |

`X` plays two roles: cancel in menus and battle, and hold-to-run in the overworld. These contexts never overlap — while any menu or screen is open, `X` only cancels; with nothing open, holding it makes you run.

## Overworld

- **Move** by holding any direction. You step one tile at a time and automatically face the way you last stepped. Pressing two directions at once moves you horizontally.
- **Run** by holding `X` while you move: steps come about 1.8× faster. Running also slightly lowers the chance of a wild encounter on each step. Whether you're running is checked at the start of each step, so tapping `X` mid-stride takes effect on the next step.
- Every completed step advances the in-game clock by one minute, and the game auto-saves after each step.
- Resting (in a placed bed or with the Sleeping Bag) also advances the clock — a daytime rest passes four hours, a night rest wakes you at 07:00 — and marks your current spot as your campsite, where you return after a blackout. Watch the time: a daytime rest can carry you into nightfall.
- Walking into something impassable shows a short message explaining why, with a hint about what would clear the way.

### `Z`: the context action

In the overworld, `Z` acts on the tile you're facing. The game checks the following in order and does the first thing that applies:

1. **Placed camp objects** — a campfire opens the [camp menu](#camp-menu-z-on-a-placed-campfire); a bed lets you rest; a storage box opens the [storage screen](#storage-screen-z-on-a-placed-storage-box).
2. **Harvestable tiles and built structures** — trees, rocks, and similar are cut, smashed, or dug if a party member knows the right move. Facing a structure **you built** (wall, door, roof, partition, fence, or torch) with a Pokémon that knows Cut — or Smash for stone-built structures — demolishes it and **refunds every material** it cost. A storage box holding Pokémon can't be demolished until it's empty.
3. **Open ground with a builder** — if the faced tile is walkable and your party has a Pokémon that knows Build (Fighting types), you enter [Build Mode](#build-mode).
4. **Otherwise** — you get a short "There is nothing left here." message.

`Z` does nothing in the overworld while you're in battle, mid-step, in build mode, or while a menu or screen is open.

`Enter` opens the start menu (press it again to close it). Closing the start menu saves the game and shows "Saved."

## Build Mode

Enter build mode by pressing `Z` on open ground with a Build-capable Pokémon, or by choosing the FIELD: Build move from the party screen. You build on the tile you were facing — the target tile is locked in when you enter, and you can't move while building.

- **Cycle structures with the movement keys**: Left or Up = previous, Right or Down = next, wrapping around the full list: wall, door, roof, partition, fence, campfire, storage box, bed, torch. The wall is selected by default.
- A ghost preview shows whether the spot works: **white** = placeable, **magenta** = not, along with a hint of the materials you have versus what's needed. A door placed beside a fence previews as a gate.
- **`Z`** places the selected structure. Success exits build mode; if placement is refused, the reason is shown and the mode stays open so you can try again.
- **`X`** exits without placing anything.

Either way you leave, your movement returns and the game saves.

## Battle

- **Arrow keys / WASD** move the arrow cursor between options.
- **`Z`** activates the highlighted option:
  - **FIGHT** opens the move list — pick a move and press `Z` to use it; `X` (or clicking empty space) returns to the main menu; there is no BACK row here. Moves with 0 PP are greyed out and can't be picked.
  - **ITEM** opens the item list — Poké Ball, Potion, or BACK. Entries with a count of 0 are greyed out and can't be picked.
  - **RUN** attempts to flee the battle.
- **`X`** backs out of any submenu to the main action menu. `X` on the main menu does nothing.
- **Mouse**: left-click an option to select and activate it in one go; click empty space to back out of a submenu.
- Input is briefly locked while a turn animation plays.
- **You can't always run:** at night, if you have no light, some encounters are shadow ghosts that refuse to let you flee — those battles end only by victory, capture, or blackout (see [Passive Abilities](#passive-abilities)).

## Menus

### Start Menu (`Enter` in the overworld)

Entries: **POKEMON**, **BAG**, **SAVE**, **NEW GAME**, **CLOSE**.

- **Up/Down** moves the selection (it wraps around). **`Z`** activates the selected entry. **`X`** or **`Enter`** closes the menu. Clicking an entry activates it too.
- **SAVE** saves the game — and closing the menu saves as well ("Saved.").
- **NEW GAME** asks you to confirm — "Start a new game? Your current save will be erased." — with **`Z` = yes** and **`X` = no**.

### Party Screen (keyboard only)

**Up/Down** picks a party member (wraps), **`Z`** opens their action menu, and **`X`** closes the screen.

Actions:

- **SWAP LEAD** — make this Pokémon the lead. Always available.
- **MOVE** — reorder the party (only with two or more Pokémon): Up/Down live-swaps the member with wrap-around, **`Z`** commits the new order, and **`X`** cancels and restores the original order.
- **SUMMARY** — shows stats; `Z` or `X` returns to the action menu.
- **FIELD: \<move\>** — one entry per eligible field move. Build enters build mode with that Pokémon; Cut / Smash / Dig harvest the tile you're facing; using a move where nothing needs it simply says so.
- **DEPOSIT** — sends the Pokémon to a storage box. Appears only while you stand next to a placed storage box; if it's refused, the hint line explains why.
- **RETRIEVE: \<name\>** — takes back the oldest Pokémon held at your campsite. Appears when something is being held and your party has fewer than six.
- **CANCEL**

### Bag (keyboard only)

**Up/Down** selects an item, **`Z`** uses it, **`X`** closes the bag.

- **Potion** opens a party picker: Up/Down chooses the Pokémon (wrapping), `Z` heals 20 HP and consumes one Potion, `X` backs out. Using it on a Pokémon at full HP has no effect ("It would have no effect.") and consumes nothing.
- **Sleeping Bag** rests the party anywhere — a reusable key item that is never consumed. Unlike a bed (full heal, cures status, revives fainted), the bag only restores about half of each member's max HP — reviving fainted members to half — and does not cure status. Resting also skips time (see [Overworld](#overworld)).
- Any other item can't be used here.

### Camp Menu (`Z` on a placed campfire)

- Rows list craftable recipes with have/need material counts; recipes you're short on are greyed out.
- **Up/Down** selects (wraps), **`Z`** acts, and **`X`** or **`Enter`** closes the menu. Clicking an entry activates it too.
- **Crafting** consumes the materials and grants the result, then saves.
- **Extinguish / Light** toggles the fire — an extinguished campfire gives no light at night.
- **Demolish** tears down the campfire and refunds its materials.

Closing the menu re-enables your movement and saves.

### Storage Screen (`Z` on a placed storage box)

Two columns: the box and your party (shown as n/6). **Up/Down** moves within a column (wraps); **Left/Right** switches columns.

- **`Z`** opens the action list for the highlighted side:
  - Box side: **WITHDRAW**, **RELEASE**, **SUMMARY**, **CANCEL**
  - Party side: **DEPOSIT**, **SUMMARY**, **CANCEL**
- **WITHDRAW / DEPOSIT** move the Pokémon right away, save, and return to browsing.
- **RELEASE** is confirm-gated: "Release \<name\>? It will be gone for good." — **`Z` = yes** (permanent), **`X` = no**.
- **SUMMARY** shows stats; `Z` or `X` returns to the action list.
- **`X`** backs out one level: from the action list to browsing, and from browsing it closes the screen. Closing the screen saves.

### Confirm dialogs

Whenever a confirm box appears — new game, release — it shows "(Z: Yes   X: No)". **`Z` confirms, `X` cancels**, and while the confirm is up, `Z` and `X` belong to it.

One general rule: **the press that closes a menu, confirms a choice, or ends a battle does nothing else in that moment** — so the `Enter` that closes the camp menu won't pop the start menu back open, and the `Z` that captures a Pokémon won't also act on the tile in front of you.

## Passive Abilities

Some party abilities simply work, with no keypress:

- **Water crossing (Surf)** — if your party contains a Surf-capable Pokémon (a fully evolved Water type), water tiles are walkable, no action needed. Otherwise water stops you, with a hint that a Surf-capable Pokémon could cross.
- **Light at night (Flash)** — any Fire-type party member gives your party light at night. This is passive — there is no Flash move to use.
- **Campfire and torch light** — a lit campfire or placed torch within 4 tiles also keeps you in the light. Torches are always lit; a campfire counts as lit unless you extinguished it from the camp menu. Lit campfires and torches glow at night.
- **If you're in the dark at night**, about half of encounters become shadow ghosts — and you cannot run from them. Only victory, capture, or blackout ends the battle.

## Mouse

The mouse is optional and works in a few places:

- **Start Menu** — left-click an entry to activate it.
- **Camp Menu** — left-click an entry to activate it.
- **Storage Screen** — left-click an entry in an action list (clicks are ignored while a release confirm is open).
- **Battle** — left-click an option to select and activate it; click empty space to back out of a submenu.

Keyboard only: the party screen, the bag item list, and confirm dialogs (`Z` / `X`).

## Differences from the Original PokeWilds

- **Build cycle keys**: the original cycled structures with the L/R shoulder buttons; here the **movement keys** cycle (Left/Up previous, Right/Down next), with `Z` to place and `X` to exit.
- **One key, two jobs**: `X` handles both cancel and run (separate buttons in the original); the two never apply at once.
- **Night ghost battles**: the original held you "until dawn"; here the clock stands still during battles, so a ghost battle lasts until you win, capture, or black out.
- **Release is permanent** right now — a released Pokémon does not appear in the overworld.
- **This slice**: the battle menu offers Fight, Item, and Run only (no party switching), and Surf and Flash exist as passive abilities rather than moves you trigger in the field.
