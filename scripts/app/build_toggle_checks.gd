extends Node

# Build-toggle regressions for the dig_silence harness (C enters build; Z
# stays harvest). A/B/C live in dig_silence_scenario.gd; this extraction
# keeps that file under the 220 wall:
#   (D) MACHOP+GEODUDE, Z on a diggable AND placeable tile: Dig fires,
#       build mode stays shut, no build_mode_entered (Z no longer steals
#       Build — Dig used to shadow it because both verbs shared context Z).
#   (E) C on that same tile: build_mode_entered, overlay active, no harvest
#       and no structure_placed on the enter frame (the Z-entry over-fire:
#       structure_layer._process used to see action_a still just-pressed).
#   (F) grant wall materials, select_structure("wall"), Z: structure_placed.
#   (G) C+Z same frame on a diggable+placeable tile: overlay opens, Dig
#       does not fire (the collapsed-poll stale context_ok leak).
# Real input-phase taps (SmokeTap); every tap carries a delivery witness.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")

const SCAN_RADIUS := 40
const WALL_GRANT := {"log": 4, "dry_soil": 4, "hard_stone": 4}

var _ctx: Dictionary = {}
var _runner: SmokeScenarioRunner
var _failures: Array = []
var _site: Dictionary = {}


func run(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_runner.swap_party(_runtime(), ["MACHOP", "GEODUDE"])
	if not _expect(_runtime().party_has_field_move_ability("build"), "precondition: MACHOP+GEODUDE cannot BUILD"):
		return
	if not _expect(_runtime().party_has_field_move_ability("dig"), "precondition: MACHOP+GEODUDE cannot DIG"):
		return
	await _part_g_c_and_z_same_frame_does_not_harvest()
	if _failures.is_empty():
		await _part_d_z_digs_and_does_not_open_build()
	if _failures.is_empty():
		await _part_e_c_opens_build_without_placing()
	if _failures.is_empty():
		await _part_f_z_in_overlay_places()


func _part_d_z_digs_and_does_not_open_build() -> void:
	if _site.is_empty():
		_site = _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "dig")
	if not _expect(not _site.is_empty(), "site: no dig tile with a stand spot within %d rings" % SCAN_RADIUS):
		return
	if not _expect(_tile_is_placeable(_site["tile"]), "D: the dig tile is not placeable"):
		return
	_runner.teleport_player(_world(), _player(), _runtime(), _site["from_tile"])
	_player()._facing = _site["direction"]
	_expect(_player().facing_tile() == _site["tile"], "D: the player does not face the dig tile")
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a")
	_expect(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "dig"}), "D: Z on a diggable tile did not Dig")
	_expect(not _structure_layer().is_active(), "D: Z opened build mode")
	_expect(not _runner.trace_log_has_since("build_mode_entered", cursor), "D: Z emitted build_mode_entered")
	_expect(HarvestResolver.action_for_tile(_world().get_tile_logic(_site["tile"])) == "", "D: the dig tile was not harvested")


func _part_e_c_opens_build_without_placing() -> void:
	_expect(_player().facing_tile() == _site["tile"], "E: the player no longer faces the harvested tile")
	var cursor := _runner.trace_log_line_count()
	await _tap("build_toggle")
	_expect(_runner.trace_log_has_since("build_mode_entered", cursor), "E: C did not emit build_mode_entered")
	_expect(_structure_layer().is_active(), "E: C did not open the build overlay")
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "E: C harvested on the enter frame")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "E: C placed a structure on the enter frame")


func _part_f_z_in_overlay_places() -> void:
	if not _expect(_structure_layer().is_active(), "F: build overlay is not active"):
		return
	for item_id in WALL_GRANT.keys():
		_runtime().session.add_item(str(item_id), int(WALL_GRANT[item_id]))
	_structure_layer().select_structure("wall")
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a")
	_expect(_runner.trace_log_has_since("structure_placed", cursor, {"structure_id": "wall"}), "F: Z in the overlay did not place a wall")
	_expect(not _structure_layer().is_active(), "F: a successful place left the overlay open")


func _part_g_c_and_z_same_frame_does_not_harvest() -> void:
	# Chord C+Z while overworld-free so a stale context_ok would Dig as the overlay opens.
	_site = _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "dig")
	if not _expect(not _site.is_empty(), "G: no dig tile with a stand spot within %d rings" % SCAN_RADIUS):
		return
	if not _expect(_tile_is_placeable(_site["tile"]), "G: the dig tile is not placeable"):
		return
	_runner.teleport_player(_world(), _player(), _runtime(), _site["from_tile"])
	_player()._facing = _site["direction"]
	_expect(_player().facing_tile() == _site["tile"], "G: the player does not face the dig tile")
	# A/B/C harvest leftovers would let overlay Z place a wall on this same
	# frame and close the overlay, masking the harvest-leak witness.
	for item_id in WALL_GRANT.keys():
		var have: int = _runtime().session.get_item_count(str(item_id))
		if have > 0:
			_runtime().session.remove_item(str(item_id), have)
	var cursor := _runner.trace_log_line_count()
	await _tap_chord("build_toggle", "action_a")
	_expect(_runner.trace_log_has_since("build_mode_entered", cursor), "G: C+Z did not emit build_mode_entered")
	_expect(_structure_layer().is_active(), "G: C+Z did not open the build overlay")
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "G: C+Z harvested the faced tile")
	_expect(HarvestResolver.action_for_tile(_world().get_tile_logic(_site["tile"])) == "dig", "G: C+Z harvested the dig tile")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "G: C+Z placed a structure")
	# Leave overworld-free so D can Z-harvest the same tile.
	_structure_layer().stop_build()


func _tap(action: String) -> void:
	if not SmokeTap.inject_press(action):
		_failures.append("injection: no key event is bound to %s" % action)
		return
	await get_tree().process_frame
	SmokeTap.inject_release(action)
	await get_tree().process_frame


func _tap_chord(first: String, second: String) -> void:
	if not SmokeTap.inject_press(first) or not SmokeTap.inject_press(second):
		_failures.append("injection: no key event is bound to %s+%s" % [first, second])
		return
	await get_tree().process_frame
	SmokeTap.inject_release(first)
	SmokeTap.inject_release(second)
	await get_tree().process_frame


func _tile_is_placeable(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")) == "" and str(logic.get("structure_id", "")) == "" and str(logic.get("landmark_id", "")) == ""


func _expect(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _structure_layer() -> Node: return _ctx["structure_layer"]
