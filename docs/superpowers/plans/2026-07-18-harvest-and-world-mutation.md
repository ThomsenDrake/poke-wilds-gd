Status: draft
Last verified: 2026-07-18
Review cadence days: 30
Source paths: docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md, scripts/domain/world_generator.gd, scripts/runtime/world_view.gd, scripts/runtime/game_runtime.gd, scripts/runtime/session_state.gd, scripts/app/main.gd, scripts/ui/start_menu.gd

# Harvest & World Mutation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the world-mutation layer and harvest loop (cut/dig/smash → materials) with per-tile permanent clearing and party-capability field moves, per the approved spec.

**Architecture:** Sparse `Vector2i → override` map applied at the `get_tile_logic` boundary (`docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md`). One runtime `harvest_resolver` serves two triggers (context-Z and the party screen). Save schema v3 persists overrides and drops `unlocked_field_moves`.

**Tech Stack:** Godot 4.6 GDScript, the repo's scenario/audit harness.

## Global Constraints

- GDScript: tabs, snake_case, typed signatures. `scripts/app` + `scripts/ui` < 220 lines, other scripts < 320 lines, `*.tscn` < 250 lines.
- Layer rules per ARCHITECTURE.md: app → app/runtime/ui/core; runtime → runtime/domain/data/core; domain → domain/core.
- Implementers never connect to DAP port 6006; validation is headless: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --check-only -s res://<script>` and scenario runs via `echo '{"scenario":"<name>"}' > .godot-smoke/scenario.json && /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --quit-after <ms>` (scenario.json is consumed per run — recreate each time).
- No git operations by implementers except the per-task commit step shown.
- New scripts are registered in `docs/registry/subsystems.toml` and new trace events in `docs/references/trace-events.md` in the SAME task that creates them.
- Temporary probes and scenario.json leftovers are deleted at the end of every task.

## File Structure

- Create `scripts/domain/world_overrides.gd` — pure override schema + apply + cap.
- Modify `scripts/domain/world_generator.gd` — holds the override map, applies it in `get_tile_logic`, save accessors.
- Create `scripts/domain/field_moves.gd` — per-mon capability rules (flag/type-auto/force-unable).
- Modify `scripts/runtime/game_runtime.gd` — `party_has_field_move_ability`, harvest glue, save/load integration.
- Create `scripts/runtime/harvest_resolver.gd` — action resolution + yields + messages.
- Modify `scripts/runtime/world_view.gd` — surf gating via party capability; cut/smash gates no longer unlock.
- Modify `scripts/runtime/session_state.gd` — save v3 + migrations.
- Modify `scripts/app/main.gd`, `scripts/app/input_router.gd` — context-Z trigger.
- Modify `scripts/ui/start_menu.gd` — FIELD MOVE path invokes the resolver.
- Create `scripts/app/harvest_flow_scenario.gd` — validation scenario.
- Modify `scripts/app/smoke_scenarios.gd` (field_move rework), `scripts/app/world_consistency_audit.gd`, `scripts/app/nav_audit.gd` + `scripts/runtime/smoke_scenario_runner.gd`, `docs/*`, `tools/*` — integration.

---

### Task 1: Override map in the world generator

**Files:**
- Create: `scripts/domain/world_overrides.gd`
- Modify: `scripts/domain/world_generator.gd`
- Modify: `docs/registry/subsystems.toml` (world_runtime code_paths += world_overrides.gd)

**Interfaces:**
- Consumes: existing `WorldGenerator.get_tile_logic(tile) -> Dictionary` (keys: `walkable`, `prop_path`, `encounter`, `requires_field_move`, `block_reason`, `biome`, `tall_grass_path`).
- Produces: `WorldOverrides.apply(logic: Dictionary, override: Dictionary) -> Dictionary`; `WorldGenerator.apply_overrides(overrides: Dictionary) -> void`, `WorldGenerator.overrides_for_save() -> Dictionary`, `WorldGenerator.add_override(tile: Vector2i, kind: String, by: String, step: int) -> bool`, `WorldGenerator.clear_overrides() -> void`. Override entry: `{kind: "cleared"|"dug", by: "cut"|"dig"|"smash", step: int}`. Post-override logic gains `mutated: true`.

- [ ] **Step 1: Write the failing probe.** Temporary SceneTree script `tmp_probe_overrides.gd`: build a `WorldGenerator`, take a seeded tree tile's logic, add an override, assert post-override `walkable == true`, `prop_path == ""`, `mutated == true`, `encounter == false` (for `dug`), and a neighboring tile untouched. Also assert `overrides_for_save()` round-trips the entry and a 10k+1 insert is refused with a warning flag.

