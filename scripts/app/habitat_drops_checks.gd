extends Node

# The unsatisfied control of habitat_drops (the app-budget split; spec:
# docs/product-specs/breeding-shinies-drops-fishing.md). An ODDISH (GRASS/
# POISON) penned on the SAME grass-free floor is UNSATISFIED (GRASS needs tall
# grass; the pen has none — dual-types would need BOTH tiles): its deposit
# evaluates satisfied=false, its happiness NEVER gains on the day tick (a
# comfortable mon would gain +10), and crossed day boundaries deliver NO drop
# (an uncomfortable mon forfeits its generated item — the faithful staleness
# quirk, observable because the port re-evaluates comfort each day tick).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const MON_LEVEL := 30
const DAY_STEPS := 1440

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _pen_center := Vector2i.ZERO
var _anchor := ""


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, pen_center: Vector2i, anchor: String) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_pen_center = pen_center
	_anchor = anchor


func run_unsatisfied_control(runtime) -> bool:
	if not _failures.is_empty():
		return false
	# MILTANK leaves first (its drop day stamp must not mask the control window).
	var mons: Array = _snapshot_mons(runtime)
	for index in range(mons.size() - 1, -1, -1):
		Phase5.pasture_withdraw(runtime, _anchor, index)
	var oddish: Dictionary = runtime.catalog.get_species("ODDISH")
	if oddish.is_empty():
		return _ensure(false, "control: ODDISH does not resolve in the catalog")
	var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(oddish, MON_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	runtime.session.party = [runtime.session.party[0] if not runtime.session.party.is_empty() else mon, mon]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = Phase5.habitat_deposit(runtime, 1, _pen_center)
	if not bool(result.get("ok", false)):
		return _ensure(false, "control: ODDISH deposit refused (%s)" % str(result.get("reason", "")))
	var ok := _ensure(not bool(result.get("satisfied", true)), "control: a grass-free pen evaluated SATISFIED for GRASS/POISON")
	ok = _ensure(_runner.trace_log_has_since("pasture_deposited", cursor, {"species_id": "ODDISH"}), "control: no pasture_deposited trace") and ok
	ok = _ensure(_runner.trace_log_has_since("habitat_happiness_changed", cursor, {"species_id": "ODDISH", "satisfied": false}), "control: no unsatisfied habitat_happiness_changed trace") and ok
	# Across THREE day boundaries (init + two ticks) the uncomfortable mon gains
	# NO happiness (a satisfied mon would gain +10 per tick) and drops NOTHING.
	var happiness_before := _penned_happiness(runtime)
	var drop_cursor := _runner.trace_log_line_count()
	_cross_days(runtime, 3)
	ok = _ensure(_penned_happiness(runtime) == happiness_before, "control: an unsatisfied mon gained happiness (%d -> %d)" % [happiness_before, _penned_happiness(runtime)]) and ok
	return _ensure(not _runner.trace_log_has_since("item_dropped", drop_cursor, {"species_id": "ODDISH"}), "control: an unsatisfied mon dropped anyway") and ok


# The Steel-type cadence drop (Phase 5 acquisition DIVERGENCE — wiki-materials.md:393
# documents Metal Coat ONLY; the shiny_stone + cadence are port-invented, flagged on
# habitat_drops.STEEL_STONE_DROP). A MAGNEMITE (ELECTRIC/STEEL — both basic-recessive,
# so the SAME grass-free pen satisfies it) pens after the ODDISH control leaves: the
# first happy drop day yields metal_coat AND magnet (the daily path, stones NEVER in
# drops_for) PLUS one shiny_stone (deposit stamps last_stone_day := -CADENCE, so the
# first drop day is stone-due); the NEXT day suppresses the stone (window 1 < 4) while
# materials keep dropping; three more crossed days re-arm it (window 4). Happiness is
# POKED (the documented seam; the real +10/day tick gain is proven by the MILTANK
# phase). NO rng: steel_stone_due is pure over (types, day, last_stone_day).
func run_steel_drop_control(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var mons: Array = _snapshot_mons(runtime)
	for index in range(mons.size() - 1, -1, -1):
		Phase5.pasture_withdraw(runtime, _anchor, index) # ODDISH (the control's residue) leaves
	var entry: Dictionary = runtime.catalog.get_species("MAGNEMITE")
	if entry.is_empty():
		return _ensure(false, "steel: MAGNEMITE does not resolve in the catalog")
	var ok := _ensure(entry.get("types", PackedStringArray()).has("STEEL"), "steel: MAGNEMITE lost its STEEL type (catalog drift)")
	ok = _ensure(Phase5.basic_ground_satisfies(runtime, "MAGNEMITE"), "steel: MAGNEMITE is not basic-ground-satisfied (the grass-free pen would confound the drop)") and ok
	var domain = Phase5.habitat_drops_domain(runtime)
	if domain == null:
		return _ensure(false, "steel: habitat_drops domain is missing")
	# Domain pins: the stone NEVER rides the daily path; the cadence gate is pure.
	ok = _ensure(domain.call("drops_for", entry) == ["magnet", "metal_coat"], "steel: drops_for(MAGNEMITE) != [magnet, metal_coat] (the stone leaked into the daily table)") and ok
	ok = _ensure(bool(domain.call("steel_stone_due", entry, 0, -4)), "steel: the cadence gate missed day 0 / last -4 (the first drop day must be stone-due)") and ok
	ok = _ensure(not bool(domain.call("steel_stone_due", entry, 3, 0)), "steel: the cadence gate fired inside the 4-day window (day 3 / last 0)") and ok
	ok = _ensure(bool(domain.call("steel_stone_due", entry, 4, 0)), "steel: the cadence gate missed the re-arm edge (day 4 / last 0)") and ok
	var miltank: Dictionary = runtime.catalog.get_species("MILTANK")
	ok = _ensure(not bool(domain.call("steel_stone_due", miltank, 100, -100)), "steel: the cadence gate fired for a non-Steel species") and ok
	if not ok:
		return false
	var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, MON_LEVEL, Callable(runtime.catalog, "get_move")) # no rng: the swap_party creation path
	runtime.session.party.append(mon)
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	var result: Dictionary = Phase5.habitat_deposit(runtime, runtime.session.party.size() - 1, _pen_center)
	if not bool(result.get("ok", false)):
		return _ensure(false, "steel: MAGNEMITE deposit refused (%s)" % str(result.get("reason", "")))
	ok = _ensure(bool(result.get("satisfied", false)), "steel: the grass-free pen evaluated unsatisfied for ELECTRIC/STEEL")
	ok = _ensure(Phase5.poke_pasture_happiness(runtime, _anchor, 220), "steel: the happiness poke found no penned MAGNEMITE") and ok
	var metal_before: int = runtime.get_item_count("metal_coat")
	var magnet_before: int = runtime.get_item_count("magnet")
	var stone_before: int = runtime.get_item_count("shiny_stone")
	var cursor := _runner.trace_log_line_count()
	_cross_days(runtime, 1) # the first drop day: daily materials AND the cadence stone
	ok = _ensure(_runner.trace_log_has_since("item_dropped", cursor, {"species_id": "MAGNEMITE", "item_id": "metal_coat"}), "steel: no item_dropped{MAGNEMITE,metal_coat} on the first drop day") and ok
	ok = _ensure(_runner.trace_log_has_since("item_dropped", cursor, {"species_id": "MAGNEMITE", "item_id": "shiny_stone"}), "steel: no item_dropped{MAGNEMITE,shiny_stone} on the first drop day") and ok
	ok = _ensure(runtime.get_item_count("metal_coat") == metal_before + 1 and runtime.get_item_count("magnet") == magnet_before + 1, "steel: the daily materials were not exactly one each") and ok
	ok = _ensure(runtime.get_item_count("shiny_stone") == stone_before + 1, "steel: the shiny_stone grant was not exactly one") and ok
	var suppress_cursor := _runner.trace_log_line_count()
	_cross_days(runtime, 1) # window 1 < 4: materials re-drop, the stone is suppressed
	ok = _ensure(_runner.trace_log_has_since("item_dropped", suppress_cursor, {"species_id": "MAGNEMITE", "item_id": "metal_coat"}), "steel: the next day dropped no metal_coat (the daily cadence broke)") and ok
	ok = _ensure(not _runner.trace_log_has_since("item_dropped", suppress_cursor, {"species_id": "MAGNEMITE", "item_id": "shiny_stone"}), "steel: a second shiny_stone fired inside the 4-day window") and ok
	ok = _ensure(runtime.get_item_count("shiny_stone") == stone_before + 1, "steel: the shiny_stone bag moved during suppression") and ok
	var rearm_cursor := _runner.trace_log_line_count()
	_cross_days(runtime, 3) # window 4: the cadence re-arms
	ok = _ensure(_runner.trace_log_has_since("item_dropped", rearm_cursor, {"species_id": "MAGNEMITE", "item_id": "shiny_stone"}), "steel: the shiny_stone did not re-arm after the 4-day window") and ok
	ok = _ensure(runtime.get_item_count("shiny_stone") == stone_before + 2, "steel: the re-armed shiny_stone grant was not exactly one") and ok
	# Witness honesty: the stone is habitat-yieldable (audit-complete) and the
	# log/hard_stone invariant still holds.
	ok = _ensure(bool(domain.call("is_habitat_drop_material", "shiny_stone")), "steel: shiny_stone is not auditable through is_habitat_drop_material") and ok
	ok = _ensure(bool(domain.call("witness_clean")), "steel: the habitat witness broke once the stone landed") and ok
	for index in range(_snapshot_mons(runtime).size() - 1, -1, -1):
		Phase5.pasture_withdraw(runtime, _anchor, index) # leave the pen as found (MAGNEMITE out)
	return ok


# habitat_runtime's pastures live on the session key — the ONE shared store
# breeding_runtime holds by reference (its snapshot deep-copies this dict).
func _snapshot_mons(runtime) -> Array:
	var entry: Variant = runtime.session.pastures.get(_anchor, {})
	var mons: Variant = (entry as Dictionary).get("mons", []) if entry is Dictionary else []
	return (mons as Array).duplicate() if mons is Array else []


func _penned_happiness(runtime) -> int:
	var mons := _snapshot_mons(runtime)
	return int((mons[0] as Dictionary).get("happiness", 0)) if not mons.is_empty() else 0


func _steps_to_next_day(runtime) -> int:
	return DAY_STEPS - (int(runtime.session.total_steps) % DAY_STEPS)


func _cross_days(runtime, count: int) -> void:
	for _i in range(count):
		Phase5.pen_tick(runtime, _steps_to_next_day(runtime) + 1)


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
