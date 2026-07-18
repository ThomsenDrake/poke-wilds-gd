Status: draft
Last verified: 2026-07-18
Review cadence days: 30
Source paths: docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md, scripts/app/qa_scenarios.gd, scripts/runtime/playtest_bot.gd, tools/run_playtests.py

# Autonomous Playtesting Oracles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add model-based oracles (world consistency, UI render model, soak spatial invariants, agent vision review) to the playtesting suite so collision and garbled-text bug classes turn the suite red without manual reporting.

**Architecture:** Per the approved spec at `docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md`. New scenario scripts dispatch through the existing `scripts/app/qa_scenarios.gd` table; expectations anchor to external truth (world data, baked art, font metrics), never to the game's layout code. Two-tier failure policy: deterministic oracles are hard gates, heuristic pixel checks start quarantined.

**Tech Stack:** Godot 4.6 GDScript, Python 3 stdlib, the repo's DAP/headless scenario harness.

## Global Constraints

- GDScript: tabs, snake_case, typed signatures. `scripts/app` + `scripts/ui` < 220 lines, other scripts < 320 lines, `*.tscn` < 250 lines.
- Layer rules per ARCHITECTURE.md: app → app/runtime/ui/core; runtime → runtime/domain/data/core.
- No git operations by task implementers EXCEPT the per-task commit step shown.
- Implementers never connect to DAP port 6006; validation is headless: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --check-only -s res://<script>` and scenario runs via `echo '{"scenario":"<name>"}' > .godot-smoke/scenario.json && /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --quit-after <ms>` (scenario.json is consumed on read — recreate per run).
- Every new script/scene must be registered in `docs/registry/subsystems.toml` (app_bootstrap) and every new trace event in `docs/references/trace-events.md` in the SAME task that creates it.
- The dispatcher backs up/restores the player save around every scenario; audits must not add their own backup logic.
- Delete temporary probes and `.godot-smoke/scenario.json` leftovers at the end of every task.

## File Structure

- Create `scripts/app/world_consistency_audit.gd` — Lane 1 scenario (tiles, movement probes, spatial, z-order, tall-grass alignment). Entry `run(ctx)`.
- Modify `scripts/runtime/world_view.gd` — add texture accessors the audit compares against (`get_tile_base_texture`, `get_tile_prop_texture`) and y-sort rendering (Task 2 game fix).
- Modify `scripts/runtime/player_avatar.gd` — expose `world_rect()`.
- Modify `scripts/runtime/smoke_scenario_runner.gd` — shared sampling helpers if reused.
- Create `scripts/app/ui_render_model.gd` — Lane 2 expected-region model from baked art + data + font metrics.
- Create `scripts/app/ui_render_audit.gd` — Lane 2 scenario (scene-tree half + pixel half). Entry `run(ctx)`.
- Create `tools/visual_lint.py` — region ink density, forbidden zones, row-band garble profile.
- Modify `scripts/runtime/playtest_bot.gd` — per-step spatial invariants + payload counts.
- Create `docs/references/vision-review-rubric.md` — Lane 4 rubric.
- Modify `docs/RELIABILITY.md`, `docs/registry/subsystems.toml`, `docs/references/trace-events.md`, `tools/godot_dap_smoketest.py`, `tools/run_playtests.py` — integration.

---

### Task 1: World consistency audit — tile three-way check

**Files:**
- Create: `scripts/app/world_consistency_audit.gd`
- Modify: `scripts/runtime/world_view.gd` (add 2 accessors)
- Modify: `scripts/app/qa_scenarios.gd` (table row)
- Modify: `tools/godot_dap_smoketest.py` (requirements entry)
- Modify: `docs/registry/subsystems.toml`, `docs/references/trace-events.md`

