extends Node

# The created-world legendary-dungeon journey for new_game_flow. It reuses the
# production DungeonRuntime facade (app -> runtime) rather than importing the
# domain directly: each generated entrance receives a real Main-routed step in,
# then a real step onto its authored exit. The existing legendary_dungeon gate
# retains battle, seal ladder, and persistence-depth ownership.

const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd")
const DungeonMaps := DungeonRuntime.DungeonMaps
const DungeonLayouts := DungeonRuntime.DungeonLayouts

const TABLET_SPECIES := ["REGIROCK", "REGICE", "REGISTEEL", "REGIELEKI", "REGIDRAGO"]

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary, runner, failures: Array, oks: Dictionary) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _oks = oks
	var start := _failures.size()
	var entrances := DungeonMaps.entrances_for_world(_runtime().get_world_seed())
	if not _validate_entrances(entrances):
		return
	for dungeon_id in DungeonMaps.DUNGEON_IDS: # frozen, deterministic roster order
		var entrance := _entrance_for(entrances, str(dungeon_id))
		if entrance.is_empty():
			_expect(false, "dungeon roster: %s has no generated entrance record" % str(dungeon_id))
			return
		if str(dungeon_id) == DungeonLayouts.SEAL_DUNGEON:
			await _sealed_round_trip(entrance)
		else:
			await _round_trip(entrance)
		if _failures.size() != start:
			return
	_oks["dungeon_warps_ok"] = true


# The source is precisely DungeonMaps.entrances_for_world: full frozen roster,
# no duplicate warp tiles, and live resolver stamps before a traversal begins.
func _validate_entrances(entrances: Array) -> bool:
	var expected: Array = DungeonMaps.DUNGEON_IDS
	var actual: Array = []
	var warps: Array = []
	_expect(entrances.size() == expected.size(), "dungeon roster: seed %d resolved %d records, not %d (%s)" % [_runtime().get_world_seed(), entrances.size(), expected.size(), str(entrances)])
	for entrance in entrances:
		var dungeon_id := str(entrance.get("dungeon_id", ""))
		var warp: Vector2i = entrance.get("warp_tile", Vector2i.ZERO)
		actual.append(dungeon_id)
		_expect(expected.has(dungeon_id), "dungeon roster: unexpected dungeon id '%s'" % dungeon_id)
		_expect(not warps.has(warp), "dungeon roster: %s reuses warp tile %s" % [dungeon_id, str(warp)])
		warps.append(warp)
		var live: Dictionary = _world().get_tile_logic(warp)
		_expect(bool(live.get("walkable", false)) and bool(live.get("dungeon_warp", false)) and str(live.get("dungeon_id", "")) == dungeon_id, "dungeon roster: live warp %s for %s lost its exact stamp (%s)" % [str(warp), dungeon_id, str(live)])
	for dungeon_id in expected:
		_expect(actual.count(dungeon_id) == 1, "dungeon roster: expected exactly one %s in %s" % [str(dungeon_id), str(actual)])
	return _failures.is_empty()


func _entrance_for(entrances: Array, dungeon_id: String) -> Dictionary:
	for entrance in entrances:
		if str(entrance.get("dungeon_id", "")) == dungeon_id:
			return entrance
	return {}


