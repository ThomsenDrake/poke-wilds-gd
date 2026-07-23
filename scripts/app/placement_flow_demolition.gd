extends RefCounted

# Demolition + self-trap checks for the placement_flow scenario (spec:
# docs/product-specs/building-and-placement.md). Extracted from
# placement_flow_scenario.gd for the app-layer line budget (the same extraction
# rationale as field_action_router.gd). Three proofs: (1) the exact softlock
# attempt — a standing player faces N/E/S/W and places a wall on each side; the
# first three are accepted (each leaves an exit) and the ENCLOSING fourth is
# refused with would_trap, consuming nothing and leaving no placement; (2) the
# build->demolish->refund round-trip — Cut (or Smash for a hard-stone desert
# shell) via the Z-action harvest path AND via the build runtime refunds the
# exact cost_for, leaves the tile walkable open ground again, and the tile's
# clear fact survives (demolition removes the placement entry only); (3) the
# load-bearing material->demolition WITNESS invariant — every shell class has a
# cost material only its demolish move yields, so the region enclosure the guard
# allows stays escapable. The app layer never imports domain: the required move
# is read off the cost table the build runtime exposes (a hard_stone cost implies
# smash, anything else cut), and the clear-fact check rides the build runtime's
# public tile_has_clear seam (never the generator's private members).

const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const SCAN_RADIUS := 40

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = []


func run(ctx: Dictionary, runner, failures: Array, wall_tile: Vector2i, door_tile: Vector2i) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_check_would_trap()
	_check_demolish_round_trip(wall_tile, door_tile)
	_check_desert_smash_round_trip()
	_check_demolish_invariant()


# The exact softlock attempt: teleport onto an open tile with four bare
# neighbors and wall in each faced side; the fourth (enclosing) wall must be
# refused would_trap, then the first three are demolished back out.
func _check_would_trap() -> void:
	if not _failures.is_empty():
		return
	var center := _find_trap_center(_player().tile_position)
	if center.is_empty():
		_failures.append("trap: no walkable tile with four bare neighbors within %d rings" % SCAN_RADIUS)
		return
	_runner.swap_party(_runtime(), ["MACHOP", "BULBASAUR", "GEODUDE"])
	_grant_materials()
	_runner.teleport_player(_world(), _player(), _runtime(), center["tile"])
	var placed: Array = []
	for direction in DIRS:
		var tile: Vector2i = center["tile"] + direction
		var before := _bag_snapshot({"log": 0, "dry_soil": 0, "hard_stone": 0})
		var cursor: int = _runner.trace_log_line_count()
		var result: Dictionary = _runtime().build_runtime.try_place(tile, "wall", {})
		if placed.size() < 3:
			if not bool(result.get("ok", false)):
				_failures.append("trap: wall %d of 4 refused (%s); the footprint was not open" % [placed.size() + 1, str(result.get("reason", ""))])
				break
			placed.append(tile)
			continue
		if bool(result.get("ok", false)) or str(result.get("reason", "")) != "would_trap":
			_failures.append("trap: the enclosing wall was not refused with would_trap (got %s)" % str(result))
		elif not _runner.trace_log_has_since("structure_refused", cursor, {"structure_id": "wall", "tile": [tile.x, tile.y], "reason": "would_trap"}):
			_failures.append("trap: no structure_refused trace with the would_trap payload")
		elif not str(_world().get_tile_logic(tile).get("structure_id", "")).is_empty():
			_failures.append("trap: the refused wall still stamped a placement")
		elif _bag_snapshot(before) != before:
			_failures.append("trap: the refused wall consumed materials")
	for tile in placed:
		if not bool(_runtime().harvest_tile(tile).get("ok", false)):
			_failures.append("trap: cleanup demolition of %s was refused" % str(tile))