**Interfaces:**
- Consumes: `SmokeScenarioRunner.ring_around(center, radius)`, `stand_spot`, `even_samples`, `teleport_player`; `world_view.get_tile_logic`-equivalent via `runtime._world_gen.get_tile_logic(tile) -> Dictionary` (keys: `walkable`, `biome`, `prop_path`, `requires_field_move`, `encounter`); `world_view.is_tile_walkable(tile) -> bool`; `player_avatar.smoke_step(dir) -> bool`, `player_avatar.tile_position`, `player_avatar.tile_changed` signal.
- Produces: scenario `world_consistency_audit`; trace `world_consistency_audit_passed` (source `SmokeScenarios`, payload `{tiles_checked, movement_checked, failures}`). `world_view.get_tile_base_texture(tile: Vector2i) -> Texture2D`, `world_view.get_tile_prop_texture(tile: Vector2i) -> Texture2D` (null when none).

- [ ] **Step 1: Add the world_view texture accessors.** In `scripts/runtime/world_view.gd`, after the existing tile-node creation path (find where `_ensure_tile_nodes` stores per-tile nodes), add:

```gdscript
func get_tile_base_texture(tile: Vector2i) -> Texture2D:
	var tile_data: Dictionary = _tiles.get(tile, {})
	if tile_data.is_empty():
		return null
	return _texture_cache.base_texture(tile_data)


func get_tile_prop_texture(tile: Vector2i) -> Texture2D:
	var tile_data: Dictionary = _tiles.get(tile, {})
	if str(tile_data.get("prop_path", "")).is_empty():
		return null
	return _texture_cache.prop_texture(tile_data)
```

Adjust member names (`_tiles`, `_texture_cache`) to the actual ones in the file — read it first. If the view does not cache tile data per tile, fall back to `_world_gen.get_tile_logic(tile)` for the data (the world generator is already a member).

- [ ] **Step 2: Parse-check + register the accessors.**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --check-only -s res://scripts/runtime/world_view.gd`
Expected: exit 0, no errors.

- [ ] **Step 3: Write the audit scenario.** Create `scripts/app/world_consistency_audit.gd`:

```gdscript
extends Node

# Lane 1 of the autonomous oracle suite (spec: docs/superpowers/specs/
# 2026-07-18-autonomous-playtesting-oracles-design.md). For sampled tiles the
# logic dict, the rendered texture, and the collision answer must agree.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")

const SAMPLE_RADIUS := 20
const SAMPLES_PER_BIOME := 8

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _tex_cache = TileTextureCache.new()
var _failures: Array = []
var _tiles_checked := 0
var _movement_checked := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var biomes_seen := {}
	for radius in range(2, SAMPLE_RADIUS, 4):
		for tile in _runner.ring_around(_player().tile_position, radius):
			var biome := _world().get_tile_biome(tile)
			if biomes_seen.get(biome, 0) >= SAMPLES_PER_BIOME:
				continue
			biomes_seen[biome] = biomes_seen.get(biome, 0) + 1
			_check_tile(tile)
			_check_movement_probe(tile)
			if _failures.size() > 20:
				break
	if _failures.is_empty():
		_runtime().emit_trace("world_consistency_audit_passed", "SmokeScenarios", {
			"tiles_checked": _tiles_checked,
			"movement_checked": _movement_checked,
			"failures": 0
		})
	else:
		for failure in _failures:
			push_error(str(failure))


func _check_tile(tile: Vector2i) -> void:
	_tiles_checked += 1
	var logic: Dictionary = _runtime()._world_gen.get_tile_logic(tile)
	if logic.is_empty():
		_failures.append({"tile": [tile.x, tile.y], "kind": "empty_logic"})
		return
	# Render vs pipeline: the texture the view shows must be the texture the
	# cache produces for the same logic dict.
	var shown := _world().get_tile_base_texture(tile)
	var expected := _tex_cache.base_texture(logic)
	if shown != expected:
		_failures.append({"tile": [tile.x, tile.y], "kind": "base_texture_mismatch"})
	var shown_prop := _world().get_tile_prop_texture(tile)
	var logic_prop := str(logic.get("prop_path", ""))
	if logic_prop.is_empty() and shown_prop != null:
		_failures.append({"tile": [tile.x, tile.y], "kind": "phantom_prop"})
	elif not logic_prop.is_empty() and shown_prop == null:
		_failures.append({"tile": [tile.x, tile.y], "kind": "missing_prop"})
	# Collision vs logic: blocked tiles must report a reason.
	var walkable := _world().is_tile_walkable(tile)
	var logic_walkable := bool(logic.get("walkable", true))
	var gate := str(logic.get("requires_field_move", ""))
	var gate_open := not gate.is_empty() and _runtime().is_field_move_unlocked(gate)
	if walkable != logic_walkable and not gate_open:
		_failures.append({"tile": [tile.x, tile.y], "kind": "walkable_mismatch",
			"logic": logic_walkable, "view": walkable})
	if not walkable and _world().get_traversal_block_reason(tile).is_empty() and not gate_open:
		_failures.append({"tile": [tile.x, tile.y], "kind": "block_without_reason"})


func _check_movement_probe(tile: Vector2i) -> void:
	var stand = _runner.stand_spot(_world(), tile)
	if stand == Vector2i(-9999, -9999):
		return
	_movement_checked += 1
	_runner.teleport_player(_world(), _player(), _runtime(), stand)
	var direction: Vector2i = tile - stand
	var accepted: bool = _player().smoke_step(direction)
	await get_tree().create_timer(0.15).timeout
	var moved := _player().tile_position != stand
	var expect := _world().is_tile_walkable(tile)
	if moved != expect or accepted != expect:
		_failures.append({"tile": [tile.x, tile.y], "kind": "movement_mismatch",
			"expected_walkable": expect, "moved": moved, "accepted": accepted})


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
```