# Teleport is positioning only, on the fixed facade's south approach. Both warp
# edges are real PlayerAvatar.smoke_step calls through Main's tile_changed route.
func _round_trip(entrance: Dictionary) -> bool:
	var start := _failures.size()
	var runtime = _runtime()
	var dungeon_id := str(entrance["dungeon_id"])
	var species_id := str(entrance["species_id"])
	var warp: Vector2i = entrance["warp_tile"]
	var approach := warp + Vector2i.DOWN
	_runner.teleport_player(_world(), _player(), runtime, approach)
	if not _expect(_player().input_enabled and bool(_world().get_tile_logic(approach).get("walkable", false)), "dungeon %s: south approach %s is not live-walkable/input-ready" % [dungeon_id, str(approach)]):
		return false
	var enter_cursor: int = _runner.trace_log_line_count()
	if not _expect(_player().smoke_step(Vector2i.UP), "dungeon %s: real entrance step from %s refused" % [dungeon_id, str(approach)]):
		return false
	await _player().tile_changed
	await get_tree().process_frame
	var spawn: Vector2i = DungeonMaps.spawn_tile_for(dungeon_id)
	var live: Dictionary = _world().get_tile_logic(spawn)
	_expect(str(runtime.session.active_area) == dungeon_id, "dungeon %s: active_area '%s' after entrance" % [dungeon_id, str(runtime.session.active_area)])
	_expect(runtime.session.player_tile == spawn and _player().tile_position == spawn, "dungeon %s: session/avatar did not land on spawn %s" % [dungeon_id, str(spawn)])
	_expect(str(live.get("dungeon_id", "")) == dungeon_id and bool(live.get("walkable", false)), "dungeon %s: live dungeon view at spawn %s is %s" % [dungeon_id, str(spawn), str(live)])
	_expect(_runner.trace_log_has_since("dungeon_entered", enter_cursor, {"dungeon_id": dungeon_id, "species_id": species_id, "entrance_tile": [warp.x, warp.y], "tile": [spawn.x, spawn.y]}), "dungeon %s: no exact dungeon_entered trace" % dungeon_id)
	if not runtime.dungeon_runtime.in_dungeon():
		return false
	var exit_tile: Vector2i = DungeonMaps.exit_tile_for(dungeon_id)
	var exit_step := exit_tile - spawn
	if not _expect(exit_step.length_squared() == 1, "dungeon %s: authored exit %s is not adjacent to spawn %s" % [dungeon_id, str(exit_tile), str(spawn)]):
		return false
	var exit_cursor: int = _runner.trace_log_line_count()
	if not _expect(_player().smoke_step(exit_step), "dungeon %s: real authored-exit step refused" % dungeon_id):
		return false
	await _player().tile_changed
	await get_tree().process_frame
	_expect(str(runtime.session.active_area) == "", "dungeon %s: active_area did not clear on exit" % dungeon_id)
	_expect(runtime.session.player_tile == warp and _player().tile_position == warp, "dungeon %s: exit did not return session/avatar to %s" % [dungeon_id, str(warp)])
	_expect(_runner.trace_log_has_since("dungeon_exited", exit_cursor, {"dungeon_id": dungeon_id, "reason": "exit", "tile": [warp.x, warp.y]}), "dungeon %s: no exact dungeon_exited trace" % dungeon_id)
	return _failures.size() == start


# Regigigas uses the same real-step round trip, preceded by a zero-tablet refusal.
# The fixture owns only the five tablet ids and restores their original counts.
func _sealed_round_trip(entrance: Dictionary) -> void:
	var runtime = _runtime()
	var tablets := _tablet_ids()
	var original: Array = []
	for tablet in tablets:
		var count: int = runtime.session.get_item_count(tablet)
		original.append(count)
		if count > 0:
			runtime.session.remove_item(tablet, count)
		_expect(runtime.session.get_item_count(tablet) == 0, "dungeon_regigigas: tablet fixture did not clear %s" % tablet)
	var warp: Vector2i = entrance["warp_tile"]
	var approach := warp + Vector2i.DOWN
	_runner.teleport_player(_world(), _player(), runtime, approach)
	var cursor: int = _runner.trace_log_line_count()
	if _expect(_player().smoke_step(Vector2i.UP), "dungeon_regigigas: sealed real entrance step refused"):
		await _player().tile_changed
		await get_tree().process_frame
		var missing := tablets.duplicate(); missing.sort()
		_expect(str(runtime.session.active_area) == "" and runtime.session.player_tile == warp and _player().tile_position == warp, "dungeon_regigigas: empty-tablet entry changed dungeon context or warp landing")
		_expect(_runner.trace_log_has_since("dungeon_entry_refused", cursor, {"dungeon_id": DungeonLayouts.SEAL_DUNGEON, "missing": missing}), "dungeon_regigigas: empty-tablet step emitted no exact seal refusal")
	for tablet in tablets:
		runtime.session.add_item(tablet, 1)
	await _round_trip(entrance)
	for index in range(tablets.size()):
		var tablet: String = tablets[index]
		var held: int = runtime.session.get_item_count(tablet)
		if held > 0:
			runtime.session.remove_item(tablet, held)
		if int(original[index]) > 0:
			runtime.session.add_item(tablet, int(original[index]))
		_expect(runtime.session.get_item_count(tablet) == int(original[index]), "dungeon_regigigas: tablet fixture leaked %s" % tablet)
	runtime.save_game() # Main saved the successful warp with fixtures; persist the restored bag.


func _tablet_ids() -> Array:
	var ids: Array = []
	for species_id in TABLET_SPECIES:
		ids.append(str(DungeonLayouts.TABLET_FOR_SPECIES[species_id]))
	return ids

func _expect(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