- [ ] **Step 2: Implement `world_overrides.gd`.**

```gdscript
extends RefCounted

# Sparse per-tile overrides applied over the deterministic world (spec:
# docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md).

const MAX_OVERRIDES := 10000
const KINDS := ["cleared", "dug"]
const ACTIONS := ["cut", "dig", "smash"]


static func make_entry(kind: String, by: String, step: int) -> Dictionary:
	return {"kind": kind, "by": by, "step": step}


static func is_valid_entry(override: Dictionary) -> bool:
	return KINDS.has(str(override.get("kind", ""))) and ACTIONS.has(str(override.get("by", "")))


static func apply(logic: Dictionary, override: Dictionary) -> Dictionary:
	var out := logic.duplicate(true)
	out["walkable"] = true
	out["prop_path"] = ""
	out["prop_block"] = false
	out["block_reason"] = ""
	out["requires_field_move"] = ""
	out["mutated"] = true
	out["override_kind"] = str(override.get("kind", ""))
	out["override_by"] = str(override.get("by", ""))
	if str(override.get("kind", "")) == "dug":
		out["encounter"] = false
		out["tall_grass_path"] = ""
	return out
```

- [ ] **Step 3: Wire the generator.** In `world_generator.gd`: add `var _overrides := {}`; apply at the END of `get_tile_logic` (`var override: Dictionary = _overrides.get(tile, {}); if not override.is_empty(): logic = WorldOverrides.apply(logic, override)` — preload WorldOverrides at the top); add the four accessors (`add_override` validates kind/by, enforces `MAX_OVERRIDES`, returns false on overflow); `overrides_for_save` returns a `{"x,y": entry}` string-keyed copy; `apply_overrides` accepts that shape, validates entries via `is_valid_entry`, ignores bad ones.

- [ ] **Step 4: Run probe + checks.** Probe passes; `--check-only` both files; `python3 tools/check_architecture.py`; delete the probe.

- [ ] **Step 5: Commit.**

```bash
git add scripts/domain/world_overrides.gd scripts/domain/world_generator.gd docs/registry/subsystems.toml
git commit -m "Add sparse world override map applied at tile-logic boundary"
```

---

### Task 2: Party-capability field moves (replaces the unlock model)

**Files:**
- Create: `scripts/domain/field_moves.gd`
- Modify: `scripts/runtime/game_runtime.gd`, `scripts/runtime/world_view.gd`, `scripts/runtime/session_state.gd` (remove unlock storage only), `scripts/runtime/smoke_scenario_runner.gd` (unlock helpers)
- Modify: `docs/registry/subsystems.toml` (pokemon_progression code_paths += field_moves.gd)

**Interfaces:**
- Consumes: species entry `field_moves` dict (15 flags) and `types`; catalog `get_species` (for surf final-stage check via empty `evolutions`).
- Produces: `FieldMoves.can_perform(mon: Dictionary, move_id: String, get_species: Callable) -> bool`; `FieldMoves.AUTO_TYPES := {"cut": "GRASS", "dig": "GROUND", "power": "ELECTRIC", "smash": "ROCK", "flash": "FIRE", "build": "FIGHTING", "charm": "FAIRY", "repel": "POISON", "attack": "DARK", "teleport": "PSYCHIC"}`; `game_runtime.party_has_field_move_ability(move_id: String) -> bool`; `game_runtime.is_field_move_unlocked` / `unlock_field_move` REMOVED (callers updated in this task — grep first).

- [ ] **Step 1: Write the failing probe.** `tmp_probe_capability.gd`: bulbasaur (GRASS) → cut true, dig false; geodude (ROCK/GROUND) → smash+dig true; a flag-1 mon of a non-auto type → true; a flag-2 mon of an auto type → false; magikarp (WATER, evolves) → surf false; gyarados (WATER, no evolutions) → surf true.

- [ ] **Step 2: Implement `field_moves.gd`.**

```gdscript
extends RefCounted

# Per-mon field-move capability (spec section 1): species flag 1 always able,
# flag 2 force-unable, otherwise the move's auto-ability type decides.

const AUTO_TYPES := {"cut": "GRASS", "dig": "GROUND", "power": "ELECTRIC", "smash": "ROCK", "flash": "FIRE", "build": "FIGHTING", "charm": "FAIRY", "repel": "POISON", "attack": "DARK", "teleport": "PSYCHIC"}


static func can_perform(mon: Dictionary, move_id: String, get_species: Callable) -> bool:
	var id := move_id.strip_edges().to_lower()
	var species: Dictionary = get_species.call(str(mon.get("species_id", "")))
	var flags: Dictionary = species.get("field_moves", {})
	var flag := int(flags.get(id, 0))
	if flag == 2:
		return false
	if flag == 1:
		return true
	if id == "surf":
		return _is_final_water(species)
	var auto := str(AUTO_TYPES.get(id, ""))
	return not auto.is_empty() and (species.get("types", PackedStringArray()) as PackedStringArray).has(auto)


static func _is_final_water(species: Dictionary) -> bool:
	return (species.get("types", PackedStringArray()) as PackedStringArray).has("WATER") and (species.get("evolutions", []) as Array).is_empty()
```

