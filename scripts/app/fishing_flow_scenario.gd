extends Node

# Fishing flow scenario (Phase 5; spec: docs/product-specs/breeding-shinies-
# drops-fishing.md). Rods CRAFT at a lit campfire (logs EARNED via the Cut
# resolver + grant top-up); a shore cast facing WATER hooks from the rod's
# cumulative pool (fish_hooked; Beach-anchored table pinned as literals); the
# tier gate is the fishing.gd table (Super strictly contains Good contains Old
# — Qwilfish unreachable on Old); the hook battles via start_wild_battle;
# reseed -> identical species order. Casts ride the shared _rng. Tier + battle
# checks live in fishing_flow_checks.gd (app line-budget extraction).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")
const FishingFlowChecks := preload("res://scripts/app/fishing_flow_checks.gd")

const SEED := 2026072603
const WATER_SCAN_RADIUS := 96
const DAY_MINUTES := 600
const RODS := ["old_rod", "good_rod", "super_rod"]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _water := {}


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game() # self-contained: world + spawn derive from the PINNED seed (the breed_flow
	# precedent; the double-run lane needs a pure function of (code, seed) — the boot world is
	# wall-clock, so under the lane's --fresh-save runs the cut/water tiles diverged per process)
	_world().rebuild(runtime.get_world_seed()) # mirror main.gd:_sync_world_from_runtime: new_game reseeds the authoritative generator but never the view
	_runner.teleport_player(_world(), _player(), runtime, _find_coastal_base(runtime)) # the pinned
	# spawn can land in treeless stretches; relocate to a water-adjacent stand that supports all
	# three resources — a pure traversal of the pinned world, so byte-stable across processes
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	# MACHOP = BUILD capability (campfire gate), CALYREX = Cut (the log witness).
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP", "CALYREX"], 30)
	if not Phase5.contract_problem(runtime).is_empty():
		_failures.append(Phase5.contract_problem(runtime))
	if runtime.session.get_active_party_index() < 0:
		_failures.append("fixture: no healthy party member for the fishing battle")
	var cast_ok := false
	var refused_ok := false
	var tier_ok := false
	var battle_ok := false
	if _failures.is_empty():
		cast_ok = _craft_the_rods(runtime)
	if _failures.is_empty():
		_water = Sites.find_water_tile(_world(), _player().tile_position, WATER_SCAN_RADIUS)
		if _water.is_empty():
			_failures.append("site: no water tile with a walkable stand within %d rings" % WATER_SCAN_RADIUS)
		else:
			_runner.teleport_player(_world(), _player(), runtime, _water["stand"])
	var checks := FishingFlowChecks.new()
	add_child(checks)
	checks.setup(_ctx, _runner, _failures, _water)
	if _failures.is_empty():
		refused_ok = _check_refusals(runtime)
	if _failures.is_empty():
		tier_ok = checks.run_tiers_case(runtime)
	if _failures.is_empty():
		battle_ok = checks.run_battle_case(runtime)
	if _failures.is_empty():
		runtime.emit_trace("fishing_flow_passed", "SmokeScenarios", {"cast_ok": cast_ok,
			"tier_ok": tier_ok, "refused_ok": refused_ok, "battle_ok": battle_ok, "seed": SEED})
	else:
		runtime.emit_trace("fishing_flow_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("FishingFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("FishingFlowScenario", "Fishing flow failed.", {})
	_clear_fishing_seam(runtime)
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	runtime.session.repel_steps = 0
	runtime.session.time_of_day_minutes = DAY_MINUTES


# A water-adjacent walkable stand (ring-out from the pinned spawn) with a cuttable
# tree within the 40-ring cut scan and open campfire ground within 24 rings. Pure
# tile-logic traversal of the pinned world → deterministic; the wall-clock boot
# world used to provide a coastal spawn by luck.
func _find_coastal_base(runtime) -> Vector2i:
	var origin: Vector2i = runtime.session.player_tile
	for r in range(1, 129):
		for tile in _runner.ring_around(origin, r):
			if str(_world().get_tile_logic(tile).get("biome", "")) != "WATER":
				continue
			for stand in [tile + Vector2i.UP, tile + Vector2i.DOWN, tile + Vector2i.LEFT, tile + Vector2i.RIGHT]:
				# generator logic, NOT world_view.is_tile_walkable — that reads the render cache
				# (synced to the wall-clock boot position pre-teleport → non-deterministic)
				if not bool(_world().get_tile_logic(stand).get("walkable", false)):
					continue
				if _runner.find_harvest_target(_world(), stand, 40, "cut").is_empty():
					continue
				if Sites.find_open_tile(_world(), stand, 24) == Vector2i.MAX:
					continue
				return stand
	return origin


# Earn a log via Cut (trace witness), fund the campfire + rod chain, craft all three.
func _craft_the_rods(runtime) -> bool:
	var cursor := _runner.trace_log_line_count()
	for _i in range(4):
		var target: Dictionary = _runner.find_harvest_target(_world(), _player().tile_position, 40, "cut")
		if not target.is_empty():
			runtime.harvest_tile(target["tile"])
	if not _ensure(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut", "yield": "log"}), "rods: no field_move_used{cut,log} trace"):
		return false
	Sites.grant_rod_materials(runtime)
	# Ring 24 (up from 8, Phase 7 Build 1): a landmark footprint can shadow the coast band — the scan must out-reach any footprint edge (world-depth.md § Landmarks).
	var fire_tile := Sites.find_open_tile(_world(), _player().tile_position, 24)
	if fire_tile == Vector2i.MAX:
		return _ensure(false, "rods: no open tile for the campfire within 24 rings")
	var placed: Dictionary = runtime.build_runtime.try_place(fire_tile, "campfire", {})
	if not bool(placed.get("ok", false)):
		return _ensure(false, "rods: campfire refused (%s)" % str(placed.get("reason", "")))
	var craft_cursor := _runner.trace_log_line_count()
	for rod_id in RODS:
		var result: Dictionary = runtime.crafting_runtime.craft(rod_id, "campfire")
		if not bool(result.get("ok", false)):
			return _ensure(false, "rods: %s craft refused (%s)" % [rod_id, str(result.get("reason", ""))])
	# The chain CONSUMES the lower rods, so exactly one super_rod remains.
	var ok := _ensure(runtime.get_item_count("super_rod") == 1, "rods: the super_rod count is not exactly one after the chain")
	for rod_id in RODS:
		ok = _ensure(_runner.trace_log_has_since("item_crafted", craft_cursor, {"output_id": rod_id, "station": "campfire"}), "rods: no item_crafted trace for %s" % rod_id) and ok
	return ok


# Rodless facing water -> no_rod; rod away from water -> no_water; both trace fishing_refused.
func _check_refusals(runtime) -> bool:
	for rod_id in RODS:
		runtime.session.remove_item(rod_id, runtime.get_item_count(rod_id))
	var cursor := _runner.trace_log_line_count()
	var rodless: Dictionary = Phase5.cast_rod(runtime, _water["tile"])
	var ok := _ensure(not bool(rodless.get("ok", true)) and str(rodless.get("reason", "")) == "no_rod", "refuse-no_rod: got %s" % str(rodless))
	ok = _ensure(_runner.trace_log_has_since("fishing_refused", cursor, {"reason": "no_rod"}), "refuse-no_rod: no fishing_refused trace") and ok
	runtime.session.add_item("old_rod", 1)
	cursor = _runner.trace_log_line_count()
	var dry: Dictionary = Phase5.cast_rod(runtime, _water["stand"])
	ok = _ensure(not bool(dry.get("ok", true)) and str(dry.get("reason", "")) == "no_water", "refuse-no_water: got %s" % str(dry)) and ok
	ok = _ensure(_runner.trace_log_has_since("fishing_refused", cursor, {"reason": "no_water"}), "refuse-no_water: no fishing_refused trace") and ok
	return ok


# Drains the pending-encounter seam so a hook never leaks into a later wild draw.
func _clear_fishing_seam(runtime) -> void:
	var rt = Phase5.fishing_rt(runtime)
	if rt == null: return
	if (rt as Object).has_method("take_pending_encounter"): (rt as Object).call("take_pending_encounter")
	if (rt as Object).has_method("consume_fishing_battle"): (rt as Object).call("consume_fishing_battle")


func _ensure(ok: bool, label: String) -> bool:
	if not ok: _failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
