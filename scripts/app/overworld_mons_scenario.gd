extends Node

# Overworld mons gate scenario (Phase 6; spec: docs/product-specs/overworld-pokemon.md
# § Smoke validation). Proof order: DETERMINISM FIRST — the pinned walk script's
# entity_set_hash is byte-identical across a double run on the crafted seed, and the
# CONTROL asserts N seeded wild draws are byte-identical with entities active vs inert
# (the shared _rng — the night_system wild-encounter stream — is provably unconsumed);
# then SPAWN (every biome shows roaming mons with correct dispositions — the live-
# catalog witness), CHARM-RECRUIT (Dedenne pacifies, calm window holds, dialogue Z
# recruits with the spawn-time rolls, the full-party refusal :262), HOSTILE ENGAGE
# (Attack provoked:false/NO buff :280; chase-catch provoked:true/+3 :284; the Repel
# seam ordering), EGG TAKE -> ALPHA (nest_found; the :248 Attack/TAKE binary; the
# guardian forced battle; the level-5 hatch), EVERY-creation shiny_rolled{origin:
# "overworld"}, and the transient save round-trip (party channels persist, NO entity
# key rides the payload). Check groups split into overworld_mons_checks.gd +
# overworld_mons_battle_checks.gd for the app line budget.
#
# The scenario OWNS the forced-battle seam: game_runtime's encounter_requested bridge
# is disconnected for the run (reconnected on exit), so arming pending never auto-
# starts main's battle presentation mid-check; battle resolution rides the runtime
# directly (battle_view is presentation, covered by the 22/23 sweep). Emits
# overworld_mons_passed/failed (the symmetric miss-002 contract).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")
const OverworldMonsChecks := preload("res://scripts/app/overworld_mons_checks.gd")
const OverworldMonsBattleChecks := preload("res://scripts/app/overworld_mons_battle_checks.gd")
const OverworldMonsDispositionChecks := preload("res://scripts/app/overworld_mons_disposition_checks.gd")