- [ ] **Step 3: Runtime + traversal rewiring.** `game_runtime.gd`: add `party_has_field_move_ability(move_id) -> bool` (iterate `session.party`, `FieldMoves.can_perform`), DELETE `is_field_move_unlocked`/`unlock_field_move` (and their session methods if nothing else uses them — grep). `world_view.gd`: in `is_tile_walkable`, the `requires_field_move` branch now asks `party_has_field_move_ability` (surf is the only remaining traversal gate; cut/smash gates stay blocked until cleared — the unlock path is gone). session_state.gd: remove `unlock_field_move`/`is_field_move_unlocked` and the stored key from `to_save_payload` (migration lands in Task 5). smoke_scenario_runner.gd: delete `set_field_move_unlocked`/snapshot helpers' unlock writes (nav_audit rewires in Task 6).

- [ ] **Step 4: Run probe + regression.** Probe passes; `python3 tools/check_architecture.py`; headless `biome_traverse` may now behave differently (surf gates only) — run it and `nav_audit` and record what changes for Task 6; `--check-only` touched files.

- [ ] **Step 5: Commit.**

```bash
git add scripts/domain/field_moves.gd scripts/runtime/game_runtime.gd scripts/runtime/world_view.gd scripts/runtime/session_state.gd scripts/runtime/smoke_scenario_runner.gd docs/registry/subsystems.toml
git commit -m "Replace stored field-move unlocks with party capability"
```

---

### Task 3: Harvest resolver with yields and trace

**Files:**
- Create: `scripts/runtime/harvest_resolver.gd`
- Modify: `scripts/runtime/game_runtime.gd`
- Modify: `docs/references/trace-events.md` (`field_move_used` payload), `docs/registry/subsystems.toml` (new `harvest_loop` subsystem)

**Interfaces:**
- Consumes: Task 1 `WorldGenerator.add_override/overrides`, Task 2 `party_has_field_move_ability`, `session.add_item`, biome defs prop paths (read them).
- Produces: `HarvestResolver.action_for_tile(logic: Dictionary) -> String` (`"cut"|"dig"|"smash"|""`); `HarvestResolver.resolve(tile: Vector2i, mon_constraint := {}) -> Dictionary` `{ok: bool, move_id, message, yield_item}`; `game_runtime.harvest_tile(tile: Vector2i, mon_constraint := {}) -> Dictionary`; trace `field_move_used` payload `{move_id, tile, yield}`.

- [ ] **Step 1: Write the failing probe.** `tmp_probe_harvest.gd` on a seeded world: tree tile → action "cut"; plains ground → "dig"; rock prop → "smash"; cleared tile → ""; diggable check excludes WATER/ROCK-base/LAVA tiles; resolve grants exactly one item and stamps the override.

- [ ] **Step 2: Implement `harvest_resolver.gd`.**

```gdscript
extends RefCounted

# Single resolver for harvest actions on a faced tile (spec section 3).

const TREE_PROPS := ["tree1.png", "cactus1.png", "tree13.png", "spooky/tree1.png"]
const DIG_BIOME_ITEMS := {"PLAINS": "dry_soil", "GRASSLAND": "dry_soil", "FOREST": "dry_soil", "SAVANNA": "dry_soil", "SWAMP": "dry_soil", "SAND": "dry_sand", "DESERT": "soft_sand"}
const YIELDS := {"cut": "log", "smash": "hard_stone"}


static func action_for_tile(logic: Dictionary) -> String:
	if bool(logic.get("mutated", false)):
		return ""
	var prop := str(logic.get("prop_path", ""))
	for tree_prop in TREE_PROPS:
		if prop.ends_with(tree_prop):
			return "cut"
	if prop.ends_with("rock_small1.png"):
		return "smash"
	if bool(logic.get("walkable", false)) and DIG_BIOME_ITEMS.has(str(logic.get("biome", ""))):
		return "dig"
	return ""


static func yield_for(move_id: String, logic: Dictionary) -> String:
	if move_id == "dig":
		return str(DIG_BIOME_ITEMS.get(str(logic.get("biome", "")), ""))
	return str(YIELDS.get(move_id, ""))
```

