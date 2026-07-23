extends Node

# Placement-flow scenario for the building loop (spec:
# docs/product-specs/building-and-placement.md). Drives game_runtime.build_runtime:
# harvest->build (clear the build tiles via the REAL resolver so the logs are
# earned, not granted); refuse without materials / a Build-capable mon; place a
# wall + a door with exact structure_placed/materials_consumed payloads + bag
# drops; occupancy blocking pathing (wall rejects a step, door accepts one);
# persistence across a save round-trip on the v3-additive "structures" key; and
# the softlock fix (placement_flow_demolition.gd): the four-wall self-trap is
# refused would_trap and build->demolish->refund round-trips the full cost with
# the clear fact intact (app never imports domain; save guard: the dispatcher).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const PlacementFlowDemolition := preload("res://scripts/app/placement_flow_demolition.gd")

const SCAN_RADIUS := 40
const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _placed_sprites := {} # tile -> prop_path captured at placement, matched after reload

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(_runtime(), ["MACHOP", "BULBASAUR"])
	var pair := _find_build_pair(_player().tile_position)
	if pair.is_empty():
		_failures.append("targets: no adjacent placeable/clearable build pair within %d rings" % SCAN_RADIUS)
	else:
		var wall_tile: Vector2i = pair["wall"]
		var door_tile: Vector2i = pair["door"]
		_harvest_for_materials(wall_tile, door_tile)
		_check_refusals(wall_tile)
		_check_place(wall_tile, door_tile)
		await _check_occupancy(wall_tile, door_tile)
		var save_ok := _check_persistence(wall_tile, door_tile)
		PlacementFlowDemolition.new().run(_ctx, _runner, _failures, wall_tile, door_tile)
		if _failures.is_empty():
			_runtime().emit_trace("placement_flow_passed", "SmokeScenarios", {
				"wall_tile": [wall_tile.x, wall_tile.y], "door_tile": [door_tile.x, door_tile.y], "save_ok": save_ok, "demolish_ok": _failures.is_empty()})
	_runner.restore_party(_runtime(), party_before)
	_player().encounter_chance = saved_chance
	if not _failures.is_empty():
		_runtime().warn("PlacementFlowScenario", "Placement flow failed: %s." % "; ".join(PackedStringArray(_failures)), {})

# Cut any tree on a build tile (clearing it); else cut a spare, so >=1 log is earned via the resolver.
func _harvest_for_materials(wall_tile: Vector2i, door_tile: Vector2i) -> void:
	var cursor := _runner.trace_log_line_count()
	var earned := 0
	for tile in [wall_tile, door_tile]:
		if HarvestResolver.action_for_tile(_world().get_tile_logic(tile)) != "cut":
			continue
		var before: int = _runtime().get_item_count("log")
		var result: Dictionary = _runtime().harvest_tile(tile)
		if bool(result.get("ok", false)) and str(result.get("yield_item", "")) == "log":
			earned += _runtime().get_item_count("log") - before
	if earned == 0:
		var spare := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "cut")
		if not spare.is_empty() and bool(_runtime().harvest_tile(spare["tile"]).get("ok", false)):
			earned += 1
	await get_tree().create_timer(0.1).timeout
	if earned == 0:
		_failures.append("harvest: no build log could be earned via the resolver")
	elif not _runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut", "yield": "log"}):
		_failures.append("harvest: no field_move_used cut trace for the earned log")

# Empty bag + capable party -> missing_materials; Grass party + materials -> not_capable (capability first).
func _check_refusals(wall_tile: Vector2i) -> void:
	if not _failures.is_empty():
		return
	for item_id in ["dry_soil", "hard_stone"]:
		_runtime().session.remove_item(item_id, _runtime().get_item_count(item_id))
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = _runtime().build_runtime.try_place(wall_tile, "wall", _runtime().get_party_snapshot()[0])
	_assert_refusal(result, cursor, wall_tile, "missing_materials", "refuse-materials")
	if not _failures.is_empty():
		return
	_grant_materials()
	_runner.swap_party(_runtime(), ["CHIKORITA"])
	cursor = _runner.trace_log_line_count()
	result = _runtime().build_runtime.try_place(wall_tile, "wall", {})
	_assert_refusal(result, cursor, wall_tile, "not_capable", "refuse-capable")

func _assert_refusal(result: Dictionary, cursor: int, tile: Vector2i, reason: String, label: String) -> void:
	if bool(result.get("ok", true)) or str(result.get("reason", "")) != reason:
		_failures.append("%s: expected %s, got %s" % [label, reason, str(result)])
	elif not _runner.trace_log_has_since("structure_refused", cursor,
		{"structure_id": "wall", "tile": [tile.x, tile.y], "reason": reason}):
		_failures.append("%s: no structure_refused trace with the %s payload" % [label, reason])

# Restore the capable party and place wall + door; the wall tile must first be a walkable route (the "route now blocked" proof).
func _check_place(wall_tile: Vector2i, door_tile: Vector2i) -> void:
	if not _failures.is_empty():
		return
	_runner.swap_party(_runtime(), ["MACHOP", "BULBASAUR"])
	_grant_materials()
	if not _world().is_tile_walkable(wall_tile):
		_failures.append("place: the wall tile was not a walkable route before building")
		return
	_place_one(wall_tile, "wall")
	_place_one(door_tile, "door")

