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
4. **Water with a fishing rod** — facing water with a fishing rod in your bag casts the line (see [Fishing](#fishing)); facing the interior of a pen you built picks up an egg there — or takes out the most recently penned Pokémon when there are no eggs (see [Breeding & pens](#breeding--pens)).
5. **Otherwise** — you get a short "There is nothing left here." message.

`Z` does nothing in the overworld while you're in battle, mid-step, in build mode, or while a menu or screen is open.

`Enter` opens the start menu (press it again to close it). Closing the start menu saves the game and shows "Saved."

## Build Mode

Enter build mode by pressing `Z` on open ground with a Build-capable Pokémon, or by choosing the FIELD: Build move from the party screen. You build on the tile you were facing — the target tile is locked in when you enter, and you can't move while building.

- **Cycle structures with the movement keys**: Left or Up = previous, Right or Down = next, wrapping around the full list: wall, door, roof, partition, fence, campfire, storage box, bed, torch, way stone. The wall is selected by default.
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
- **FIELD: \<move\>** — one entry per eligible field move. Build enters build mode with that Pokémon; Cut / Smash / Dig harvest the tile you're facing; **Ride** mounts (and dismounts) a rideable Pokémon for faster travel; **Fly** flies you to the last [way stone](#traversal--utility-field-moves) you registered; using a move where nothing needs it simply says so. (The menu lists only the moves a Pokémon explicitly knows — so Fly and Ride show here for Pokémon that know them. Cut/Smash/Dig and Build also resolve from the overworld `Z` action; Surf and Flash are passive; and Teleport/Repel/Power/Attack/Charm are type-based and don't appear in this menu in the current roster — see [Traversal & utility field moves](#traversal--utility-field-moves).)
- **DEPOSIT** — sends the Pokémon to a storage box. Appears only while you stand next to a placed storage box; if it's refused, the hint line explains why.
- **DROP** — releases the Pokémon into the pen you're standing next to (see [Breeding & pens](#breeding--pens)). Appears only near a fenced pen; you can't drop your last Pokémon, and Eggs always stay with you.
- **RETRIEVE: \<name\>** — takes back the oldest Pokémon held at your campsite. Appears when something is being held and your party has fewer than six.
- **CANCEL**

### Bag (keyboard only)

**Up/Down** selects an item, **`Z`** uses it, **`X`** closes the bag.

- **Potion** opens a party picker: Up/Down chooses the Pokémon (wrapping), `Z` heals 20 HP and consumes one Potion, `X` backs out. Using it on a Pokémon at full HP has no effect ("It would have no effect.") and consumes nothing.
- **Evolution stones** (Fire, Water, Leaf, Moon, Sun, Ice, Dawn, Dusk, and Shiny Stones, plus Thunderstone — one word) open the same party picker: Up/Down chooses the Pokémon (wrapping), `Z` attempts the evolution, `X` backs out. On success the Pokémon evolves in place — the stone is consumed, and a shiny Pokémon stays shiny through the evolution. On a Pokémon it can't evolve it shows "It would have no effect." and consumes nothing, and Eggs are refused. Stones ARE obtainable in normal play: Dig turns them up in several biomes (a Water Stone among the Beach Dig items, faithfully), and a happy Steel-type Pokémon penned in comfort yields a Shiny Stone every few in-game days — see [Differences from the Original PokeWilds](#differences-from-the-original-pokewilds) for exactly which sources are faithful to the original and which are port additions. (Ice and Dawn Stones have no world source yet — the automated suite grants those for now.)
- **Fishing rods** (Old Rod, Good Rod, Super Rod) are used by water — see [Fishing](#fishing).
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
- **Light at night (Flash)** — any Fire-type party member gives your party light at night, lighting the tiles around you out to the same range as a campfire (4 tiles). This is passive — faithful to the original, Flash "can't be selected like Cut"; its overworld effect simply IS the light (see [Traversal & utility field moves](#traversal--utility-field-moves)).
- **Campfire and torch light** — a lit campfire or placed torch within 4 tiles also keeps you in the light. Torches are always lit; a campfire counts as lit unless you extinguished it from the camp menu. Lit campfires and torches glow at night.
- **If you're in the dark at night**, about half of encounters become shadow ghosts — and you cannot run from them. Only victory, capture, or blackout ends the battle.

## Fishing

Fishing rods are crafted at a [campfire](#camp-menu-z-on-a-placed-campfire): **Old Rod** (1 Log + 1 Silky Thread), **Good Rod** (1 Old Rod + 2 Metal Coats), **Super Rod** (1 Good Rod + 3 Magnets).

- Stand on shore **facing water** and press `Z`: if you hold several rods, the BEST one casts automatically (using a rod from the bag does nothing — the overworld `Z` is the only trigger). You do not need a Surf-capable Pokémon — fishing works from land.
- Something doesn't always bite: better rods bite more often (Old about half the time, Super most of the time), and a miss simply settles the water — cast again.
- Better rods also hook better Pokémon: the Old Rod lands only the most common water Pokémon (Magikarp, Tentacool); the Good Rod adds rarer ones (Horsea, Corsola); the Super Rod adds the best (Qwilfish).
- A bite starts a normal wild battle — fight, throw a ball, or run as usual. Repel never wards off a hooked Pokémon, and shiny Pokémon can be hooked just like anywhere else.

## Breeding & pens

- **Build a pen** from fences (a structure in [Build Mode](#build-mode)) — a **completely closed** ring. A ring with a gap or a gate is not a pen (fences block movement; the enclosure is what matters).
- **Drop Pokémon inside**: stand next to the pen and use the party screen's **DROP** action. You can't drop your last Pokémon, and Eggs always stay with you. To take a Pokémon back out, stand next to the pen and press `Z` **facing its interior** — this picks up a ground egg first, or returns the most recently dropped Pokémon to your party (up to six).
- **Habitat makes them happy**: a penned Pokémon is comfortable only if tiles its type likes lie inside the pen OR on the tiles directly outside its fence (solid trees and pond water can't be pen floor, so the game counts the ring around the pen too) — Grass types need tall grass, Flying types need trees, Water types need a pond of deep water, Fire types need lava or a lit campfire, Bug types need flowers, Ice types need snow, Ground types need sand, Rock types need rocks; dual-types need BOTH of their tiles (a Charizard pen needs heat and a tree). Ordinary "basic" types (Normal, Electric, Psychic, and friends) are fine on plain ground. Comfortable Pokémon grow happier over time (once per in-game day); uncomfortable ones simply don't — nothing ever decays, but an uncomfortable Pokémon forfeits its daily drop.
- **Eggs**: two happy, comfortable Pokémon breed when they're a compatible pair — a female with a male of the same egg group, or **Ditto with almost anything breedable**. Genderless and legendary Pokémon cannot breed at all, even with a Ditto — faithful to the original (a flagged constant is the one-edit workaround; see [Differences from the Original PokeWilds](#differences-from-the-original-pokewilds)). Eggs appear inside the pen (at most seven before the pair stops laying). An egg's status screen shows its species, gender, moves, and whether it's shiny — BEFORE it hatches.
- **Hatching**: pick an egg up (it joins your party, taking a slot) and WALK — eggs hatch after enough steps, into a level-5 Pokémon. Egg moves are inherited from the FATHER.
- **Drops**: a happy, comfortable penned Pokémon leaves you a material once per in-game day — by type (Normal → Manure, Bug → Silky Thread, Flying → Soft Feather, and so on; a Miltank leaves Moo Moo Milk). These penned drops are the primary source of crafting materials; winning battles against matching types still yields their material as a secondary source.
- **Shinies**: every Pokémon — wild, hatched, or caught — has a 1 in 256 chance of being shiny. A shiny looks completely normal in the overworld until you battle it (alternate colors + a sparkle) or check its status (a sparkle icon next to its gender) — eggs show the icon before hatching. The odds aren't adjustable in the menu yet.

## Traversal & utility field moves

Beyond harvesting (Cut/Smash/Dig) and building, your party's field moves cover travel and a few overworld tasks. The harvesting moves (Cut/Smash/Dig) and Build resolve from the overworld `Z` context action; the travel moves (Ride, Fly) are chosen from the [party screen](#party-screen-keyboard-only)'s FIELD move list. **Activation reality:** the FIELD list shows only the moves a Pokémon explicitly knows, so in the current roster only Fly and Ride appear there; Surf and Flash are passive (they simply work — see [Passive Abilities](#passive-abilities)); and the type-based moves (Teleport, Repel, Power, Attack, Charm) have working callers but don't surface in the menu — they fire from the FIELD list only if a Pokémon explicitly knows one, and are otherwise exercised by the automated test harness (surfacing them more broadly is tracked as tech debt).

- **Way stones** — a buildable structure (the last entry in the [Build Mode](#build-mode) cycle). Building one registers it as a warp point you can return to. Way stones are the targets of Teleport and Fly.
- **Ride** — mount a rideable Pokémon (FIELD: Ride) to move noticeably faster than running; choose it again (or the dismount action) to get back on foot. Ride speeds up travel only — it does not climb ledges.
- **Fly** — FIELD: Fly flies you straight to the last way stone you registered. You can only fly to way stones you've already reached (registered); a selection menu over your stones is a later addition.
- **Teleport** — return to your registered way stone. (Type-based — Psychic — so it doesn't surface in the FIELD menu for most parties in the current roster; see the activation-reality note above. Reaches way stones within the same world only; traveling between worlds is a later feature.)
- **Repel** — wild encounters stop for a number of steps, then resume. (Type-based — Poison — so it doesn't surface in the FIELD menu for most parties in the current roster; see the activation-reality note above. Simplified from the original, where Repel is a crafted item that only wards off low-level Pokémon.)
- **Power** — shove a boulder one tile out of the way (boulders are the movable rocks, distinct from the cliffs Smash breaks apart). The move is wired, but boulders don't appear in the world yet — they arrive with a later landmark update; until then Power has nothing to act on. (Type-based — Electric — so it doesn't surface in the FIELD menu for most parties in the current roster; see the activation-reality note above.)
- **Flash** — see [Passive Abilities](#passive-abilities): a Fire-type lights the area around you automatically.
- **Attack / Charm** — overworld moves for dealing with wild Pokémon you can see in the field (Attack engages a hostile one; Charm calms a timid one, more reliably at higher levels). The visible overworld Pokémon they act on arrive in a later update; until then these moves have nothing to target.

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
- **Surf and Flash stay passive**: as in the original, a Surf-capable Pokémon simply makes water walkable, and a Fire-type simply lights the area around you (Flash "can't be selected like Cut"). Ride, Fly, Teleport, Repel, and Power are active field moves here (with working callers) — though in the current roster only Fly and Ride surface in the FIELD menu for most parties (see [Traversal & utility field moves](#traversal--utility-field-moves)).
- **Repel** is a field move that wards off all encounters for a number of steps; in the original it is a crafted item (and a Max Repel) that only repels low-level Pokémon.
- **Way stones vs. beacons**: warp points within a world are way stones (the targets of Teleport and Fly). The original's edge-of-world "Teleport Beacons" for traveling between worlds are not in yet.
- **Pens instead of roaming drops**: in the original you drop Pokémon into the overworld and they wander the pen; here penned Pokémon don't roam yet (visible overworld Pokémon arrive in a later update). You drop them into a pen from the party screen, eggs appear inside the pen, and happy penned Pokémon deliver their daily material straight to your bag (no talking to them; the original's "holding an extra item" repeat loop isn't in yet).
- **Genderless & legendary breeding**: faithful to the original — Beldum, Unown, and legendaries cannot breed at all, even with a Ditto. (A flagged constant, `ALLOW_UNDISCOVERED_BREEDING`, is the one-edit workaround if a breedable-genderless pen is ever wanted; the automated suite witnesses the faithful default.)
- **Shinies**: 1 in 256 and invisible in the overworld until battle or status, exactly as the original; the original's promised user-adjustable odds aren't a menu option yet.
- **Fishing tiers are global for now**: rods work exactly as the original (cast by water, better rod → better Pokémon), but the hooked species list is the same in every biome until per-biome fishing tables arrive.
- **Evolution stones — obtaining them (faithful + port additions)**: using them from the bag works — `Z` on a stone opens the party picker and evolves the chosen Pokémon (shiny-safe; no effect consumes nothing). World acquisition is now in, split honestly between what the original documents and what this port adds:
  - **Faithful — Beach Dig → Water Stone.** Dig on the beach (sandy shore tiles) can turn up items alongside the dry sand, and the pool matches the original's Beach "Dig Items" exactly: Big Pearl, Water Stone, Clear Glass, and Revive (Water Stone being the evolution stone in the set). This is the only stone source the original's scrapes document.
  - **Port addition — Dig stones in other biomes.** The original cites no non-Beach stone source, but this port gives Dig a small bonus find in several other biomes so the rest of the stones are reachable: Grassland (Leaf Stone), Forest (Leaf Stone, Moon Stone), Savanna (Fire Stone, Thunderstone), Desert (Sun Stone), and Swamp (Dusk Stone). These biome pools are a deliberate port divergence (flagged as such in the code); plains digging still yields dry soil only. Ice Stone and Dawn Stone have NO world source yet — the snow biome isn't diggable — so the automated suite grants those for now.
  - **Port addition — Steel-type habitat drop → Shiny Stone.** A happy (≥220 friendship), comfortable Steel-type Pokémon penned in suitable habitat yields one Shiny Stone every few in-game days, on top of its daily material. This is also a deliberate port divergence: the original documents Steel-type drops as Metal Coat only (which this port keeps faithfully as the daily material), and the design's "Steel-type drops" note named no stone — so the Shiny Stone choice and the multi-day cadence are port inventions, flagged in the code.
  - Dig's bonus find and the Steel cadence are both deterministic step-counter draws (never the wild-encounter random stream), so the world stays reproducible. The find rate is a port tuning constant even for the faithful Beach pool (the original documents the pool's contents, not a rate).
- **This slice**: the battle menu offers Fight, Item, and Run only (no party switching); Attack and Charm are wired but have no visible overworld Pokémon to act on yet; breeding, shinies, habitat drops, fishing, evolution-stone bag use, AND stone ACQUISITION are in (Phase 5; the faithful Beach-Dig Water Stone plus the flagged port-addition sources above — Ice/Dawn Stones stay grant-only) — with wild egg nests and overworld Pokémon still to come.