Verify the actual prop path suffixes against `biome_defs.gd` before trusting them (rock prop is `rock_small1.png`; trees are `tree1.png` etc.).

- [ ] **Step 3: Runtime glue.** `game_runtime.harvest_tile(tile, mon_constraint := {})`: fetch logic via the world generator, `action_for_tile`; "" → `{ok: false, "message": "There is nothing left here."}`; capability: mon_constraint non-empty → `FieldMoves.can_perform(mon_constraint, ...)` else `party_has_field_move_ability` → false → `{ok: false, "message": block reason + hint}`; success → `add_override(tile, kind, action, session.total_steps)`, `session.add_item(yield)`, emit `field_move_used` `{move_id, tile, yield}`, `{ok: true, move_id, message: "The tree was cut down! Got a log!", yield_item}` (message table per action/yield; dug tile yields named item).

- [ ] **Step 4: Register the `harvest_loop` subsystem** (layer runtime, code_paths harvest_resolver.gd + the game_runtime glue is already registered, spec_doc `docs/product-specs/harvest-and-mutation.md` — created in Task 7, register the row now with validation command for `harvest_flow` scenario arriving in Task 6) and update the `field_move_used` row in trace-events.md to the new payload.

- [ ] **Step 5: Probe + checks + commit.**

---

### Task 4: Interaction wiring — context-Z, party screen, block hints

**Files:**
- Modify: `scripts/app/main.gd`, `scripts/app/input_router.gd`, `scripts/ui/start_menu.gd`, `scripts/runtime/world_view.gd` (hint text), `scripts/runtime/player_avatar.gd` (facing accessor if missing)

**Interfaces:**
- Consumes: Task 3 `game_runtime.harvest_tile`, `player_avatar.facing` (verify name), `world_view.get_traversal_block_reason`.
- Produces: context-Z resolver trigger; start menu FIELD MOVE invokes resolver with the chosen mon; block reasons append ` It could be <MOVE>.` when the gate is harvestable (cut/smash) and ` A SURF-capable Pokemon could cross.` for water.

- [ ] **Step 1: Context-Z.** input_router polls `action_a` when overworld is idle (not menu/battle/animating) via a second callable `_init(on_menu_toggle, on_context_action)`; main.gd `_on_context_action()`: faced tile = `player.tile_position + player.facing`; `game_runtime.harvest_tile(tile)`; show the returned message in the message box. Keep main.gd under 220 lines (lean delegation).
- [ ] **Step 2: Party screen.** start_menu's field-move path now calls the same ctx callable main.gd uses, with the chosen mon passed through the existing `field_move_requested(move_id)` signal → main.gd resolves with `mon_constraint` = the selected party member (main.gd already has the party accessor); failure message "can't use that here." stays a toast. The unlock-era "The way is clear!" toast and `field_move_used` emission from main.gd's old handler are deleted (the resolver emits the trace now).
- [ ] **Step 3: Hints.** `world_view.get_traversal_block_reason`: append the hint strings for gated tiles (surf wording vs harvest wording by gate id).
- [ ] **Step 4: Checks.** `--check-only`; `check_architecture.py`; headless `menu_save` still passes; commit.

---

### Task 5: Save schema v3 + migration

**Files:**
- Modify: `scripts/runtime/session_state.gd`, `scripts/runtime/game_runtime.gd`, `docs/product-specs/menu-and-save.md`

**Interfaces:**
- Consumes: Task 1 save accessors, `save_store`.
- Produces: `SAVE_VERSION := 3`; payload gains `world_overrides`; v1/v2→v3 migration dropping `unlocked_field_moves`; New Game clears overrides.

