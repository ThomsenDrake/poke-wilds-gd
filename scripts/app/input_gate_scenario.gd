extends Node

# Input double-fire regression (exec plan Part A5; spec: the Input map in
# bootstrap-and-overworld.md). Overlays own Z/X/Enter via _unhandled_input
# during the INPUT PHASE, which runs BEFORE Main._process polls Input — so a
# press that closed/confirmed an overlay there used to also fire the same-
# frame polls (Enter opened the start menu under a closing camp menu;
# Z-on-Demolish re-fired the context route on the bare former campfire tile).
# input_router.gd's GENERALIZED closed/confirm latch (bind_ui_consumers) now
# swallows BOTH polls on the closing/confirming frame for EVERY overlay;
# input_gate_menu_checks.gd covers the other leak paths (start-menu CLOSE,
# MessageBox NEW GAME confirm, inert FIELD MOVE). This scenario drives REAL
# input-phase events — never direct runtime calls — to prove both camp races
# are gone: (A) Enter with the camp menu open closes ONLY the camp menu (start
# menu stays shut, no menu_opened trace, avatar cleanly re-enabled); (B) Z on
# Demolish demolishes the campfire and nothing else (no build mode, no
# structure_placed / materials_consumed / field_move_used, the bag delta is
# exactly the refund). Injection: Input.use_accumulated_input buffers each
# parsed event for the NEXT iteration's input phase — _unhandled_input first,
# then same-iteration polls with just_pressed true (the bug frame). Press and
# release land in SEPARATE iterations so a poll ever sees just_pressed (smoke
# _press injects press+release in one frame and never fires a poll); every tap
# carries an INJECTION WITNESS so degraded delivery fails red, never vacuous.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const InputGateMenuChecks := preload("res://scripts/app/input_gate_menu_checks.gd")

