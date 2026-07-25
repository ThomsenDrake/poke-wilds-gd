extends Node

# Build/occupancy/save/demolish phases of the building playtest (spec:
# docs/product-specs/field-moves.md), the companion to build_house_flow_scenario.gd
# (the placement_flow -> placement_flow_demolition split for the app budget). Stamps
# the fixed HOUSE_PATTERN (roof cap + wall ring + one door => an enclosed interior)
# with EXACT per-piece cost drops + traces, proves occupancy (wall rejects a step,
# the door admits one and the interior is reached through it), persists across a save
# round-trip, then demolishes every piece with an EXACT full refund restoring the bag
# to its pre-build state. The site's biome is uniform (the orchestrator's site scan
# guarantees it), so the center biome prices every piece.

const HOUSE_PATTERN := {
	Vector2i(-1, -1): "roof", Vector2i(0, -1): "roof", Vector2i(1, -1): "roof",
	Vector2i(-1, 0): "wall", Vector2i(1, 0): "wall",
	Vector2i(-1, 1): "wall", Vector2i(0, 1): "door", Vector2i(1, 1): "wall",
}
const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _center := Vector2i.ZERO
var _placed: Array = [] # [{tile, id, cost}] in placement order
var _bag_pre_build: Dictionary = {} # the bag just before building; a full refund restores it


func run_phases(ctx: Dictionary, runner, failures: Array, center: Vector2i) -> Dictionary:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_center = center
	var oks := {}
	oks["placed"] = _build_house()
	if _failures.is_empty():
		oks["door_walkable"] = await _check_occupancy()
		oks["save_ok"] = _check_save()
		oks["refund_ok"] = _demolish_house()
	return oks


# Stamps the pattern (player parked outside so the wall ring never trips the
# would-trap guard); every piece must land with the exact cost drop + both traces.
func _build_house() -> bool:
	var runtime = _runtime()
	_bag_pre_build = runtime.session.bag.duplicate(true)
	_runner.teleport_player(_world(), _player(), runtime, _center + Vector2i(0, 2))
	runtime.session.player_tile = _center + Vector2i(0, 2)
	var biome: String = _world().get_tile_biome(_center)
	for offset in HOUSE_PATTERN.keys():
		var tile: Vector2i = _center + offset
		var id := str(HOUSE_PATTERN[offset])
		var cost: Dictionary = runtime.build_runtime.materials_for(id, biome)
		var before := {}
		for item_id in cost.keys():
			before[item_id] = runtime.get_item_count(str(item_id))
		var cursor: int = _runner.trace_log_line_count()
		var result: Dictionary = runtime.build_runtime.try_place(tile, id, {})
		if not _ensure(bool(result.get("ok", false)), "build: %s refused at %s (%s)" % [id, str(tile), str(result.get("reason", ""))]):
			return false
		_placed.append({"tile": tile, "id": id, "cost": cost})
		for item_id in cost.keys():
			_ensure(runtime.get_item_count(str(item_id)) == int(before[item_id]) - int(cost[item_id]), "build: %s did not charge exactly %s of %s" % [id, str(cost[item_id]), str(item_id)])
		_ensure(_runner.trace_log_has_since("structure_placed", cursor, {"structure_id": id, "tile": [tile.x, tile.y]}), "build: no structure_placed trace for the %s" % id)
		_ensure(_runner.trace_log_has_since("materials_consumed", cursor, {"structure_id": id, "tile": [tile.x, tile.y], "items": cost}), "build: no materials_consumed trace for the %s" % id)
	return true


# A wall rejects a step; the door admits one and the enclosed interior is reached
# by walking through it (the door is the ring's only walkable tile).
func _check_occupancy() -> bool:
	var runtime = _runtime()
	var wall_tile: Vector2i = _center + Vector2i(-1, 0)
	var door_tile: Vector2i = _center + Vector2i(0, 1)
	if not _ensure(not _world().is_tile_walkable(wall_tile) and not _world().get_traversal_block_reason(wall_tile).is_empty(), "occupancy: the wall tile is walkable or has no block reason"):
		return false
	if not _ensure(_world().is_tile_walkable(door_tile), "occupancy: the door tile is not walkable"):
		return false
	if not _ensure(not (await _probe(wall_tile)), "occupancy: a step into the wall was accepted"):
		return false
	if not _ensure(await _probe(door_tile), "occupancy: a step into the door did not land on it"):
		return false
	var interior := _center
	_runner.teleport_player(_world(), _player(), runtime, door_tile)
	await get_tree().process_frame
	var stepped: bool = _player().smoke_step(Vector2i.UP) # door (0,1) -> interior (0,0)
	if stepped:
		await _player().tile_changed
	return _ensure(stepped and _player().tile_position == interior, "occupancy: the interior is not reachable through the door")


# Steps from a walkable neighbor toward `tile`; returns whether the step lands on it.
func _probe(tile: Vector2i) -> bool:
	for dir in DIRS:
		var from: Vector2i = tile + dir
		if _world().is_tile_walkable(from):
			_runner.teleport_player(_world(), _player(), _runtime(), from)
			await get_tree().process_frame
			if _player().smoke_step(-dir):
				await _player().tile_changed
				return _player().tile_position == tile
			return false
	return false


# All eight pieces ride the structures save key; the door stays walkable on reload.
func _check_save() -> bool:
	var payload: Dictionary = _runner.save_and_reload(_world(), _runtime())
	var structures: Dictionary = payload.get("structures", {})
	var ok := true
	for entry in _placed:
		var tile: Vector2i = entry["tile"]
		_world().sync_visible(tile)
		if not structures.has("%d,%d" % [tile.x, tile.y]):
			ok = _ensure(false, "save: %s missing from the structures key" % str(tile))
	var door: Vector2i = _center + Vector2i(0, 1)
	return ok and _ensure(_world().is_tile_walkable(door), "save: the door is not walkable after reload")


# Demolish every piece: each refunds its EXACT cost; the bag returns to pre-build.
func _demolish_house() -> bool:
	var runtime = _runtime()
	for entry in _placed:
		var tile: Vector2i = entry["tile"]; var id := str(entry["id"]); var cost: Dictionary = entry["cost"]
		var cursor: int = _runner.trace_log_line_count()
		var result: Dictionary = runtime.build_runtime.try_demolish(tile, {})
		if not _ensure(bool(result.get("ok", false)), "demolish: %s at %s refused" % [id, str(tile)]):
			return false
		_ensure(_runner.trace_log_has_since("structure_demolished", cursor, {"structure_id": id, "tile": [tile.x, tile.y], "refund": cost}), "demolish: no structure_demolished trace for the %s" % id)
		_ensure(_runner.trace_log_has_since("materials_refunded", cursor, {"structure_id": id, "tile": [tile.x, tile.y], "items": cost}), "demolish: no materials_refunded trace for the %s" % id)
	var bag_after: Dictionary = runtime.session.bag.duplicate(true)
	for entry in _placed:
		var tile: Vector2i = entry["tile"]
		_ensure(str(_world().get_tile_logic(tile).get("structure_id", "")) == "" and _world().is_tile_walkable(tile), "demolish: %s did not revert to open ground" % str(tile))
	return _ensure(bag_after == _bag_pre_build, "demolish: the bag was not restored to its pre-build state (full refund)")


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