- [ ] **Step 1: Failing probe.** `tmp_probe_savev3.gd`: write a crafted v2 payload with `unlocked_field_moves: ["cut"]` and no overrides → apply → version 3, key gone, overrides empty, rest intact; apply a v3 payload with two overrides → restored into the generator; New Game → overrides cleared.
- [ ] **Step 2: Implement.** session_state: version bump, `to_save_payload` gains overrides (passed in from game_runtime — check current payload assembly and thread the generator's `overrides_for_save()` through), `apply_loaded_state` drops the old key and calls `game_runtime` glue to `apply_overrides` (cap + warn per spec). game_runtime: `save_game` includes overrides; `ensure_initialized` applies them after load; `new_game` calls `clear_overrides()`.
- [ ] **Step 3: Probe + `menu_save` headless + commit.**

---

### Task 6: Scenarios and suite integration

**Files:**
- Create: `scripts/app/harvest_flow_scenario.gd`
- Modify: `scripts/app/smoke_scenarios.gd` (field_move rework), `scripts/app/world_consistency_audit.gd`, `scripts/app/nav_audit.gd`, `scripts/app/qa_scenarios.gd`, `tools/godot_dap_smoketest.py`, `tools/run_playtests.py`, `docs/registry/subsystems.toml`, `docs/references/trace-events.md`

**Interfaces:**
- Produces: scenario `harvest_flow` + trace `harvest_flow_passed` `{cut_tile, dig_tile, smash_tile, save_ok}`; reworked `field_move` (clearing semantics + save round-trip); override checks in world_consistency_audit; nav_audit gate semantics per Task 2.

- [ ] **Step 1: `harvest_flow` scenario.** Sequence: (a) craft a party with no capable mon (write a save whose lead party mon is a species with no cut/dig/smash capability — e.g. a pure WATER mid-stage — via the scenario's save crafting), attempt context action on a tree → expect refusal + block hint; (b) restore a capable lead (bulbasaur), context-Z the tree → assert `field_move_used {move_id:"cut", yield:"log"}`, bag has 1 log, tile walkable; (c) dig a plains tile → dry_soil + tall grass gone; (d) smash a rock → hard_stone; (e) save, reload overrides from disk via `save_store.load_payload` + `apply_loaded_state`, assert the three tiles still read cleared/dug; emit `harvest_flow_passed`.
- [ ] **Step 2: `field_move` rework** in smoke_scenarios.gd: drive the resolver on a cut tile, assert blocked→cleared + walkable survives the save round-trip; keep the `field_move_scenario_passed` event with updated payload.
- [ ] **Step 3: Audits.** world_consistency_audit: overridden tiles agree across logic/render/collision and appear in `overrides_for_save()`. nav_audit: gate contract now uses party capability (craft party states; surf gate opens with gyarados, stays shut with magikarp; cut gate no longer opens without clearing).
- [ ] **Step 4: Wiring.** qa_scenarios.gd row, smoketest requirements (`harvest_flow`: all `[harvest_flow_passed]`, any session_loaded/created), runner PLAYTEST_SCENARIOS, registry code_paths + `harvest_flow_passed` required event, trace-events.md row.
- [ ] **Step 5: Full headless run of all touched scenarios until green; static checks; commit.**

---

### Task 7: Docs, product spec, and final gate

**Files:**
- Create: `docs/product-specs/harvest-and-mutation.md`
- Modify: `docs/product-specs/bootstrap-and-overworld.md`, `docs/product-specs/menu-and-save.md`, `docs/RELIABILITY.md`, `docs/QUALITY_SCORE.md`, `docs/tech-debt-tracker.md`, `ARCHITECTURE.md` (subsystem list)

- [ ] **Step 1: Write `docs/product-specs/harvest-and-mutation.md`** with repo front matter: mutation model, capability rules, harvest yields table, interaction flow, persistence, validation scenarios.
- [ ] **Step 2: Update the three existing specs** (traversal model now per-tile clearing + passive surf; party-screen field-move path; block-reason hints) and RELIABILITY (harvest_flow row). QUALITY_SCORE gains the `harvest_loop` row; tech-debt marks the global-unlock item resolved.
- [ ] **Step 3: Full gate.** `python3 tools/check_repo_contracts.py && python3 tools/check_architecture.py && python3 tools/check_change_contract.py && python3 tools/check_quality_docs.py && python3 tools/run_playtests.py --include-smoke` — everything green.
- [ ] **Step 4: Commit + push (orchestrator confirms with the user first).**

---

## Self-Review

- **Spec coverage:** Section 1 (override map, capability) → Tasks 1-2; Section 2 (rules/yields) → Task 3; Section 3 (interaction) → Task 4; Section 4 (persistence) → Task 5; Section 5 (validation) → Task 6; product spec/registry/docs → Task 7. Success criteria map to the Task 7 gate.
- **Placeholder scan:** all steps carry code or exact commands; prop-path suffixes and `player_avatar.facing` are marked verify-before-use where they depend on existing internals.
- **Type consistency:** `WorldOverrides.apply/make_entry/is_valid_entry`, `WorldGenerator.add_override/apply_overrides/overrides_for_save/clear_overrides`, `FieldMoves.can_perform`, `party_has_field_move_ability`, `HarvestResolver.action_for_tile/resolve/yield_for`, `game_runtime.harvest_tile(tile, mon_constraint)` are used identically across tasks.
