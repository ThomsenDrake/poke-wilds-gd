extends Node

# Breeding / drops / fishing soak (Phase 5, Workstream L.6 — the bot gains
# capabilities as phases land; spec: docs/product-specs/breeding-shinies-
# drops-fishing.md). Self-guarded (playtest_ prefix — the dispatcher skips its
# save guard; this scenario owns backup_save/restore_save like journey/soak)
# and qa-dispatched. A fresh game on the pinned seed builds a fence pen, pens a
# happy EEVEE pair (breeding cadence) + a MAGNEMITE (habitat drops), then soaks
# iterations of pen ticks / shore casts under the bot's invariant + breeding
# bands (egg cap, pasture bounds on the ONE shared store, the drop witness); a final
# save round-trip must hold. Determinism: seed_for_smoke BEFORE new_game makes
# even the world seed a function of the pin; the soak rng is seeded separately.

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const PlaytestBotBreeding := preload("res://scripts/runtime/playtest_bot_breeding.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const SOAK_SEED := 2026072607
const ITERATIONS := 40
const TICK_BATCH := 120 # one lay cadence per batch
const WATER_SCAN_RADIUS := 24
const DIRECTIONS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _bot = PlaytestBot.new()
var _band = PlaytestBotBreeding.new()


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	_bot.backup_save()
	var rng := RandomNumberGenerator.new()
	rng.seed = SOAK_SEED
	var runtime = _runtime()
	runtime.seed_for_smoke(SOAK_SEED) # before new_game: the world seed is pinned too
	var fail := _fresh_game(runtime)
	var stats := {"iterations": 0, "eggs_laid": 0, "drops": 0, "hooks": 0, "casts": 0}
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var cursor := _runner.trace_log_line_count()
	if fail.is_empty():
		fail = _setup_pen(runtime)
	var water := {}
	if fail.is_empty():
		water = Sites.find_water_tile(_world(), _player().tile_position, WATER_SCAN_RADIUS)
		if not water.is_empty():
			runtime.session.add_item("old_rod", 1)
	for i in range(ITERATIONS):
		if not fail.is_empty():
			break
		stats["iterations"] = int(stats["iterations"]) + 1
		var roll := rng.randf()
		if roll < 0.6:
			_band.tick_pen(runtime, TICK_BATCH)
		elif roll < 0.8 and not water.is_empty():
			_runner.teleport_player(_world(), _player(), runtime, water["stand"])
			var outcome := _band.try_fish_cast(runtime, water["tile"])
			stats["casts"] = int(stats["casts"]) + 1
			if outcome == "hooked":
				stats["hooks"] = int(stats["hooks"]) + 1
				_band.tick_pen(runtime, 1) # the hook consumes the pending seam on the next battle; tick keeps clocks moving
		elif _player().smoke_step(DIRECTIONS[rng.randi_range(0, DIRECTIONS.size() - 1)]):
			await _player().tile_changed
			_bot.note_spatial_step(_player(), _world())
		if fail.is_empty():
			fail = _bot.check_invariants(runtime)
		if fail.is_empty():
			fail = _band.check_breeding_invariants(runtime)
	stats["eggs_laid"] = _count_since("egg_laid", cursor)
	stats["drops"] = _count_since("item_dropped", cursor)
	if fail.is_empty():
		var verify: Dictionary = _bot.verify_save_roundtrip(runtime)
		if not bool(verify.get("ok", false)):
			fail = "final save check: " + str(verify.get("fail", ""))
		if fail.is_empty() and _bot.spatial_violations > 0:
			fail = "spatial invariants violated %d time(s)" % _bot.spatial_violations
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	_bot.restore_save()
	if fail.is_empty():
		runtime.emit_trace("playtest_breed_soak_passed", "SmokeScenarios", {"seed": SOAK_SEED,
			"iterations": int(stats["iterations"]), "eggs_laid": int(stats["eggs_laid"]),
			"drops": int(stats["drops"]), "hooks": int(stats["hooks"]), "casts": int(stats["casts"]),
			"spatial_violations": _bot.spatial_violations})
	else:
		runtime.emit_trace("playtest_breed_soak_failed", "SmokeScenarios", {"fail": fail, "seed": SOAK_SEED})
		push_error("Playtest breed soak failed at iteration %d: %s" % [int(stats["iterations"]), fail])
	await get_tree().create_timer(0.1).timeout


# Fresh game through the runtime + the world resync main.gd performs.
func _fresh_game(runtime) -> String:
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	_runner.teleport_player(_world(), _player(), runtime, runtime.get_player_tile())
	_world().set_time_of_day(runtime.get_time_of_day_minutes())
	return _bot.check_fresh_game(runtime)


# Grant + build the pen, pen a happy EEVEE pair (breeding) and a happy MAGNEMITE
# (habitat drops). The starter stays in the party (the last-member guard).
func _setup_pen(runtime) -> String:
	var get_move := Callable(runtime.catalog, "get_move")
	# MACHOP = the BUILD capability for the fence ring (the starter may lack it).
	runtime.session.party.append(runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("MACHOP"), 30, get_move, runtime._rng))
	Sites.grant_pen_materials(runtime)
	var center := Sites.find_pen_site(_world(), _player().tile_position, 160)
	if center == Vector2i.ZERO:
		return "no pen site within 160 rings of the fresh spawn"
	if not bool(Sites.build_pen(runtime, center).get("ok", false)):
		return "the pen build was refused"
	Phase5.invalidate_pen_cache(runtime)
	var anchor := Phase5.pen_key_for(runtime, center)
	if anchor.is_empty():
		return "the breeding runtime detects no pen at the fenced ring"
	var pair: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", 30, ["female", "male"])
	if pair.size() != 2:
		return "no male+female EEVEE within 128 creations"
	# Append + deposit the pair FIRST (the last-slot deposit loop must see the
	# eevees, not whatever is appended afterwards).
	runtime.session.party.append(pair["female"])
	runtime.session.party.append(pair["male"])
	_runner.teleport_player(_world(), _player(), runtime, center)
	for _i in range(2):
		var deposit: Dictionary = Phase5.pasture_deposit(runtime, runtime.session.party.size() - 1)
		if not bool(deposit.get("ok", false)):
			return "eevee deposit refused (%s)" % str(deposit.get("reason", ""))
	if not Phase5.poke_pasture_happiness(runtime, anchor, 255):
		return "happiness poke found no penned eevees"
	# The drops-side mon: a MAGNEMITE on the habitat runtime's pasture. Under the
	# ONE shared pasture store a FIELD-group mon (the old RATTATA) forms a SECOND
	# compatible pair with the EEVEEs — a third mon breaks attraction (faithful)
	# and the breeding cadence silently stops laying (eggs_laid = 0). MAGNEMITE
	# is genderless/Undiscovered (never pairs) yet satisfied on the basic floor
	# (ELECTRIC/STEEL -> recessive), so BOTH cadences run on the shared store.
	var drop_mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("MAGNEMITE"), 30, get_move, runtime._rng)
	runtime.session.party.append(drop_mon)
	var drop_index: int = runtime.session.party.size() - 1
	var drop_deposit: Dictionary = Phase5.habitat_deposit(runtime, drop_index, center)
	if not bool(drop_deposit.get("ok", false)):
		return "magnemite habitat deposit refused (%s)" % str(drop_deposit.get("reason", ""))
	# Poke the drops-side happiness too so the day cadence yields within the soak.
	var drop_anchor := str(drop_deposit.get("anchor", ""))
	var pastures: Dictionary = runtime.session.pastures if runtime.session.pastures is Dictionary else {}
	var entry: Dictionary = pastures.get(drop_anchor, {})
	for mon in (entry.get("mons", []) as Array):
		(mon as Dictionary)["happiness"] = 255
	return ""


func _count_since(event_name: String, from_line: int) -> int:
	var count := 0
	if not FileAccess.file_exists(SmokeScenarioRunner.TRACE_LOG_PATH):
		return 0
	var file := FileAccess.open(SmokeScenarioRunner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return 0
	var lines := file.get_as_text().split("\n", false)
	file.close()
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if parsed is Dictionary and str((parsed as Dictionary).get("event", "")) == event_name:
			count += 1
	return count


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
