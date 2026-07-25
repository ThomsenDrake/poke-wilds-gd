extends Node

# Building playtest (Phase 4 addition B; spec: docs/product-specs/field-moves.md):
# the full build loop driven by the all-field-moves party — HARVEST build materials
# through the REAL resolver (so the first logs/soil are earned, not granted, with
# field_move_used traces), then BUILD a fixed "small house with a door", prove
# occupancy, persist across a save round-trip, and DEMOLISH every piece with an EXACT
# full refund (the build/occupancy/save/demolish phases live in build_house_flow_build
# for the app budget — the placement_flow -> placement_flow_demolition split). The site
# scan requires a uniform-biome 3x3 so one biome prices every piece. Seed-pinned,
# encounters zeroed, dispatcher save-guarded; build_house_failed + push_error on any
# non-pass (miss-002).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")
const BuildHouseFlowBuild := preload("res://scripts/app/build_house_flow_build.gd")

const SEED := 2026072502
const SCAN_RADIUS := 40
const DAY_MINUTES := 600
# House piece ids (BuildHouseFlowBuild.HOUSE_PATTERN values) for the material need.
const PIECE_IDS := ["roof", "roof", "roof", "wall", "wall", "wall", "wall", "door"]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _center := Vector2i.ZERO


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var party_before: Array = FieldMovesParty.swap_in(runtime)
	for problem in FieldMovesParty.verify(runtime):
		_failures.append("fixture: %s" % problem)
	if _failures.is_empty():
		_center = _find_house_center(_player().tile_position)
		if _center == Vector2i.ZERO:
			_failures.append("site: no uniform-biome placeable 3x3 within %d rings" % SCAN_RADIUS)
	if _failures.is_empty():
		_oks["harvest_ok"] = _harvest_materials()
	if _failures.is_empty():
		var build := BuildHouseFlowBuild.new()
		add_child(build)
		var phase_oks: Dictionary = await build.run_phases(_ctx, _runner, _failures, _center)
		for key in phase_oks.keys():
			_oks[key] = phase_oks[key]
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("build_house_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("build_house_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("BuildHouseFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("BuildHouseFlowScenario", "Build house flow failed.", {})
	FieldMovesParty.restore(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true


# Earn build materials through the real resolver (cut -> log, dig -> dry_soil),
# best-effort up to the house need, then top up any shortfall (the exact-drop +
# exact-refund assertions in the build companion are the load-bearing proof; the
# field_move_used traces prove the harvest seam).
func _harvest_materials() -> bool:
	var runtime = _runtime()
	var cursor: int = _runner.trace_log_line_count()
	var earned_log := _harvest_loop("cut", "log", PIECE_IDS.size())
	var earned_soil := _harvest_loop("dig", "", PIECE_IDS.size())
	_ensure(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut", "yield": "log"}), "harvest: no field_move_used{cut,log} trace")
	_ensure(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "dig"}), "harvest: no field_move_used{dig} trace")
	var biome: String = _world().get_tile_biome(_center)
	var need := {}
	for id in PIECE_IDS:
		var cost: Dictionary = runtime.build_runtime.materials_for(id, biome)
		for item_id in cost.keys():
			need[item_id] = int(need.get(item_id, 0)) + int(cost[item_id])
	for item_id in need.keys(): # top up any shortfall so the whole house is affordable
		var have: int = runtime.get_item_count(str(item_id))
		if have < int(need[item_id]):
			runtime.session.add_item(str(item_id), int(need[item_id]) - have)
	return _ensure(earned_log >= 1 and earned_soil >= 1, "harvest: no log/soil could be earned via the resolver")


# Harvests up to `cap` tiles for `action`, returning how many yielded an item.
func _harvest_loop(action: String, want_yield: String, cap: int) -> int:
	var earned := 0
	for _i in range(cap):
		var target: Dictionary = _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, action)
		if target.is_empty():
			break
		var result: Dictionary = _runtime().harvest_tile(target["tile"])
		if bool(result.get("ok", false)) and (want_yield.is_empty() or str(result.get("yield_item", "")) == want_yield):
			earned += 1
	return earned


# First 3x3 (by center) in ring order whose nine tiles are all open ground AND share
# one biome (uniformity keeps a single cost table valid for the whole house).
func _find_house_center(start: Vector2i) -> Vector2i:
	for ring in range(0, SCAN_RADIUS + 1):
		for tile in _runner.ring_around(start, ring):
			if _all_placeable(tile):
				return tile
	return Vector2i.ZERO


func _all_placeable(center: Vector2i) -> bool:
	var biome: String = _world().get_tile_biome(center)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var tile := center + Vector2i(dx, dy)
			if not _placeable(tile) or _world().get_tile_biome(tile) != biome:
				return false
	return true


func _placeable(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
