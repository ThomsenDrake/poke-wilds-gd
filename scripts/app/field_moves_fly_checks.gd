extends RefCounted

# Field-move FLY/TELEPORT lifecycle tails (group A companion, driven from the tail of
# field_moves_checks.check_fly so the flow scenario's plan list is untouched): with TWO
# or more way stones the LAST-registered ordering must hold (bare Teleport reaches the
# newest stone), Fly must REFUSE a DEMOLISHED stone, and both the survivor set and the
# ordering must hold across a save/reload of the structures key. The all-field-moves
# party is already swapped in by group A. Failures accumulate in the shared array (the
# first-failure latch is upstream — every miss is loud).

const WAYSTONE_ID := "way_stone" # structures.gd literal (app cannot preload domain)

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []


func run(ctx: Dictionary, runner, failures: Array, runtime, first_stone: Vector2i) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	var fmr = runtime.field_move_runtime
	# -- two stones, last-registered ordering ----------------------------------
	var second := _find_open_tile(first_stone)
	if not _ensure(second != Vector2i.MAX, "fly_lifecycle: no open tile for a second way stone"):
		return
	_ensure(bool(fmr.register_way_stone(second).get("ok", false)), "fly_lifecycle: the second way stone refused registration")
	_ensure(fmr.way_stone_tiles().size() >= 2, "fly_lifecycle: fewer than two way stones registered")
	_ensure(fmr.last_way_stone() == second, "fly_lifecycle: last_way_stone is not the LAST-registered stone")
	var teleported: Dictionary = fmr.use_teleport() # bare: the last-registered stone
	_ensure(bool(teleported.get("ok", false)) and Vector2i(teleported.get("tile", Vector2i.MAX)) == second, "fly_lifecycle: bare Teleport did not reach the last-registered stone")
	_runner.resync_player_tile(_world(), _player(), runtime)
	# -- fly to a DEMOLISHED stone must refuse ----------------------------------
	var demo: Dictionary = runtime.harvest_tile(second) # structures route to try_demolish
	_ensure(bool(demo.get("ok", false)), "fly_lifecycle: demolishing the second way stone refused (%s)" % str(demo.get("reason", "")))
	_ensure(not fmr.way_stone_tiles().has(second), "fly_lifecycle: a demolished stone lingered in way_stone_tiles")
	var refuse_cursor: int = _runner.trace_log_line_count()
	_ensure(not bool(fmr.use_fly(second).get("ok", true)), "fly_lifecycle: Fly accepted a DEMOLISHED stone")
	_ensure(_runner.trace_log_has_since("field_move_refused", refuse_cursor, {"move_id": "fly", "reason": "unvisited_way_stone"}), "fly_lifecycle: no unvisited_way_stone refusal for the demolished stone")
	# -- structures save/reload: the survivor + the ordering hold ---------------
	_runner.save_and_reload(_world(), runtime)
	_ensure(fmr.way_stone_tiles().has(first_stone), "fly_lifecycle: the surviving stone lost the structures round-trip")
	_ensure(not fmr.way_stone_tiles().has(second), "fly_lifecycle: the demolished stone resurrected on reload")
	_ensure(fmr.last_way_stone() == first_stone, "fly_lifecycle: last-registered ordering broke across the reload")
	var reload_cursor: int = _runner.trace_log_line_count()
	var flight: Dictionary = fmr.use_fly(first_stone)
	_ensure(bool(flight.get("ok", false)), "fly_lifecycle: Fly refused the surviving stone after reload")
	_ensure(_runner.trace_log_has_since("fly_used", reload_cursor, {"tile": [first_stone.x, first_stone.y]}), "fly_lifecycle: no fly_used trace after the reload")
	_runner.teleport_player(_world(), _player(), runtime, Vector2i(flight.get("tile", first_stone)))
	_runner.resync_player_tile(_world(), _player(), runtime)


# Walkable, prop-free, structure-free (the field_moves_checks._open shape) — nearest to
# the first stone so both stay inside the scenario's worked area.
func _find_open_tile(first_stone: Vector2i) -> Vector2i:
	for ring in range(2, 30):
		for tile in _runner.ring_around(first_stone, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.MAX # never ZERO — (0,0) is a real open tile


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
