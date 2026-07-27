extends Node

# Fishing flow scenario (Phase 5; spec: docs/product-specs/breeding-shinies-
# drops-fishing.md). Rods CRAFT at a lit campfire (logs EARNED via the Cut
# resolver + grant top-up); a shore cast facing WATER hooks from the rod's
# cumulative pool (fish_hooked; Beach-anchored table pinned as literals); the
# tier gate is the fishing.gd table (Super strictly contains Good contains Old
# — Qwilfish unreachable on Old); the hook battles via start_wild_battle;
# reseed -> identical species order. Casts ride the shared _rng.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const SEED := 2026072603
const TIER_SEED_BASE := 2026072630
const HOOKS_PER_TIER := 4
const CAST_CAP := 32
const WATER_SCAN_RADIUS := 96
const DAY_MINUTES := 600
const RODS := ["old_rod", "good_rod", "super_rod"]
# The fishing.gd TIER_POOLS pinned as literals (the Beach-scraped approximation).
const POOL_OLD := ["MAGIKARP", "TENTACOOL"]
const POOL_GOOD := ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA"]
const POOL_SUPER := ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA", "QWILFISH"]
const LEVEL_RANGE := {1: [3, 7], 2: [8, 14], 3: [15, 22]} # the documented per-tier bands

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _water := {}
var _first_batch: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
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
	if _failures.is_empty():
		refused_ok = _check_refusals(runtime)
	if _failures.is_empty():
		tier_ok = _check_tiers(runtime)
	if _failures.is_empty():
		battle_ok = _check_battle(runtime)
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
	var fire_tile := Sites.find_open_tile(_world(), _player().tile_position, 8)
	if fire_tile == Vector2i.ZERO:
		return _ensure(false, "rods: no open tile for the campfire within 8 rings")
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


# Each rod hooks only its cumulative pool; the tier-1 batch re-runs reseeded (exact order).
func _check_tiers(runtime) -> bool:
	var pools := {"old_rod": POOL_OLD, "good_rod": POOL_GOOD, "super_rod": POOL_SUPER}
	var tier := 0
	for rod_id in RODS:
		tier += 1
		for other in RODS:
			runtime.session.remove_item(other, runtime.get_item_count(other))
		runtime.session.add_item(rod_id, 1)
		runtime.seed_for_smoke(TIER_SEED_BASE + tier * 7919)
		var species := _hook_batch(runtime, rod_id, pools[rod_id], LEVEL_RANGE[tier])
		if species.size() != HOOKS_PER_TIER:
			return _ensure(false, "%s: %d hooks within %d casts, expected %d" % [rod_id, species.size(), CAST_CAP, HOOKS_PER_TIER])
		if tier == 1:
			_first_batch = species
	for rod_id in RODS: runtime.session.remove_item(rod_id, runtime.get_item_count(rod_id)) # determinism: reseeded tier-1 reproduces the identical order
	runtime.session.add_item("old_rod", 1)
	runtime.seed_for_smoke(TIER_SEED_BASE + 7919)
	var rerun := _hook_batch(runtime, "old_rod", POOL_OLD, LEVEL_RANGE[1])
	var ok := _ensure(rerun == _first_batch, "determinism: reseeded tier-1 draws %s != %s" % [str(rerun), str(_first_batch)])
	var fishing_domain = Phase5.fishing_domain() # the tier gate: domain pools nest strictly + the Beach unlock
	if fishing_domain != null and (fishing_domain as GDScript).has_method("pool_for"):
		var pool1: Array = (fishing_domain as GDScript).call("pool_for", 1)
		var pool3: Array = (fishing_domain as GDScript).call("pool_for", 3)
		ok = _ensure(pool1 == POOL_OLD, "tiers: domain pool 1 drifted from the pinned table") and ok
		ok = _ensure(pool3.has("QWILFISH") and not pool1.has("QWILFISH"), "tiers: Qwilfish is not a Super-only unlock") and ok
		ok = _ensure(int(((fishing_domain as GDScript).call("level_range_for", 3) as Array)[0]) > int(((fishing_domain as GDScript).call("level_range_for", 1) as Array)[1]), "tiers: the Super rod's band does not beat the Old rod's") and ok
	return ok


func _hook_batch(runtime, rod_id: String, pool: Array, level_band: Array) -> Array:
	var species: Array = []
	var water_types := {"WATER": true}
	for _cast in range(CAST_CAP):
		if species.size() >= HOOKS_PER_TIER:
			break
		var cursor := _runner.trace_log_line_count()
		var result: Dictionary = Phase5.cast_rod(runtime, _water["tile"])
		if not bool(result.get("ok", false)):
			if str(result.get("reason", "")) != "no_bite":
				_ensure(false, "cast: %s refused (%s)" % [rod_id, str(result.get("reason", ""))])
				return species
			continue
		var hooked := str(result.get("species_id", ""))
		species.append(hooked)
		var level := int((result.get("wild_mon", {}) as Dictionary).get("level", 0))
		_ensure(level >= int(level_band[0]) and level <= int(level_band[1]), "hook: %s level %d outside the %s band %s" % [hooked, level, rod_id, str(level_band)])
		_ensure(_runner.trace_log_has_since("fish_hooked", cursor, {"rod_id": rod_id, "species_id": hooked}), "hook: no fish_hooked trace for %s/%s" % [rod_id, hooked])
		_ensure(pool.has(hooked), "hook: %s is outside the %s pool %s" % [hooked, rod_id, str(pool)])
		var is_water := false
		for type_variant in (runtime.catalog.get_species(hooked) as Dictionary).get("types", PackedStringArray()):
			if water_types.has(str(type_variant).to_upper()): is_water = true
		_ensure(is_water, "hook: %s is not a WATER-type species" % hooked)
		_ensure((result.get("wild_mon", {}) as Dictionary).get("is_shiny", null) != null, "hook: the hooked mon carries no is_shiny flag (shiny hunts by water)")
	return species


func _check_battle(runtime) -> bool:
	for rod_id in RODS:
		runtime.session.remove_item(rod_id, runtime.get_item_count(rod_id))
	runtime.session.add_item("old_rod", 1)
	runtime.seed_for_smoke(TIER_SEED_BASE + 31337)
	var result := {}
	for _cast in range(CAST_CAP):
		result = Phase5.cast_rod(runtime, _water["tile"])
		if bool(result.get("ok", false)):
			break
	if not bool(result.get("ok", false)):
		return _ensure(false, "battle: no hook within %d casts" % CAST_CAP)
	var wild_mon: Dictionary = result.get("wild_mon", {})
	var cursor := _runner.trace_log_line_count()
	runtime.start_wild_battle(wild_mon)
	var escape: Dictionary = runtime.run_from_battle()
	var ok := _ensure(_runner.trace_log_has_since("encounter_started", cursor, {"species_id": str(wild_mon.get("species_id", ""))}), "battle: no encounter_started trace")
	ok = _ensure(bool(escape.get("finished", false)), "battle: the fishing encounter did not finish on escape") and ok
	ok = _ensure(_runner.trace_log_has_since("battle_finished", cursor), "battle: no battle_finished trace") and ok
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