# Nearest walkable tile whose four neighbors are all bare open ground (walkable,
# no prop, no placement) — placeable as-is, so the trap needs no harvesting.
func _find_trap_center(center: Vector2i) -> Dictionary:
	for ring in range(0, SCAN_RADIUS + 1):
		for tile in _runner.ring_around(center, ring):
			if not _world().is_tile_walkable(tile):
				continue
			var open := true
			for direction in DIRS:
				var logic: Dictionary = _world().get_tile_logic(tile + direction)
				if not bool(logic.get("walkable", false)) or not str(logic.get("prop_path", "")).is_empty() or not str(logic.get("structure_id", "")).is_empty():
					open = false
					break
			if open:
				return {"tile": tile}
	return {}


# build->demolish->refund round-trip on the scenario's wall + door tiles: the
# wall falls to the Z-action harvest path (what overworld Z drives), the door to
# the build runtime directly; each refunds its exact cost_for, leaves open
# ground, and the wall tile's clear fact (when it had one) survives.
func _check_demolish_round_trip(wall_tile: Vector2i, door_tile: Vector2i) -> void:
	if not _failures.is_empty():
		return
	var wall_cost: Dictionary = _runtime().build_runtime.materials_for("wall", _world().get_tile_biome(wall_tile))
	if wall_cost.has("hard_stone"):
		# A Cut-only mon cannot bring down a hard-stone shell (Smash is required).
		var party: Array = _runtime().get_party_snapshot()
		var refused: Dictionary = _runtime().build_runtime.try_demolish(wall_tile, party[1] if party.size() > 1 else {})
		if bool(refused.get("ok", false)):
			_failures.append("demolish: a Cut-only mon demolished a hard-stone shell")
	var wall_had_clear: bool = _runtime().build_runtime.tile_has_clear(wall_tile)
	_demolish_one(wall_tile, "wall", true)
	_demolish_one(door_tile, "door", false)
	if wall_had_clear and not _runtime().build_runtime.tile_has_clear(wall_tile):
		_failures.append("demolish: demolition destroyed the wall tile's clear fact")
	elif wall_had_clear and str(_world().get_tile_logic(wall_tile).get("override_kind", "")) != "cleared":
		_failures.append("demolish: the wall tile did not revert to its cleared ground")


func _demolish_one(tile: Vector2i, structure_id: String, via_harvest: bool) -> void:
	if not _failures.is_empty():
		return
	var cost: Dictionary = _runtime().build_runtime.materials_for(structure_id, _world().get_tile_biome(tile))
	var expected_move := "smash" if cost.has("hard_stone") else "cut"
	var before := _bag_snapshot(cost)
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = _runtime().harvest_tile(tile) if via_harvest else _runtime().build_runtime.try_demolish(tile)
	if not bool(result.get("ok", false)) or str(result.get("move_id", "")) != expected_move:
		_failures.append("demolish: the %s was not demolished by %s (got %s)" % [structure_id, expected_move, str(result)])
		return
	for item_id in cost.keys():
		if _runtime().get_item_count(str(item_id)) != int(before[item_id]) + int(cost[item_id]):
			_failures.append("demolish: the %s did not refund exactly %s of %s" % [structure_id, str(cost[item_id]), str(item_id)])
	var logic: Dictionary = _world().get_tile_logic(tile)
	if not _world().is_tile_walkable(tile) or not str(logic.get("structure_id", "")).is_empty() or not str(logic.get("prop_path", "")).is_empty():
		_failures.append("demolish: the %s tile is not open ground again" % structure_id)
	elif not _runner.trace_log_has_since("structure_demolished", cursor, {"structure_id": structure_id, "tile": [tile.x, tile.y], "refund": cost}):
		_failures.append("demolish: no structure_demolished trace with the exact %s refund" % structure_id)
	elif not _runner.trace_log_has_since("materials_refunded", cursor, {"structure_id": structure_id, "tile": [tile.x, tile.y], "items": cost}):
		_failures.append("demolish: no materials_refunded trace for the %s" % structure_id)