const SEED := 2026072711 # calibrated world seed (all 11 biomes found by the spoke scan — climate blobs under slice 2 — + the nest sequence)
const DAY_MINUTES := 600 # noon: the DAY label holds across the walks (no DAY<->NIGHT recompute)
const WALK_STEPS := 24 # the pinned step script for the determinism double run
const EXPECTED_OVERWORLD_BUILDS := 8 # charm recruits x2 + hostile seam battles x3 + Alpha + the guardian re-catch during the hatch drive + the save-case recruit

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _probe = OverworldMonsProbe.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _bridge_disconnected := false
var _start_cursor := 0

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	var mons: Object = runtime.get("overworld_mons_runtime")
	_start_cursor = _runner.trace_log_line_count()
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	_disconnect_bridge(runtime)
	var party_before: Array = runtime.session.party
	var checks := OverworldMonsChecks.new(); add_child(checks); checks.setup(_ctx, _runner, _failures, SEED)
	var battle_checks := OverworldMonsBattleChecks.new(); add_child(battle_checks); battle_checks.setup(_ctx, _runner, _failures, SEED)
	if _failures.is_empty():
		_oks["determinism_ok"] = _run_determinism(runtime, mons, checks)
	if _failures.is_empty():
		_oks["spawn_ok"] = await checks.run_spawn_case(runtime)
	if _failures.is_empty():
		_oks["charm_ok"] = await checks.run_charm_case(runtime)
	if _failures.is_empty():
		_oks["hostile_ok"] = await battle_checks.run_hostile_case(runtime)
	var shiny_ref := [true]
	if _failures.is_empty():
		_oks["egg_ok"] = await battle_checks.run_egg_case(runtime, shiny_ref)
	if _failures.is_empty() and bool(_oks.get("egg_ok", false)):
		_oks["save_ok"] = await _run_save_case(runtime, checks, battle_checks)
	if _failures.is_empty():
		var disp_checks := OverworldMonsDispositionChecks.new(); add_child(disp_checks); disp_checks.setup(_ctx, _runner, _failures, SEED)
		_oks["disposition_ok"] = disp_checks.run_cases(runtime, mons)
	# Tally AFTER the save case (its recruit is the final instance build of the run).
	var shiny_total := _probe.trace_count(_start_cursor, "shiny_rolled", {"origin": "overworld"})
	_oks["shiny_ok"] = bool(checks.shiny_ok) and shiny_ref[0] and shiny_total == EXPECTED_OVERWORLD_BUILDS
	if not _oks["shiny_ok"]: # miss-002 loudness: a payload boolean must never bury a failure (deep-dive finding)
		_failures.append("shiny: the every-creation shiny_rolled contract broke (checks %s, egg %s, total %d vs expected %d)" % [bool(checks.shiny_ok), shiny_ref[0], shiny_total, EXPECTED_OVERWORLD_BUILDS])
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("overworld_mons_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("overworld_mons_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("OverworldMonsScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("SmokeScenarios", "Overworld mons scenario failed.", {})
	mons.take_pending_encounter() # never leave an armed seam for the dispatcher's teardown
	mons.active = true
	_reconnect_bridge(runtime)
	runtime.session.party = party_before
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	runtime.session.repel_steps = 0
	runtime.session.time_of_day_minutes = DAY_MINUTES
	_world().set_time_of_day(DAY_MINUTES)

func _run_determinism(runtime, mons, checks: OverworldMonsChecks) -> bool:
	if not checks.craft(runtime):
		return _ensure(false, "determinism: the crafted state failed")
	var hashes_a := checks.walk_and_sample(runtime, mons, WALK_STEPS)
	var control_ok := checks.unconsumed_stream_control(runtime, mons)
	if not checks.craft(runtime):
		return _ensure(false, "determinism: the second crafted state failed")
	var hashes_b := checks.walk_and_sample(runtime, mons, WALK_STEPS)
	var nonempty := false
	for hash_value in hashes_a:
		nonempty = nonempty or not str(hash_value).is_empty()
	return _ensure(control_ok and hashes_a == hashes_b and nonempty, "determinism: the entity timeline diverged across the double run (or the window stayed empty)")

# The transient decision proven, not accidental: the party channels persist (a recruit
# + the hatched child) while NO entity state rides the save payload.
func _run_save_case(runtime, checks: OverworldMonsChecks, battle_checks: OverworldMonsBattleChecks) -> bool:
	if str(battle_checks.hatched_species).is_empty() or (checks.recruited_species as Array).is_empty():
		return _ensure(false, "save: the charm/egg cases left no witness to persist")
	runtime.session.party.remove_at(0) # free a slot without dropping the hatched witness
	var recruit := await _save_recruit(runtime)
	if recruit.is_empty():
		return false
	var payload: Dictionary = _runner.save_and_reload(_world(), runtime)
	var ok := _ensure(int(payload.get("world_seed", 0)) == SEED, "save: the world seed did not round-trip")
	for key in payload.keys():
		if str(key).contains("overworld") or str(key).contains("entit"):
			ok = _ensure(false, "save: entity state rides the save (%s) — the transient decision is broken" % str(key))
	var ids := {}
	var no_egg := true
	for mon in runtime.session.party:
		ids[str(mon.get("species_id", ""))] = true
		if bool(mon.get("is_egg", false)):
			no_egg = false
	ok = _ensure(ids.has(recruit), "save: the recruit did not survive the round-trip") and ok
	ok = _ensure(ids.has(str(battle_checks.hatched_species)), "save: the hatched child did not survive the round-trip") and ok
	return _ensure(no_egg, "save: an egg still rides the party after the round-trip") and ok

# Save-case witness: one more dialogue recruit on a synced window (no craft — the
# hatched-child witness must survive). Returns the recruited species id ("" on failure).
func _save_recruit(runtime) -> String:
	var mons: Object = runtime.get("overworld_mons_runtime")
	var spawn: Vector2i = _player().tile_position
	for anchor in [spawn, spawn + Vector2i(16, 0), spawn + Vector2i(0, 16), spawn + Vector2i(-16, 0)]:
		await get_tree().process_frame
		_runner.teleport_player(_world(), _player(), runtime, anchor)
		runtime.note_player_step(); runtime.note_player_step()
		for e in _probe.live(mons, anchor, 24):
			if str(e.get("kind", "")) != "mon" or str(e.get("state", "")) != "idle" or str(e.get("disposition", "")) != "FRIENDLY":
				continue
			for direction in [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]:
				if _world().is_tile_walkable(e.tile + direction):
					_runner.teleport_player(_world(), _player(), runtime, e.tile + direction)
					mons.call("note_faced_tile", e.tile)
					break
			var joined: Dictionary = mons.call("interact", e.tile)
			if bool(joined.get("ok", false)):
				return str(e.species_id)
			_ensure(false, "save: the witness recruit failed (%s)" % str(joined.get("reason", "")))
			return ""
	_ensure(false, "save: no friendly roamer to recruit")
	return ""


# main._on_entity_encounter consumes the seam for presentation; the scenario owns it instead.
func _disconnect_bridge(runtime) -> void:
	var target := Callable(runtime, "_on_entity_encounter")
	if runtime.overworld_mons_runtime.encounter_requested.is_connected(target):
		runtime.overworld_mons_runtime.encounter_requested.disconnect(target)
		_bridge_disconnected = true

func _reconnect_bridge(runtime) -> void:
	var target := Callable(runtime, "_on_entity_encounter")
	if _bridge_disconnected and not runtime.overworld_mons_runtime.encounter_requested.is_connected(target):
		runtime.overworld_mons_runtime.encounter_requested.connect(target)

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
