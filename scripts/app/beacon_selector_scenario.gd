extends Node

# Multi-beacon SELECTOR functional witness (Phase 7 audit R5; world-depth.md § Teleport
# Beacons (1)(2), fresh-faq.md:178-192 "you can select one of the Beacons to be Teleported
# to it"). Closes the UNCOVERED multi-beacon CHOICE: shot 33 is screenshot-only and
# world_chain warps via use_teleport(tile) DIRECTLY (the selector bypassed), so an
# index->tile mis-mapping warp could never red. This registers TWO edge-band beacons,
# drives the APP teleport route (field_move_actions._route_warp) so the BeaconSelector
# opens, drives a REAL input pick of the SECOND-registered beacon (index 1) through
# smoke_tap injection, and asserts the avatar warps to THAT beacon's tile (not index 0);
# plus the registration-order listing (beacon_tiles == the selector's _rows order) and a
# cancel-changes-nothing control. Self-pinned seed_for_smoke BEFORE new_game (house
# convention); encounter_chance 0 (no wild stream). Input rides the selector's
# _unhandled_input (headless-safe). PRECONDITION: scenes/ui/BeaconSelector.tscn is in
# Main.tscn (the orchestrator's final commit includes the untracked scene + the modified
# Main.tscn) — an absent selector reds HERE loudly, never a silent skip.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const SEED := 2026073101
const DAY_MINUTES := 600
const BEACON_RING := 90 # manhattan: inside the suppression band (>= WORLD_RADIUS - 8 = 88) AND inside the disc (< 96) — every ring tile is a Teleport Beacon

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _beacons: Array = [] # the two registered edge beacons, in registration order


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the root_seed draw (the double-run lane convention)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the breed_flow precedent)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var party_before: Array = FieldMovesParty.swap_in(runtime) # Calyrex carries Teleport (the capability the registry + the warp gate)
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # no grass battles / wild-stream draws during the selector proof
	_oks["party_ok"] = _ensure(FieldMovesParty.verify(runtime).is_empty(), "party: the all-field-moves fixture failed verification (%s)" % str(FieldMovesParty.verify(runtime)))
	if _failures.is_empty(): _oks["order_ok"] = _setup_two_beacons(runtime)
	else: _failures.append("skipped: beacon setup (cascaded from a party red)")
	if _failures.is_empty(): _oks["pick_ok"] = await _pick_second_beacon(runtime)
	else: _failures.append("skipped: selector pick (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["cancel_ok"] = await _cancel_changes_nothing(runtime)
	else: _failures.append("skipped: cancel control (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED; payload["beacons"] = _beacons.map(func(t: Vector2i): return [t.x, t.y])
		runtime.emit_trace("beacon_selector_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("beacon_selector_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("BeaconSelectorScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("SmokeScenarios", "Beacon selector scenario failed.", {})
	FieldMovesParty.restore(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES


# Register TWO edge-band way-stones (beacons) in a deterministic ring order, then pin the
# selector listing: beacon_tiles() (the selector's _rows source) carries both in
# REGISTRATION order — the single ordering the trace + the UI share (world_chain_runtime
# .beacon_tiles; a listing-order drift reds here, named).
func _setup_two_beacons(runtime) -> bool:
	var start: int = _failures.size()
	_runner.teleport_player(_world(), _player(), runtime, Vector2i.ZERO) # inland; registration is position-independent but keeps the player off the suppression band
	for tile in _beacon_ring_tiles():
		if _beacons.size() >= 2:
			break
		var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
		if not bool(logic.get("walkable", false)) or str(logic.get("landmark_id", "")) != "" or str(logic.get("prop_path", "")) != "":
			continue # open ground only (register_way_stone's can_place gate); landmarks/props refused
		var reg: Dictionary = runtime.field_move_runtime.register_way_stone(tile)
		if bool(reg.get("ok", false)):
			_beacons.append(tile)
	if not _ensure(_beacons.size() == 2, "beacons: registered %d/2 edge-band way-stones on ring %d (%s)" % [_beacons.size(), BEACON_RING, str(_beacons)]):
		return false
	var listed: Array = runtime.world_chain_runtime.beacon_tiles()
	var i0: int = listed.find(_beacons[0]); var i1: int = listed.find(_beacons[1])
	_ensure(i0 >= 0 and i1 >= 0 and i0 < i1, "beacons: beacon_tiles() order %s != registration order %s (the selector listing drifted)" % [str(listed), str(_beacons)])
	return _failures.size() == start


# The functional CHOICE: drive the APP teleport route so the selector opens (>1 beacon,
# capable, player inland = not edge_suppressed), then a REAL input pick of index 1 — the
# SECOND-registered beacon — and the avatar must land on THAT tile, not index 0. An
# index->tile mis-mapping in _resolve_warp / the selector rows reds here.
func _pick_second_beacon(runtime) -> bool:
	var start: int = _failures.size()
	_runner.teleport_player(_world(), _player(), runtime, Vector2i.ZERO) # inland: the suppression band releases so the selector opens
	var cursor: int = _runner.trace_log_line_count()
	_drive_teleport() # field_move_actions._route_warp -> _open_selector (BeaconSelector)
	await get_tree().create_timer(0.2).timeout
	var selector: Node = _selector_node()
	if not _ensure(selector != null and bool(selector.get("visible")), "pick: the BeaconSelector did not open on the multi-beacon teleport route (scene missing or route regressed)"):
		return false
	await _tap(selector, "move_down") # row 0 -> row 1 (the second-registered beacon)
	await _tap(selector, "action_a") # Z: travel -> _resolve_warp(beacons[1]) -> use_teleport(beacons[1])
	await get_tree().create_timer(0.2).timeout
	var dest: Vector2i = _beacons[1]
	_ensure(_runner.trace_log_has_since("teleport_used", cursor, {"tile": [dest.x, dest.y]}), "pick: no teleport_used to the second beacon %s (the warp went elsewhere)" % str(dest))
	_ensure(runtime.get_player_tile() == dest, "pick: the avatar landed on %s, expected the picked beacon[1] %s (index->tile mis-mapping)" % [str(runtime.get_player_tile()), str(dest)])
	_ensure(runtime.get_player_tile() != _beacons[0], "pick: the avatar warped to beacon[0] %s, not the picked beacon[1] %s (the selector chose index 0)" % [str(_beacons[0]), str(dest)])
	return _failures.size() == start


# Cancel control: re-open the selector, press X (action_b) — the avatar must NOT move, the
# selector must close, and the avatar input must re-enable (the closed-signal latch).
func _cancel_changes_nothing(runtime) -> bool:
	var start: int = _failures.size()
	_runner.teleport_player(_world(), _player(), runtime, Vector2i.ZERO) # inland: the pick warped the avatar onto beacon[1] (ring 90, inside the suppression band) — the selector only opens OFF the band (the pick case's :92 precedent), so re-open from inland
	var before: Vector2i = runtime.get_player_tile()
	_drive_teleport()
	await get_tree().create_timer(0.2).timeout
	var selector: Node = _selector_node()
	if not _ensure(selector != null and bool(selector.get("visible")), "cancel: the BeaconSelector did not re-open"):
		return false
	await _tap(selector, "action_b") # X: close -> no warp
	await get_tree().create_timer(0.2).timeout
	_ensure(not bool(selector.get("visible")), "cancel: the BeaconSelector stayed open after X")
	_ensure(runtime.get_player_tile() == before, "cancel: the avatar moved (%s -> %s) on a cancelled selector" % [str(before), str(runtime.get_player_tile())])
	_ensure(bool(_player().input_enabled), "cancel: the avatar input stayed disabled after the selector closed (the closed latch regressed)")
	return _failures.size() == start


# A real press+release through the input phase (smoke_tap): the selector reads
# _unhandled_input, so accumulated input is toggled for the tap and restored.
func _tap(selector: Node, action: String) -> void:
	var saved: bool = Input.use_accumulated_input
	Input.use_accumulated_input = true
	await SmokeTap.tap(get_tree(), action)
	Input.use_accumulated_input = saved


# The APP teleport route (main._on_field_move_requested -> field_action_router ->
# field_move_actions.route("teleport") -> _route_warp), driven exactly like the
# party-screen FIELD MOVE seam.
func _drive_teleport() -> void:
	var callable: Callable = _ctx.get("field_move", Callable())
	if callable.is_valid():
		callable.call("teleport")


func _selector_node() -> Node: # field_move_actions._selector_node's mirror (UI/BeaconSelector under Main)
	var scene: Node = _runtime().get_tree().current_scene
	return scene.get_node_or_null("UI/BeaconSelector") if scene != null else null


# The manhattan ring at BEACON_RING, deterministic order (every tile is a beacon: ring >= 88).
func _beacon_ring_tiles() -> Array:
	var tiles: Array = []
	for x in range(-BEACON_RING, BEACON_RING + 1):
		var dy: int = BEACON_RING - absi(x)
		tiles.append(Vector2i(x, -dy))
		if dy != 0:
			tiles.append(Vector2i(x, dy))
	return tiles


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