If `SmokeScenarioRunner.stand_spot` returns a different sentinel, use its actual contract (read it). Keep the file under 220 lines.

- [ ] **Step 4: Wire dispatch + requirements.** In `scripts/app/qa_scenarios.gd` add to `SCENARIOS`:

```gdscript
	"world_consistency_audit": [preload("res://scripts/app/world_consistency_audit.gd"), "run", []],
```

In `tools/godot_dap_smoketest.py` `SCENARIO_REQUIREMENTS` add:

```python
    "world_consistency_audit": {
        "all": ["world_consistency_audit_passed"],
        "any": [["session_loaded", "session_created"]],
    },
```

- [ ] **Step 5: Register + trace docs.** In `docs/registry/subsystems.toml` add `"scripts/app/world_consistency_audit.gd"` to app_bootstrap `code_paths` and `"world_consistency_audit_passed"` to its `required_trace_events`. In `docs/references/trace-events.md` add a row: `` `world_consistency_audit_passed` | `SmokeScenarios` | The `world_consistency_audit` scenario verified logic/render/collision agreement across sampled tiles; payload carries tile and movement probe counts. ``

- [ ] **Step 6: Run headless — expect green on the clean build.**

Run: `echo '{"scenario":"world_consistency_audit"}' > .godot-smoke/scenario.json && /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --quit-after 30000`
Expected: stdout contains `world_consistency_audit_passed`, zero `SCRIPT ERROR` lines.
If it fails on the clean build, the audit found a REAL bug: fix the game code (not the oracle) until green, and note the bug in the task report.

- [ ] **Step 7: Seeded-bug red test — prove the oracle bites.** Temporarily edit `scripts/domain/biome_defs.gd`: set GRASSLAND's tree prop `block` to `false`. Re-run the scenario. Expected: `push_error` failures with `walkable_mismatch`/`movement_mismatch`, NO pass event. Revert the edit exactly (git checkout -- scripts/domain/biome_defs.gd is FORBIDDEN — implementers don't run git mutations; keep a byte-copy and restore it).

- [ ] **Step 8: Static checks + commit.**

Run: `python3 tools/check_repo_contracts.py && python3 tools/check_architecture.py && python3 tools/check_quality_docs.py`
Expected: all pass.
Commit (only your files):