# Contract witness for the load-bearing region-seal escape (spec:
# building-and-placement.md): every demolition move has a cost material only that
# move yields, so a party that could gather the build materials can always
# demolish its way out of a region the would-trap guard deliberately allows.
func _check_demolish_invariant() -> void:
	if not _failures.is_empty():
		return
	var missing: Array = _runtime().build_runtime.unwitnessed_demolish_moves()
	if not missing.is_empty():
		_failures.append("invariant: shell classes with no harvest-witnessed material: %s" % str(missing))


# Live desert build->smash->refund round trip: the GRASSLAND spawn resolves the
# wall/door round trip to Cut, so the hard_stone Smash branch only runs when a
# stone shell is actually built and smashed here. Skips (never fails) when the
# seed has no desert within reach — the static witness invariant still covers it.
func _check_desert_smash_round_trip() -> void:
	if not _failures.is_empty():
		return
	var spawn: Vector2i = _runtime()._world_gen.find_walkable_spawn(_runtime().get_world_seed())
	var tile := _find_desert_tile(spawn)
	if tile == Vector2i.MAX:
		return
	var party_before: Array = _runner.swap_party(_runtime(), ["MACHOP", "GEODUDE"])
	var cost: Dictionary = _runtime().build_runtime.materials_for("wall", _world().get_tile_biome(tile))
	_grant_materials()
	var before := _bag_snapshot(cost)
	var cursor: int = _runner.trace_log_line_count()
	var placed: Dictionary = _runtime().build_runtime.try_place(tile, "wall", {})
	if not bool(placed.get("ok", false)):
		_failures.append("desert: the stone shell was not placed (got %s)" % str(placed))
	else:
		for item_id in cost.keys():
			if _runtime().get_item_count(str(item_id)) != int(before[item_id]) - int(cost[item_id]):
				_failures.append("desert: placing the stone shell did not charge exactly %s of %s" % [str(cost[item_id]), str(item_id)])
		var result: Dictionary = _runtime().build_runtime.try_demolish(tile)
		if not bool(result.get("ok", false)) or str(result.get("move_id", "")) != "smash":
			_failures.append("desert: the stone shell was not demolished by smash (got %s)" % str(result))
		else:
			for item_id in cost.keys():
				if _runtime().get_item_count(str(item_id)) != int(before[item_id]):
					_failures.append("desert: smashing the stone shell did not refund exactly %s of %s" % [str(cost[item_id]), str(item_id)])
			var logic: Dictionary = _world().get_tile_logic(tile)
			if not _world().is_tile_walkable(tile) or not str(logic.get("structure_id", "")).is_empty() or not str(logic.get("prop_path", "")).is_empty():
				_failures.append("desert: the stone-shell tile is not open ground again")
			elif not _runner.trace_log_has_since("structure_demolished", cursor, {"structure_id": "wall", "tile": [tile.x, tile.y], "refund": cost}):
				_failures.append("desert: no structure_demolished trace with the exact %s refund" % str(cost))
			elif not _runner.trace_log_has_since("materials_refunded", cursor, {"structure_id": "wall", "tile": [tile.x, tile.y], "items": cost}):
				_failures.append("desert: no materials_refunded trace for the stone shell")
	_runner.restore_party(_runtime(), party_before)


# Nearest placeable DESERT/SAND tile (a hard_stone shell) within SCAN_RADIUS of
# center; Vector2i.MAX when the seed carries no desert within reach.
func _find_desert_tile(center: Vector2i) -> Vector2i:
	for ring in range(0, SCAN_RADIUS + 1):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			var biome := str(logic.get("biome", ""))
			if (biome == "DESERT" or biome == "SAND") and _world().is_tile_walkable(tile) \
				and str(logic.get("prop_path", "")).is_empty() and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.MAX


func _bag_snapshot(cost: Dictionary) -> Dictionary:
	var snapshot := {}
	for item_id in cost.keys():
		snapshot[str(item_id)] = _runtime().get_item_count(str(item_id))
	return snapshot


func _grant_materials() -> void:
	for item_id in ["log", "dry_soil", "hard_stone"]:
		_runtime().session.add_item(item_id, 8)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