# Places one structure, asserts the exact bag drop + both build traces, and captures the sprite for the reload match.
func _place_one(tile: Vector2i, structure_id: String) -> void:
	if not _failures.is_empty():
		return
	var cost: Dictionary = _runtime().build_runtime.materials_for(structure_id, _world().get_tile_biome(tile))
	var before := {}
	for item_id in cost.keys():
		before[item_id] = _runtime().get_item_count(str(item_id))
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = _runtime().build_runtime.try_place(tile, structure_id, {})
	if not bool(result.get("ok", false)):
		_failures.append("place: %s refused (%s)" % [structure_id, str(result.get("reason", ""))])
		return
	for item_id in cost.keys():
		if _runtime().get_item_count(str(item_id)) != int(before[item_id]) - int(cost[item_id]):
			_failures.append("place: %s did not charge exactly %s of %s" % [structure_id, str(cost[item_id]), str(item_id)])
	_placed_sprites[tile] = str(_world().get_tile_logic(tile).get("prop_path", ""))
	if not _runner.trace_log_has_since("structure_placed", cursor, {"structure_id": structure_id, "tile": [tile.x, tile.y]}):
		_failures.append("place: no structure_placed trace for the %s" % structure_id)
	elif not _runner.trace_log_has_since("materials_consumed", cursor,
		{"structure_id": structure_id, "tile": [tile.x, tile.y], "items": cost}):
		_failures.append("place: no materials_consumed trace with the exact cost for the %s" % structure_id)

# The once-walkable wall tile is now solid (block reason + rejected step); the door stays a walkable opening (accepted step).
func _check_occupancy(wall_tile: Vector2i, door_tile: Vector2i) -> void:
	if not _failures.is_empty():
		return
	if _world().is_tile_walkable(wall_tile) or _world().get_traversal_block_reason(wall_tile).is_empty():
		_failures.append("occupancy: wall tile is walkable or has no block reason")
	elif not (await _probe(wall_tile, door_tile, false)):
		_failures.append("occupancy: a step into the wall tile was accepted")
	elif not _world().is_tile_walkable(door_tile):
		_failures.append("occupancy: door tile is not walkable")
	elif not (await _probe(door_tile, wall_tile, true)):
		_failures.append("occupancy: a step into the door tile did not pass")

# Steps from a stand neighbor (never the other build tile) toward tile; a solid tile rejects it, a walkable one lands on it.
func _probe(tile: Vector2i, exclude: Vector2i, expect_pass: bool) -> bool:
	var stand := _stand_for(tile, exclude)
	if stand.is_empty():
		return false
	_runner.teleport_player(_world(), _player(), _runtime(), stand["from_tile"])
	await get_tree().process_frame
	var accepted: bool = _player().smoke_step(stand["direction"])
	if not accepted:
		return not expect_pass and _player().tile_position == stand["from_tile"]
	await _player().tile_changed
	return expect_pass and _player().tile_position == tile

# Save -> reload via the runtime apply path -> rebuild: both tiles keep the exact placed sprite + occupancy and ride the structures key.
func _check_persistence(wall_tile: Vector2i, door_tile: Vector2i) -> bool:
	if not _failures.is_empty():
		return false
	var payload: Dictionary = _runner.save_and_reload(_world(), _runtime())
	var structures: Dictionary = payload.get("structures", {})
	var ok := int(payload.get("version", 0)) == SessionState.SAVE_VERSION
	for tile in [wall_tile, door_tile]:
		_world().sync_visible(tile)
		if not structures.has("%d,%d" % [tile.x, tile.y]):
			_failures.append("save: %s missing from the structures key" % str(tile))
			ok = false
	if not _reload_holds(wall_tile, false) or not _reload_holds(door_tile, true):
		ok = false
	return ok

func _reload_holds(tile: Vector2i, expect_walkable: bool) -> bool:
	var prop_path := str(_world().get_tile_logic(tile).get("prop_path", ""))
	var placed := str(_placed_sprites.get(tile, ""))
	var holds: bool = not prop_path.is_empty() and prop_path == placed and _world().is_tile_walkable(tile) == expect_walkable
	if not holds:
		_failures.append("save: %s did not keep its placed sprite + occupancy after reload" % str(tile))
	return holds

# Adjacent build pair near center: each tile is open ground or cut-clearable, each with a stand neighbor that is not the other tile.
func _find_build_pair(center: Vector2i) -> Dictionary:
	for ring in range(1, SCAN_RADIUS + 1):
		for tile in _runner.ring_around(center, ring):
			if tile == center:
				continue
			for direction in DIRS:
				var other: Vector2i = tile + direction
				if other == center or not _placeable_or_clearable(tile) or not _placeable_or_clearable(other):
					continue
				if not _stand_for(tile, other).is_empty() and not _stand_for(other, tile).is_empty():
					return {"wall": tile, "door": other}
	return {}

# Open ground the build loop accepts (walkable, no prop, no placement) or a tree a cut clears into it — can_place_on read off the view.
func _placeable_or_clearable(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	if HarvestResolver.action_for_tile(logic) == "cut":
		return true
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()

# First walkable neighbor of tile other than exclude + the step back toward tile.
func _stand_for(tile: Vector2i, exclude: Vector2i) -> Dictionary:
	for direction in DIRS:
		var neighbor: Vector2i = tile + direction
		if neighbor != exclude and _world().is_tile_walkable(neighbor):
			return {"from_tile": neighbor, "direction": -direction}
	return {}

# Tops the bag up so both placements are affordable in any biome; the exact-drop assertions read the cost table.
func _grant_materials() -> void:
	for item_id in ["log", "dry_soil", "hard_stone"]:
		_runtime().session.add_item(item_id, 6)

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