```bash
git add scripts/app/world_consistency_audit.gd scripts/runtime/world_view.gd scripts/app/qa_scenarios.gd tools/godot_dap_smoketest.py docs/registry/subsystems.toml docs/references/trace-events.md
git commit -m "Add world consistency audit: tile logic/render/collision three-way"
```

---

### Task 2: Spatial contracts — player vs props, z-order, tall-grass alignment

**Files:**
- Modify: `scripts/app/world_consistency_audit.gd` (extend; split to a second app file if the budget demands)
- Modify: `scripts/runtime/world_view.gd` (y-sort fix)
- Modify: `scripts/runtime/player_avatar.gd` (`world_rect()`)

**Interfaces:**
- Consumes: Task 1 scenario and accessors.
- Produces: `player_avatar.world_rect() -> Rect2` (16x16 rect at the avatar's world position); y-sorted prop rendering (props and player draw in y order); payload key `spatial_checked` added to `world_consistency_audit_passed`.

- [ ] **Step 1: Write the failing spatial contract into the audit.** Add to the audit:

```gdscript
func _check_spatial_contracts() -> void:
	# Player rect must never intersect a blocking prop's solid tile rect.
	for tile in _runner.ring_around(_player().tile_position, 4):
		var logic: Dictionary = _runtime()._world_gen.get_tile_logic(tile)
		if str(logic.get("prop_path", "")).is_empty() or not bool(logic.get("prop_block", false)):
			continue
		_spatial_props.append(tile)
	# z-order: standing north of a tall prop, the prop must draw over the player;
	# south, the player must draw over the prop.
	for prop_tile in _spatial_props:
		_check_z_order(prop_tile)
	# tall grass: encounter tiles must render the tall-grass overlay and
	# non-encounter grass tiles must not.
	for tile in _runner.ring_around(_player().tile_position, 6):
		var logic2: Dictionary = _runtime()._world_gen.get_tile_logic(tile)
		var has_tall := not str(logic2.get("tall_grass_path", "")).is_empty()
		if bool(logic2.get("encounter", false)) != has_tall and _is_grass_biome(str(logic2.get("biome", ""))):
			_failures.append({"tile": [tile.x, tile.y], "kind": "tall_grass_mismatch"})
	_spatial_checked += 1
```

Verify the actual logic-dict key names (`prop_block` vs `block` inside a nested prop dict, `tall_grass_path`) by reading `scripts/domain/world_generator.gd`'s `get_tile_logic` output — adapt the code to the real keys.

- [ ] **Step 2: Add `world_rect()` to player_avatar.gd:**

```gdscript
func world_rect() -> Rect2:
	return Rect2(position - Vector2(8, 8), Vector2(16, 16))
```

- [ ] **Step 3: Run headless — expect RED on current build (z-order).** The current render gives the player a constant z_index above props, so standing north of a tree the player draws over the canopy — the contract fails. If (and only if) the audit reports `z_order` failures, apply the game fix: enable y-sorting in `world_view.gd` (`y_sort_enabled = true` on the world container) and set `player_avatar` z_index to 0 so y-sort governs draw order; prop sprites stay children of the same container with their sprite `position.y` at the tile bottom for tall props. Re-run until green. If there are no z-order failures, skip the fix and say why in the report.

- [ ] **Step 4: Registry/trace docs for the new payload key** (no new events) + static checks + commit:

```bash
git add scripts/app/world_consistency_audit.gd scripts/runtime/world_view.gd scripts/runtime/player_avatar.gd
git commit -m "Add spatial/z-order/tall-grass contracts to world consistency audit"
```

---

### Task 3: Soak spatial invariants

**Files:**
- Modify: `scripts/runtime/playtest_bot.gd`

**Interfaces:**
- Consumes: `player_avatar.world_rect()` (Task 2), `world_view.is_tile_walkable`, `runtime._world_gen.get_tile_logic`.
- Produces: `playtest_soak_passed` payload gains `spatial_violations` (int); soak fails when > 0.

- [ ] **Step 1: Add the per-step invariant.** In `playtest_bot.gd`, inside the soak loop right after each completed step, add:

```gdscript
func _check_spatial_invariants(player: Node, world: Node, runtime: Node) -> int:
	var violations := 0
	var rect: Rect2 = player.world_rect()
	for offset in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var tile: Vector2i = player.tile_position + offset
		var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
		if bool(logic.get("walkable", true)) or str(logic.get("prop_path", "")).is_empty():
			continue
		var prop_rect := Rect2(world.map_to_world(tile), Vector2(16, 16))
		if rect.intersects(prop_rect):
			violations += 1
	return violations
```

Call it after every step and accumulate into `_spatial_violations`; include `spatial_violations` in the pass payload and refuse the pass event when it is > 0. Verify `world.map_to_world(tile) -> Vector2` returns the tile's top-left world position (read world_view.gd) and adjust if it returns centers.

- [ ] **Step 2: Run playtest_soak headless — expect green.**

Run: `echo '{"scenario":"playtest_soak"}' > .godot-smoke/scenario.json && /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --quit-after 60000`
Expected: `playtest_soak_passed` with `spatial_violations: 0`. Red on clean build = real bug; fix game code, not the oracle.

- [ ] **Step 3: Static checks + commit:**

```bash
git add scripts/runtime/playtest_bot.gd
git commit -m "Add per-step spatial invariants to playtest soak"
```

---

### Task 4: UI render model — expected regions from art + data + font

**Files:**
- Create: `scripts/app/ui_render_model.gd`

**Interfaces:**
- Consumes: battle snapshot (`battle_runtime.get_snapshot()` shape), `catalog.get_move/get_species/get_item`, the source `res://pokewilds/fonts.ttf`.
- Produces: `UiRenderModel.expected(state: String, snapshot: Dictionary) -> Dictionary` returning `{"ink": Array[Rect2], "forbidden": Array[Rect2], "pairs": Array[Dictionary{"cursor": Rect2, "row": Rect2}], "strings": Array[Dictionary{"text": String, "region": Rect2}]}` for states `battle_action`, `battle_moves`, `battle_item`, `battle_message`, `menu`, `party`, `bag`.

- [ ] **Step 1: Measure-and-encode the art region table.** Decode `pokewilds/battle/gsc/battle_screen2.png` and `attack_screen1.png` (python3 + zlib stdlib, or Read the images) and confirm/adjust these measured constants (they come from prior pixel work — VERIFY, don't trust):

```gdscript
extends RefCounted

# Expected-region model for Lane 2 (ui_render_audit). Regions are measured
# from the baked art PNGs — the external truth — not from the layout code.

const FONT_PATH := "res://pokewilds/fonts.ttf"
const FONT_SIZE := 7

const ART := {
	"battle_action": {
		"rows": [Rect2(80, 112, 40, 8), Rect2(122, 112, 36, 8), Rect2(80, 128, 36, 8), Rect2(125, 128, 34, 8)],
		"forbidden": [Rect2(64, 104, 4, 40), Rect2(96, 104, 64, 4)],
	},
	"battle_moves": {
		"side_box": Rect2(2, 64, 110, 38),
		"move_box": Rect2(34, 96, 124, 46),
		"forbidden": [Rect2(32, 94, 2, 50)],
	},
}
```

- [ ] **Step 2: Implement `expected()`.** Load the font once (same path `battle_surface.gd` uses: `var font: Font = load(FONT_PATH)`; read that file to confirm). For each state, collect the visible strings from the snapshot (action commands are baked art: model them as `rows` only; moves state: move display names + `TYPE/<type>` + PP numbers; item state: item names + counts + BACK), compute each string's rect from its anchor + `font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)`, and build forbidden zones as the rows' complement strips (4px gaps between rows, box borders). Core shape:

```gdscript
static func expected(state: String, snapshot: Dictionary) -> Dictionary:
	var font: Font = load(FONT_PATH)
	var result := {"ink": [], "forbidden": [], "pairs": [], "strings": []}
	match state:
		"battle_moves":
			var moves: Array = snapshot.get("player_mon", {}).get("moves", [])
			var anchor := Vector2(45, 104)
			for i in range(moves.size()):
				var text := str(moves[i].get("name", "")).to_upper()
				var region := Rect2(anchor + Vector2(0, i * 8), font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE))
				result["ink"].append(region)
				result["strings"].append({"text": text, "region": region})
				result["pairs"].append({"cursor": Rect2(39, 104 + i * 8, 5, 8), "row": region})
				if i > 0:
					result["forbidden"].append(Rect2(34, 100 + i * 8, 124, 4))
			result["forbidden"].append(ART["battle_moves"]["forbidden"][0])
		_:
			for row in ART.get(state, {}).get("rows", []):
				result["ink"].append(row)
	return result
```

Fill out `battle_item` (item names + counts from `snapshot["bag"]` at the item-box anchors) and `battle_action` (rows from ART) the same way; menu/party/bag states model only panel bounds + row-fit (reuse `layout_audit.gd`'s data injection points — read it). Keep under 220 lines; if it won't fit, split art constants into `ui_render_art.gd`.

- [ ] **Step 3: Headless probe.** Temporary SceneTree script: build a fake snapshot (2 moves, 2 items), call `expected("battle_moves", snap)`, assert 2 move-name regions, 1 side-box, non-overlapping regions, and sane font metrics (`PECK` width ≈ 20px). Delete the probe. Parse-check + commit:

```bash
git add scripts/app/ui_render_model.gd
git commit -m "Add UI render model: expected ink regions from art and font metrics"
```

---

### Task 5: ui_render_audit — scene-tree half

**Files:**
- Create: `scripts/app/ui_render_audit.gd`
- Modify: `scripts/app/qa_scenarios.gd`, `tools/godot_dap_smoketest.py`, `docs/registry/subsystems.toml`, `docs/references/trace-events.md`

**Interfaces:**
- Consumes: Task 4 model; `battle_surface.render(snapshot, menu_state, selection, message)`; StartMenu/Party/Bag live scenes (pattern from `scripts/app/layout_audit.gd`).
- Produces: scenario `ui_render_audit`; trace `ui_render_audit_passed` (payload `{states_checked, labels_checked, cursors_checked, quarantined}`).

- [ ] **Step 1: Write the scenario.** Create `scripts/app/ui_render_audit.gd` (<220 lines; Node, `run(ctx)`). For each state in `["battle_action", "battle_moves", "battle_item", "battle_message", "menu", "party", "bag"]`: render the live scene with worst-case data (reuse `layout_audit.gd`'s snapshot-injection pattern — read it first), then:

```gdscript
func _check_state(state: String, snapshot: Dictionary) -> void:
	var model: Dictionary = UiRenderModel.expected(state, snapshot)
	_states_checked += 1
	# (a) every expected string appears in a visible Label inside its region
	for expected in model["strings"]:
		_labels_checked += 1
		if not _label_covers(expected["text"], expected["region"]):
			_failures.append({"state": state, "kind": "missing_or_misplaced", "text": expected["text"]})
	# (b) no two visible Labels' text rects intersect
	var text_rects := _visible_text_rects()
	for i in range(text_rects.size()):
		for j in range(i + 1, text_rects.size()):
			if (text_rects[i] as Rect2).intersects(text_rects[j]):
				_failures.append({"state": state, "kind": "label_overlap", "a": i, "b": j})
	# (c) cursor/row pairs
	for pair in model["pairs"]:
		_cursors_checked += 1
		var cursor: Rect2 = pair["cursor"]
		var row: Rect2 = pair["row"]
		if abs(cursor.get_center().y - row.get_center().y) > 2 or cursor.end.x > row.position.x:
			_failures.append({"state": state, "kind": "cursor_misplaced", "cursor": cursor, "row": row})
```

`_label_covers(text, region)` walks visible Labels in the current scene checking `label.text == text` and `region.encloses(label.get_global_rect())`; `_visible_text_rects()` collects `font.get_string_size`-derived rects of visible Labels. Collect failures; `push_error` + no pass event on failure, else emit `ui_render_audit_passed` with `{states_checked, labels_checked, cursors_checked, quarantined}`.

- [ ] **Step 2: Wire dispatch/requirements/registry/trace docs** (same edits as Task 1 Steps 4-5, for `ui_render_audit`).

- [ ] **Step 3: Run headless — expect green; red means real bug (fix game code).**

Run: `echo '{"scenario":"ui_render_audit"}' > .godot-smoke/scenario.json && /Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot --quit-after 30000`

- [ ] **Step 4: Seeded-bug red test.** Temporarily move one Label in `scenes/ui/BattleView.tscn` +6px right; scenario must fail; restore the file byte-identical.

- [ ] **Step 5: Static checks + commit.**

---

### Task 6: ui_render_audit — pixel half with visual_lint.py

**Files:**
- Create: `tools/visual_lint.py`
- Modify: `scripts/app/ui_render_audit.gd` (pixel half)

**Interfaces:**
- Consumes: Task 5 scenario; windowed captures via the Task 5 states; PNG decode imported from `tools/visual_diff.py` via importlib (same pattern as `tools/run_playtests.py`).
- Produces: `tools/visual_lint.py --image P --job J --out O` (JSON job: `{"ink_regions": [...], "forbidden_zones": [...], "text_rows": [...], "ink_min": 0.02, "forbidden_max": 0.01}`; JSON verdict: `{"ok": bool, "findings": [...]}`); failure crops in `.godot-smoke/lint/`; `quarantine_finding` trace events; `GRADUATED := false` const at the top of `ui_render_audit.gd`.

- [ ] **Step 1: Write `tools/visual_lint.py`.** Stdlib only; import `decode_png` (or the actual public name — read visual_diff.py) from the sibling file. Ink = luminance < 128. Implement `ink_density(img, rect)`, `forbidden_scan(img, rect)`, and `text_row_profile(img, rect) -> {"band_height": int, "max_density": float}` (histogram of dark pixels per y; a healthy single text row has band_height 5-10 and max_density < 0.85; garble = band_height > 12 or max_density >= 0.85). CLI per the contract above, exit 1 on any finding.

- [ ] **Step 2: Unit-test the lint tool.** Run it against the committed baselines: `python3 tools/visual_lint.py --image docs/generated/visual-baselines/09_battle.png --job /tmp/job.json --out /tmp/out.json` with a job built from the Task 4 model for battle_action — expect `ok: true`. Then synthesize garble: crop two text rows and paste one over the other with 2px vertical offset into a copy of the shot (python zlib PNG write, or reuse the tool's decoder/encoder) — expect `ok: false` with a `garble`/`forbidden_ink` finding on that region.

- [ ] **Step 3: Wire the pixel half.** In the scenario, after the scene-tree half per state: capture the viewport (windowed only — guard `DisplayServer.get_name() == "headless"` and skip pixel checks there), write the job JSON, `OS.execute("python3", ["tools/visual_lint.py", ...])`, parse the verdict. `GRADUATED == false`: findings emit `quarantine_finding` traces and never fail; `true`: findings fail the scenario. Register `quarantine_finding` in trace-events.md (`| `quarantine_finding` | `SmokeScenarios` | A quarantined heuristic pixel check reported a possible visual defect; payload carries state, kind, and region. |`) and in the registry's app_bootstrap `required_trace_events`.

- [ ] **Step 4: Full-windowed verification (orchestrator runs DAP; implementer verifies logic headlessly only).** Report to the orchestrator: run `python3 tools/run_playtests.py --scenario ui_render_audit` — expect pass with zero quarantine findings; if findings appear on the clean build, calibrate thresholds until the clean build is finding-free (document final thresholds in the script header).

- [ ] **Step 5: Static checks + commit.**

---

### Task 7: Vision review rubric + findings file

**Files:**
- Create: `docs/references/vision-review-rubric.md`
- Modify: `docs/RELIABILITY.md`

**Interfaces:**
- Consumes: `.godot-smoke/shots/*.png` after any `visual_sweep` run.
- Produces: `.godot-smoke/vision-review.json` schema `[{"shot": String, "findings": [{"class": String, "region": [x,y,w,h], "severity": "low|medium|high", "confidence": "low|medium|high", "note": String}]}]`.

- [ ] **Step 1: Write the rubric.** `docs/references/vision-review-rubric.md` with repo front matter (Status/Last verified/Review cadence days/Source paths) and per-state checklists: for `01-05` overworld shots (tile coherence, prop grounding — props sit ON tiles not floating between them, tall-grass patches visible and distinct, water/sand/grass/rock read correctly, tint plausibility for night/dawn), `06-08` menu shots (panel framing, row alignment, HP bar legibility, no text clipping), `09-12` battle shots (sprite integrity — single clean frame, centered, no slivers; HUD legibility; text inside boxes; cursor centered on its row; no glyph overlap). Each item phrased as a yes/no question a vision-capable reader answers from the image alone.

- [ ] **Step 2: Document the workflow in `docs/RELIABILITY.md`** under Visual verification: after any sweep whose shots change, the orchestrator (or a swarm agent) reads every shot against the rubric and writes `.godot-smoke/vision-review.json`; findings are quarantine-tier (reported, never red) unless a coded oracle confirms the same defect.

- [ ] **Step 3: Pilot run (the orchestrator does this with the implementer watching output format).** Run the rubric over the current 16 baselines, write the findings file with zero defects expected; then swap `09_battle.png` for a known-bad historical capture (message-overflow era) and confirm the rubric flags `text_overflow`/`glyph_overlap` — proving Lane 4 catches what coded oracles missed at the time.

- [ ] **Step 4: Static checks + commit.**

---

### Task 8: Runner integration + full-suite validation

**Files:**
- Modify: `tools/run_playtests.py` (default set + quarantine report section)
- Modify: `docs/RELIABILITY.md`, `docs/tech-debt-tracker.md`, `docs/QUALITY_SCORE.md`

- [ ] **Step 1: Runner.** Add `world_consistency_audit` and `ui_render_audit` to `PLAYTEST_SCENARIOS` in `tools/run_playtests.py`. Extend the JSON report: scenarios may carry `quarantine_findings: [...]` parsed from `quarantine_finding` traces; print a `quar` column.

- [ ] **Step 2: Docs.** RELIABILITY.md: the two new audits + quarantine semantics. tech-debt-tracker.md: move the corresponding debt lines to resolved. QUALITY_SCORE.md app_bootstrap note: four-lane oracle suite.

- [ ] **Step 3: Full gate.** `python3 tools/check_repo_contracts.py && python3 tools/check_architecture.py && python3 tools/check_change_contract.py && python3 tools/check_quality_docs.py` then `python3 tools/run_playtests.py --include-smoke --timeout 120` — expect 16/16 green (14 existing + 2 new) with a zero-count quarantine section.

- [ ] **Step 4: Commit + push (orchestrator confirms with the user first).**

---

## Self-Review

- **Spec coverage:** Lane 1 → Tasks 1-2; Lane 2 → Tasks 4-6; Lane 3 → Task 3; Lane 4 → Task 7; integration/two-tier/graduation → Tasks 6-8; budgets → Task 8 Step 3. All spec sections covered.
- **Placeholder scan:** every step has code or exact commands; measurement constants are marked verify-before-use where they depend on source art.
- **Type consistency:** `get_tile_base_texture/get_tile_prop_texture(Vector2i) -> Texture2D`, `world_rect() -> Rect2`, `expected(String, Dictionary) -> Dictionary`, trace names `world_consistency_audit_passed` / `ui_render_audit_passed` / `quarantine_finding` are used identically across tasks.
