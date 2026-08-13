extends Node

# Way-stone SELECTOR functional witness (infinite-world slice; succeeds the RETIRED
# beacon_selector scenario — world chaining's edge beacons are gone, way-stone teleport
# stays as plain intra-world warps, spec: field-moves.md). Closes the UNCOVERED multi-stone
# CHOICE the old scenario covered for beacons: an index->tile mis-mapping in
# field_move_actions._resolve_warp / the selector rows could never red in a screenshot.
# Registers TWO way-stones on open ground, drives the PRODUCTION party-screen route
# (start_menu toggle -> POKEMON -> FIELD MOVE teleport, the exact signal chain
# party_screen.field_move_requested -> start_menu._on_field_move_requested ->
# main._on_field_move_requested -> field_action_router -> field_move_actions._route_warp),
# and pins AVATAR-INPUT OWNERSHIP while the modal selector is open: input_enabled must be
# FALSE (the field-move route emits BEFORE start_menu hides the menu, so the selector's
# disable lands first and main._on_menu_closed's re-enable — which re-checks the selector's
# visibility — must not clobber it; an unconditional re-enable regresses to
# walking-under-the-modal and reds HERE). C must not open build mode under the modal
# (the selector does not consume build_toggle; an unguarded overworld-free poll would
# arm StructureLayer so the next Z both warps and places).
# Then a REAL input pick of the SECOND-registered stone (index 1) must warp the avatar to
# THAT tile, and a cancel must change nothing. Self-pinned seed_for_smoke BEFORE new_game
# (house convention); encounter_chance 0 (no wild stream). Input rides the selector's
# _unhandled_input (headless-safe). PRECONDITION: scenes/ui/WayStoneSelector.tscn wired in
# Main.tscn — an absent selector reds loudly, never a silent skip.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const SEED := 2026073101
const DAY_MINUTES := 600
const SCAN_RING_MAX := 48 # expanding manhattan rings from origin; two open tiles land well inside

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _stones: Array = [] # the two registered way-stones, in registration order


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the world-seed draw (the double-run lane convention)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the breed_flow precedent)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var party_before: Array = FieldMovesParty.swap_in(runtime) # Calyrex carries Teleport (the capability the registry + the warp gate ride)
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # no grass battles / wild-stream draws during the selector proof
	_oks["party_ok"] = _ensure(FieldMovesParty.verify(runtime).is_empty(), "party: the all-field-moves fixture failed verification (%s)" % str(FieldMovesParty.verify(runtime)))
	if _failures.is_empty(): _oks["order_ok"] = _register_two_stones(runtime)
	else: _failures.append("skipped: way-stone setup (cascaded from a party red)")
	if _failures.is_empty(): _oks["pick_ok"] = await _pick_second_stone(runtime)
	else: _failures.append("skipped: selector pick (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["cancel_ok"] = await _cancel_changes_nothing(runtime)
	else: _failures.append("skipped: cancel control (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED; payload["stones"] = _stones.map(func(t: Vector2i): return [t.x, t.y])
		runtime.emit_trace("waystone_selector_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("waystone_selector_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("WayStoneSelectorScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("SmokeScenarios", "Way-stone selector scenario failed.", {})
	var selector: Node = _selector_node()
	if selector != null and bool(selector.get("visible")):
		selector.call("close_selector") # teardown hygiene: never leave a modal armed for the dispatcher
	FieldMovesParty.restore(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES


# Register TWO way-stones on open ground (deterministic expanding-ring scan; registration is
# position-independent), then pin the selector listing source: way_stone_tiles() must carry
# both in REGISTRATION order — the single ordering the trace + the UI share (a listing-order
# drift reds here, named).
func _register_two_stones(runtime) -> bool:
	var start: int = _failures.size()
	for tile in _scan_tiles():
		if _stones.size() >= 2:
			break
		if tile == runtime.get_player_tile():
			continue # never stamp the player's own tile
		var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
		if not bool(logic.get("walkable", false)) or str(logic.get("landmark_id", "")) != "" or str(logic.get("prop_path", "")) != "":
			continue # open ground only (register_way_stone's can_place_on gate); landmarks/props refused
		var reg: Dictionary = runtime.field_move_runtime.register_way_stone(tile)
		if bool(reg.get("ok", false)):
			_stones.append(tile)
	if not _ensure(_stones.size() == 2, "stones: registered %d/2 way-stones within ring %d (%s)" % [_stones.size(), SCAN_RING_MAX, str(_stones)]):
		return false
	var listed: Array = runtime.field_move_runtime.way_stone_tiles()
	var i0: int = listed.find(_stones[0]); var i1: int = listed.find(_stones[1])
	_ensure(i0 >= 0 and i1 >= 0 and i0 < i1, "stones: way_stone_tiles() order %s != registration order %s (the selector listing drifted)" % [str(listed), str(_stones)])
	return _failures.size() == start


# The functional CHOICE through the PRODUCTION menu route. The avatar-input ownership pin
# rides the same drive: while the modal selector is open the avatar must stay input-DISABLED
# (the selector's disable lands during the emit, BEFORE start_menu hides the menu; main's
# menu-close re-enable re-checks the selector's visibility rather than clobbering it).
# C must not arm the build overlay (the selector does not consume build_toggle).
# Then a REAL pick of index 1 warps to stones[1], not index 0.
func _pick_second_stone(runtime) -> bool:
	var start: int = _failures.size()
	var cursor: int = _runner.trace_log_line_count()
	_drive_menu_teleport()
	await get_tree().create_timer(0.2).timeout
	var selector: Node = _selector_node()
	if not _ensure(selector != null and bool(selector.get("visible")), "pick: the WayStoneSelector did not open on the multi-stone teleport route (scene missing or route regressed)"):
		return false
	_ensure(not _start_menu().visible, "pick: the start menu stayed open under the selector (the field move must close the menu)")
	_ensure(not bool(_player().input_enabled), "pick: the avatar is INPUT-ENABLED under the open selector (the menu-close re-enable clobbered the selector's ownership — main._on_menu_closed must re-check the selector's visibility)")
	var build_cursor: int = _runner.trace_log_line_count()
	await _tap("build_toggle")
	_ensure(not _structure_layer().is_active(), "pick: C opened build mode under the way-stone selector")
	_ensure(not _runner.trace_log_has_since("build_mode_entered", build_cursor), "pick: C emitted build_mode_entered under the way-stone selector")
	var rows: Array = selector.get("_rows")
	_ensure(rows.size() == 2 and rows[0].get("tile") == _stones[0] and rows[1].get("tile") == _stones[1], "pick: the selector rows %s != registration order %s" % [str(rows), str(_stones)])
	await _tap("move_down") # row 0 -> row 1 (the second-registered stone)
	await _tap("action_a") # Z: travel -> _resolve_warp(stones[1]) -> use_teleport(stones[1])
	await get_tree().create_timer(0.2).timeout
	var dest: Vector2i = _stones[1]
	_ensure(_runner.trace_log_has_since("teleport_used", cursor, {"tile": [dest.x, dest.y]}), "pick: no teleport_used to the second stone %s (the warp went elsewhere)" % str(dest))
	_ensure(runtime.get_player_tile() == dest, "pick: the avatar landed on %s, expected the picked stone[1] %s (index->tile mis-mapping)" % [str(runtime.get_player_tile()), str(dest)])
	_ensure(runtime.get_player_tile() != _stones[0], "pick: the avatar warped to stone[0] %s, not the picked stone[1] %s (the selector chose index 0)" % [str(_stones[0]), str(dest)])
	_ensure(bool(_player().input_enabled), "pick: the avatar input stayed disabled after the resolve (the closed latch regressed)")
	return _failures.size() == start


# Cancel control: re-open the selector through the same menu route, press X (action_b) —
# the avatar must NOT move, the selector must close, and avatar input must re-enable.
func _cancel_changes_nothing(runtime) -> bool:
	var start: int = _failures.size()
	var before: Vector2i = runtime.get_player_tile()
	_drive_menu_teleport()
	await get_tree().create_timer(0.2).timeout
	var selector: Node = _selector_node()
	if not _ensure(selector != null and bool(selector.get("visible")), "cancel: the WayStoneSelector did not re-open"):
		return false
	await _tap("action_b") # X: close -> no warp
	await get_tree().create_timer(0.2).timeout
	_ensure(not bool(selector.get("visible")), "cancel: the WayStoneSelector stayed open after X")
	_ensure(runtime.get_player_tile() == before, "cancel: the avatar moved (%s -> %s) on a cancelled selector" % [str(before), str(runtime.get_player_tile())])
	_ensure(bool(_player().input_enabled), "cancel: the avatar input stayed disabled after the selector closed (the closed latch regressed)")
	return _failures.size() == start


# The PRODUCTION party-screen route, driven at the signal layer (input_gate owns the key
# plumbing): open the start menu through main's toggle, open the POKEMON submenu, put the
# confirmed row on the Teleport carrier, then emit the party screen's real signal —
# start_menu._on_field_move_requested (the hide-first ordering) -> main -> the router.
func _drive_menu_teleport() -> void:
	var toggle: Callable = _ctx.get("toggle_menu", Callable())
	if toggle.is_valid():
		toggle.call() # main._toggle_menu: _menu_open = true, avatar input off, show_menu
	var calyrex := -1
	var snapshot: Array = _runtime().get_party_snapshot()
	for i in range(snapshot.size()):
		if str((snapshot[i] as Dictionary).get("species_id", "")) == "CALYREX":
			calyrex = i
			break
	_start_menu().call("_activate_entry", 0) # ENTRY_POKEMON -> _open_submenu(_party_screen)
	_start_menu().get_node("PartyScreen").set("_selected", maxi(calyrex, 0))
	_start_menu().get_node("PartyScreen").emit_signal("field_move_requested", "teleport")


# A real press+release through the input phase (smoke_tap): the selector reads
# _unhandled_input, so accumulated input is toggled for the tap and restored.
func _tap(action: String) -> void:
	var saved: bool = Input.use_accumulated_input
	Input.use_accumulated_input = true
	await SmokeTap.tap(get_tree(), action)
	Input.use_accumulated_input = saved


# The expanding manhattan rings 1..SCAN_RING_MAX from origin, deterministic order.
func _scan_tiles() -> Array:
	var tiles: Array = []
	for ring in range(1, SCAN_RING_MAX + 1):
		for x in range(-ring, ring + 1):
			var dy: int = ring - absi(x)
			tiles.append(Vector2i(x, -dy))
			if dy != 0:
				tiles.append(Vector2i(x, dy))
	return tiles


func _selector_node() -> Node: # field_move_actions._selector_node's mirror (UI/WayStoneSelector under Main)
	var scene: Node = _runtime().get_tree().current_scene
	return scene.get_node_or_null("UI/WayStoneSelector") if scene != null else null


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _structure_layer() -> Node: return _ctx["structure_layer"]
