extends Node

# Habitat drops scenario (Phase 5; spec: docs/product-specs/breeding-shinies-
# drops-fishing.md). Proves the FAITHFUL primary material source: a MILTANK
# penned on a satisfied basic-floor pen (habitat_happiness_changed{satisfied:
# true}, happiness gaining +4/hour tick) crosses an in-game day boundary and
# drops its material straight to the bag (item_dropped — the MILTANK species
# override replacing Normal manure with moo_moo_milk), the once-per-day cadence
# suppresses a same-day second drop and re-fires on the next boundary, the
# witness invariant holds (the habitat table never yields log/hard_stone — Rock
# drops are withheld, GEODUDE keeps only its Ground sand), and the unsatisfied
# control (an ODDISH pen without tall grass: no happiness gain, no drop) AND the
# Steel-type cadence-drop control (a MAGNEMITE's metal_coat + the flagged shiny_stone
# divergence, cadence suppression + re-arm) ride habitat_drops_checks.gd (the
# app-budget split). Determinism: the runtime rides
# NO rng — drops are a pure function of the lifetime step counter; encounters
# zeroed; dispatcher save guard restores the real save.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")
const HabitatDropsChecks := preload("res://scripts/app/habitat_drops_checks.gd")

const SEED := 2026072602
const MON_LEVEL := 30
const PEN_SCAN_RADIUS := 160
const DAY_STEPS := 1440 # one step = one clock minute (habitat_runtime.DAY_STEPS)
const DAY_MINUTES := 600
const MILK_ID := "moo_moo_milk"

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _pen_center := Vector2i.ZERO
var _anchor := ""


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP", "MILTANK"], MON_LEVEL) # MACHOP = build capability for the fences
	_witness(runtime)
	if _failures.is_empty():
		_build_the_pen(runtime)
	var satisfied_ok := false
	if _failures.is_empty():
		satisfied_ok = _pen_miltank(runtime)
	var drop_ok := false
	var milk_ok := false
	if _failures.is_empty():
		var drop: Dictionary = _cross_to_drop(runtime)
		drop_ok = bool(drop.get("drop_ok", false))
		milk_ok = bool(drop.get("milk_ok", false))
	var cadence_ok := false
	if _failures.is_empty():
		cadence_ok = _check_cadence(runtime)
	var witness_ok := false
	if _failures.is_empty():
		witness_ok = _check_witness(runtime)
	var unsatisfied_ok := false
	var steel_ok := false
	var rock_ground_ok := false
	if _failures.is_empty():
		var checks := HabitatDropsChecks.new(); add_child(checks); checks.setup(_ctx, _runner, _failures, _pen_center, _anchor)
		unsatisfied_ok = checks.run_unsatisfied_control(runtime)
		if _failures.is_empty():
			steel_ok = checks.run_steel_drop_control(runtime)
		if _failures.is_empty():
			rock_ground_ok = checks.run_rock_ground_witness(runtime)
	if _failures.is_empty():
		runtime.emit_trace("habitat_drops_passed", "SmokeScenarios", {"satisfied_ok": satisfied_ok,
			"drop_ok": drop_ok, "milk_ok": milk_ok, "cadence_ok": cadence_ok,
			"unsatisfied_ok": unsatisfied_ok, "steel_ok": steel_ok, "rock_ground_ok": rock_ground_ok,
			"witness_ok": witness_ok, "seed": SEED})
	else:
		runtime.emit_trace("habitat_drops_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("HabitatDropsScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("HabitatDropsScenario", "Habitat drops failed.", {})
	if _pen_center != Vector2i.ZERO:
		Sites.demolish_pen(runtime, _pen_center)
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	runtime.session.repel_steps = 0
	runtime.session.time_of_day_minutes = DAY_MINUTES


func _witness(runtime) -> void:
	if runtime.catalog.get_species("MILTANK").is_empty():
		_failures.append("fixture: MILTANK does not resolve in the catalog")
	var problem := Phase5.contract_problem(runtime)
	if not problem.is_empty():
		_failures.append(problem)
	if Phase5.habitat_rt(runtime) == null:
		_failures.append("contract: runtime.habitat_runtime is not wired (game_runtime setup)")


func _build_the_pen(runtime) -> void:
	Sites.grant_pen_materials(runtime)
	_pen_center = Sites.find_pen_site(_world(), _player().tile_position, PEN_SCAN_RADIUS)
	if _pen_center == Vector2i.ZERO:
		_failures.append("site: no grass-free placeable 5x5 within %d rings" % PEN_SCAN_RADIUS)
		return
	var built: Dictionary = Sites.build_pen(runtime, _pen_center)
	if not bool(built.get("ok", false)):
		_failures.append("pen: %s" % str(built.get("reason", "")))


# MILTANK (NORMAL -> basic-recessive) settles satisfied; the deposit traces the
# verdict and a happiness evaluation lands immediately.
func _pen_miltank(runtime) -> bool:
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = Phase5.habitat_deposit(runtime, _party_index_of(runtime, "MILTANK"), _pen_center)
	if not bool(result.get("ok", false)):
		return _ensure(false, "deposit: MILTANK refused (%s)" % str(result.get("reason", "")))
	_anchor = str(result.get("anchor", ""))
	if _anchor.is_empty():
		return _ensure(false, "deposit: no anchor returned")
	var ok := _ensure(bool(result.get("satisfied", false)), "deposit: a basic-floor pen evaluated unsatisfied for NORMAL")
	ok = _ensure(_runner.trace_log_has_since("pasture_deposited", cursor, {"species_id": "MILTANK"}), "deposit: no pasture_deposited trace") and ok
	ok = _ensure(_runner.trace_log_has_since("habitat_happiness_changed", cursor, {"species_id": "MILTANK", "satisfied": true}), "deposit: no habitat_happiness_changed trace") and ok
	# Each crossed in-game day boundary is a DAY tick: a comfortable mon gains
	# HABITAT_HAPPINESS_GAIN (10) toward the 220 drop gate.
	var happiness_before := _penned_happiness(runtime)
	_cross_days(runtime, 2)
	ok = _ensure(_penned_happiness(runtime) >= happiness_before + 10, "happiness: no gain over two day boundaries (%d -> %d)" % [happiness_before, _penned_happiness(runtime)]) and ok
	ok = _ensure(_runner.trace_log_has_since("habitat_happiness_changed", cursor, {"species_id": "MILTANK", "delta": 10}), "happiness: no habitat_happiness_changed{delta:10} trace") and ok
	return ok


# The drop fires once happiness reaches the 220 gate (+10 per comfortable day
# tick), then once per in-game day. Cross boundaries until it lands (capped).
func _cross_to_drop(runtime) -> Dictionary:
	var milk_before: int = runtime.get_item_count(MILK_ID)
	var cursor := _runner.trace_log_line_count()
	for _day in range(20):
		if _runner.trace_log_has_since("item_dropped", cursor, {"species_id": "MILTANK", "item_id": MILK_ID}):
			break
		_cross_days(runtime, 1)
	if not _runner.trace_log_has_since("item_dropped", cursor, {"species_id": "MILTANK", "item_id": MILK_ID}):
		_ensure(false, "drop: no item_dropped{MILTANK,%s} within 20 in-game days" % MILK_ID)
		return {"drop_ok": false, "milk_ok": false}
	var milk_ok := _ensure(runtime.get_item_count(MILK_ID) == milk_before + 1, "drop: bag gained %d %s, expected exactly 1" % [runtime.get_item_count(MILK_ID) - milk_before, MILK_ID])
	# The species override REPLACES manure: no manure event for MILTANK.
	var manure_ok := _ensure(not _runner.trace_log_has_since("item_dropped", cursor, {"species_id": "MILTANK", "item_id": "manure"}), "drop: MILTANK dropped manure despite the milk override")
	return {"drop_ok": true, "milk_ok": milk_ok and manure_ok}


# Same-day suppression + the next-day re-drop (the faithful once-per-day cadence).
func _check_cadence(runtime) -> bool:
	var same_day := clampi(_steps_to_next_day(runtime) - 2, 0, 120)
	var cursor := _runner.trace_log_line_count()
	Phase5.pen_tick(runtime, same_day)
	var ok := _ensure(not _runner.trace_log_has_since("item_dropped", cursor), "cadence: a second drop fired the same in-game day")
	var milk_before: int = runtime.get_item_count(MILK_ID)
	var cursor2 := _runner.trace_log_line_count()
	_cross_days(runtime, 1)
	ok = _ensure(_runner.trace_log_has_since("item_dropped", cursor2, {"species_id": "MILTANK", "item_id": MILK_ID}), "cadence: the next in-game day produced no drop") and ok
	ok = _ensure(runtime.get_item_count(MILK_ID) == milk_before + 1, "cadence: the next-day drop was not exactly one") and ok
	return ok


# The load-bearing witness (material_drops.gd invariant extended): the habitat
# drop economy never yields log/hard_stone — Rock drops withheld, dual Rock/
# Ground keeps only the sand.
func _check_witness(runtime) -> bool:
	var ok := _ensure(Phase5.drop_table_witness_clean(runtime), "witness: the habitat drop table yields log or hard_stone")
	var domain = Phase5.habitat_drops_domain(runtime)
	var geodude: Dictionary = runtime.catalog.get_species("GEODUDE")
	if not geodude.is_empty() and domain != null:
		var drops: Array = domain.call("drops_for", geodude)
		ok = _ensure(not drops.has("hard_stone") and drops.has("soft_sand"), "witness: GEODUDE drops %s, expected [soft_sand] only" % str(drops)) and ok
	return ok


func _steps_to_next_day(runtime) -> int:
	return DAY_STEPS - (int(runtime.session.total_steps) % DAY_STEPS)


# Crosses `count` in-game day boundaries (each = a day tick, the habitat model's
# comfort/happiness/drop cadence).
func _cross_days(runtime, count: int) -> void:
	for _i in range(count):
		Phase5.pen_tick(runtime, _steps_to_next_day(runtime) + 1)


# The ONE shared store: breeding_runtime._pastures IS runtime.session.pastures
# (reference identity) — this reads the breeding gate's live happiness too.
func _penned_happiness(runtime) -> int:
	var entry: Variant = runtime.session.pastures.get(_anchor, {})
	var mons: Variant = (entry as Dictionary).get("mons", []) if entry is Dictionary else []
	if mons is Array and not (mons as Array).is_empty():
		return int(((mons as Array)[0] as Dictionary).get("happiness", 0))
	return 0


func _party_index_of(runtime, species_id: String) -> int:
	for i in range(runtime.session.party.size()):
		if str((runtime.session.party[i] as Dictionary).get("species_id", "")) == species_id:
			return i
	return -1


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