# Campfire cost/refund (structures.gd _DEFAULT_COSTS, universal across biomes); the
# +2/+2 headroom lets the PRE-FIX bug place a wall on the demolished tile the same frame.
const SEED := 2026072401
const CAMPFIRE_REFUND := {"log": 4, "dry_soil": 2}
const GRANT := {"log": 6, "dry_soil": 4}

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["BULBASAUR", "MACHOP", "SANDSHREW"]) # cut + build + dig
	# Preconditions: keep the no-double-fire asserts below from going vacuous.
	_expect(runtime.party_has_field_move_ability("build"), "precondition: swapped party is not build-capable (the re-fire branch would be dead)")
	_expect(runtime.party_has_field_move_ability("cut"), "precondition: swapped party is not cut-capable (the menu demolish would refuse)")
	# A dig-capable member makes the race-frame re-fire LOUD: the bare former campfire
	# tile is dig-harvestable (DIG_BIOME_ITEMS), so a re-fired route traces
	# field_move_used + grants a yield instead of refusing invisibly.
	_expect(runtime.party_has_field_move_ability("dig"), "precondition: swapped party is not dig-capable (a re-fire would degrade to an invisible refused dig)")
	var fire_tile := _place_campfire()
	var site_ok := fire_tile != Vector2i.MAX and _failures.is_empty()
	if site_ok:
		_face(fire_tile)
		site_ok = _failures.is_empty()
	if site_ok: # both parts run even if part A fails, so pre-fix reds name BOTH races
		await _part_a_enter_closes_only_camp_menu()
		await _part_b_demolish_does_not_refire(fire_tile)
		var menu_checks := InputGateMenuChecks.new() # parts C/E/D: the other leak paths
		add_child(menu_checks)
		await menu_checks.run(_ctx, _runner, _failures)
	if _failures.is_empty():
		runtime.emit_trace("input_gate_passed", "SmokeScenarios", {"enter_only_close": true, "demolish_no_refire": true, "seed": SEED})
	else:
		runtime.emit_trace("input_gate_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		runtime.warn("InputGateScenario", "Input gate failed: %s." % "; ".join(PackedStringArray(_failures)), {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	Input.use_accumulated_input = false


# Drains the grant ids, then funds the campfire plus one wall of headroom (the exact pre-race bag the part-B delta check reads).
func _place_campfire() -> Vector2i:
	var runtime = _runtime()
	for item_id in GRANT.keys():
		runtime.session.remove_item(str(item_id), runtime.get_item_count(str(item_id)))
		runtime.session.add_item(str(item_id), int(GRANT[item_id]))
	var fire_tile := _find_open_tile(_player().tile_position)
	if fire_tile == Vector2i.MAX:
		_failures.append("site: no open tile for the campfire within 8 rings")
		return Vector2i.ZERO
	var placed: Dictionary = runtime.build_runtime.try_place(fire_tile, "campfire", {})
	if not bool(placed.get("ok", false)):
		_failures.append("campfire: placement refused (%s)" % str(placed.get("reason", "")))
		return Vector2i.ZERO
	return fire_tile


# Stands the player on a walkable neighbor facing the campfire (a blocked step still turns it — field_move precedent).
func _face(tile: Vector2i) -> void:
	var spot: Dictionary = _runner.stand_spot(_world(), tile)
	if spot.is_empty():
		_failures.append("site: the campfire tile has no walkable stand neighbor")
		return
	_runner.teleport_player(_world(), _player(), _runtime(), spot["from_tile"])
	_player().smoke_step(spot["direction"]) # blocked by the campfire, but faces it
	_expect(_player().facing_tile() == tile, "site: the player does not face the campfire after the blocked step")


# Part A — Enter with the camp menu open closes ONLY the camp menu.
func _part_a_enter_closes_only_camp_menu() -> void:
	var player = _player()
	var tile_before: Vector2i = player.tile_position
	await _tap("action_a") # overworld Z: the _process poll opens the camp menu
	if not _expect(_camp_menu().visible and not player.input_enabled, "A: injection witness: the first Z did not open the camp menu and disable the avatar"):
		return
	var cursor := _runner.trace_log_line_count()
	await _tap("start") # Enter: the input phase closes the camp menu; the poll must be swallowed
	_expect(not _camp_menu().visible, "A: injection witness: Enter did not close the camp menu")
	_expect(not _start_menu().visible, "A: Enter also opened the start menu under the closing camp menu")
	_expect(not _runner.trace_log_has_since("menu_opened", cursor), "A: a menu_opened trace fired on the closing frame")
	_expect(player.input_enabled, "A: the avatar stayed disabled after the camp menu closed")
	_expect(player.tile_position == tile_before, "A: the player moved")
	_expect(not (_start_menu().visible and player.input_enabled), "A: start menu and avatar are both live (dual control)")

# Part B — Z on Demolish demolishes the campfire and NOTHING else (reuses part A's campfire).
func _part_b_demolish_does_not_refire(fire_tile: Vector2i) -> void:
	var runtime = _runtime()
	var player = _player()
	if _start_menu().visible: # pre-fix, part A's bug leaves the start menu open; a REAL X
		await _tap("action_b") # tap closes it so part B races a clean overworld on both sides
	await _tap("action_a") # re-open the camp menu on the campfire
	if not _expect(_camp_menu().visible, "B: injection witness: Z did not re-open the camp menu"):
		return
	# Six move_down presses flush in ONE input phase -> six _move_selection(+1):
	# five recipes + fire toggle + Demolish = row 6 (the row TEXT check turns
	# recipe-count drift into a loud failure, not a silent mis-select).
	for _i in range(6):
		_inject_press("move_down")
	_inject_release("move_down")
	await get_tree().process_frame
	var entries: ItemList = _camp_menu().get_node("MenuPanel/Margin/VBox/Entries")
	var selected: PackedInt32Array = entries.get_selected_items()
	var row_text := entries.get_item_text(int(selected[0])) if selected.size() > 0 else ""
	if not _expect(row_text.contains("Demolish"), "B: precondition witness: selected row '%s' is not Demolish" % row_text):
		return
	var tile_before: Vector2i = player.tile_position
	var tile_key := "%d,%d" % [fire_tile.x, fire_tile.y]
	var bag_before: Dictionary = runtime.session.bag.duplicate(true)
	var had_placement: bool = runtime.placed_structures().has(tile_key)
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: input phase demolishes; the poll must be swallowed
	_expect(not _camp_menu().visible, "B: injection witness: Z-on-Demolish did not close the camp menu")
	_expect(had_placement and not runtime.placed_structures().has(tile_key), "B: injection witness: the demolished tile is still occupied (something re-placed there)")
	_expect(_world().is_tile_walkable(fire_tile), "B: the demolished tile stayed occupied")
	_expect(_runner.trace_log_has_since("structure_demolished", cursor, {"structure_id": "campfire", "tile": [fire_tile.x, fire_tile.y]}), "B: no structure_demolished trace for the legitimate demolition")
	_expect(not _structure_layer().is_active(), "B: build mode opened on the demolished tile")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "B: a structure was placed on the re-fired press")
	_expect(not _runner.trace_log_has_since("materials_consumed", cursor), "B: materials were consumed after the demolition")
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "B: a harvest re-fired on the bare former campfire tile")
	var expected_bag: Dictionary = bag_before.duplicate(true)
	for item_id in CAMPFIRE_REFUND.keys():
		expected_bag[item_id] = int(expected_bag.get(item_id, 0)) + int(CAMPFIRE_REFUND[item_id])
	_expect(runtime.session.bag == expected_bag, "B: the bag delta is not exactly the campfire refund (a wall cost leaked)")
	_expect(player.tile_position == tile_before, "B: the player moved")
	_expect(player.input_enabled, "B: the avatar stayed disabled after the demolition")


# --- Real input-phase injection (press and release in separate iterations) ---
func _inject_press(action: String) -> void:
	var template := _key_template(action)
	if template == null:
		_failures.append("injection: no key event is bound to %s" % action)
		return
	var event := InputEventKey.new()
	event.physical_keycode = template.physical_keycode
	event.pressed = true
	Input.parse_input_event(event)


func _inject_release(action: String) -> void:
	var template := _key_template(action)
	if template == null:
		return
	# A fresh event: re-parsing the same object in one frame is engine-rejected.
	var event := InputEventKey.new()
	event.physical_keycode = template.physical_keycode
	event.pressed = false
	Input.parse_input_event(event)


# Press, let the race iteration complete (polls run with just_pressed true), then
# release in a LATER iteration so the press alone is just-pressed in the bug frame.
func _tap(action: String) -> void:
	_inject_press(action)
	await get_tree().process_frame
	_inject_release(action)
	await get_tree().process_frame


func _key_template(action: String) -> InputEventKey:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return event as InputEventKey
	return null

func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok

func _find_open_tile(center: Vector2i) -> Vector2i: # first open tile ring-by-ring (craft_flow's pattern); not-found = MAX ((0,0) is a real tile; ring 24 out-reaches any landmark footprint)
	for ring in range(1, 25):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.MAX


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _camp_menu() -> Node: return _ctx["camp_menu"]
func _structure_layer() -> Node: return _ctx["structure_layer"]
