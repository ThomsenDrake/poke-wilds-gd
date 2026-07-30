extends Node

# fishing_flow's tier + battle checks, EXTRACTED for the app line-budget wall
# (the breed_flow_checks / world_depth_checks precedent). The tier gate: each
# rod hooks ONLY its cumulative pool (fishing.gd table pinned as literals),
# levels ride the documented per-tier bands, a reseeded tier-1 batch reproduces
# the identical species order, and the domain pools nest strictly (Qwilfish a
# Super-only unlock). The battle case: a hooked mon rides the pending seam into
# start_wild_battle and finishes on escape.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")

const RODS := ["old_rod", "good_rod", "super_rod"]
# The fishing.gd TIER_POOLS pinned as literals (the Beach-scraped approximation).
const POOL_OLD := ["MAGIKARP", "TENTACOOL"]
const POOL_GOOD := ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA"]
const POOL_SUPER := ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA", "QWILFISH"]
const LEVEL_RANGE := {1: [3, 7], 2: [8, 14], 3: [15, 22]} # the documented per-tier bands
const TIER_SEED_BASE := 2026072630
const HOOKS_PER_TIER := 4
const CAST_CAP := 32

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _water := {}
var _first_batch: Array = []


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, water: Dictionary) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_water = water


# Each rod hooks only its cumulative pool; the tier-1 batch re-runs reseeded (exact order).
func run_tiers_case(runtime) -> bool:
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


func run_battle_case(runtime) -> bool:
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


func _ensure(ok: bool, label: String) -> bool:
	if not ok: _failures.append(label)
	return ok
