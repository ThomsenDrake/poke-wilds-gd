extends Node

# Field-move soak (Phase 4 addition B; spec: docs/product-specs/field-moves.md): a
# seeded soak that EXERCISES the field moves under the all-field-moves party, so the
# playtest harness covers the new field_move_runtime loops at depth (Workstream L.6).
# Self-guarded (playtest_ prefix => the dispatcher skips its save guard; this scenario
# owns backup_save/restore_save like journey/soak). Each iteration either drives a
# field move (PlaytestBot.try_random_field_move) or walks, under the bot's invariant +
# spatial checks; a final save round-trip must hold. Distinct from playtest_soak (which
# runs the FRESH-GAME starter party + STARTING_BAG under check_fresh_game): swapping the
# all-moves party in there would break those invariants, so this is its own scenario.
# Deterministic: FIELD_SOAK_SEED pins both the bot rng and seed_for_smoke's runtime rngs.

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const FIELD_SOAK_SEED := 2026072503
const ITERATIONS := 60
const DIRECTIONS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _bot = PlaytestBot.new()


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	_bot.backup_save()
	var rng := RandomNumberGenerator.new()
	rng.seed = FIELD_SOAK_SEED
	var runtime = _runtime()
	var fail := _fresh_game(runtime)
	if fail.is_empty():
		runtime.seed_for_smoke(FIELD_SOAK_SEED)
	var party_before: Array = FieldMovesParty.swap_in(runtime)
	if fail.is_empty():
		for problem in FieldMovesParty.verify(runtime):
			fail = "fixture: " + problem
	var stats := {"steps": 0, "field_moves_used": 0}
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var iterations := 0
	for i in range(ITERATIONS):
		if not fail.is_empty():
			break
		iterations += 1
		await get_tree().process_frame # serialize: settle any in-flight step so the walk count is deterministic
		if rng.randf() < 0.5:
			fail = _bot.try_random_field_move(runtime, _world(), _player(), _runner, rng, stats)
		elif _player().smoke_step(DIRECTIONS[rng.randi_range(0, DIRECTIONS.size() - 1)]):
			await _player().tile_changed
			stats["steps"] += 1
			_bot.note_spatial_step(_player(), _world())
		if fail.is_empty():
			fail = _bot.check_invariants(runtime)
	_player().encounter_chance = saved_chance
	_player().set_mounted(false)
	if fail.is_empty():
		var verify: Dictionary = _bot.verify_save_roundtrip(runtime)
		if not bool(verify.get("ok", false)):
			fail = "final save check: " + str(verify.get("fail", ""))
		if fail.is_empty() and _bot.spatial_violations > 0:
			fail = "spatial invariants violated %d time(s)" % _bot.spatial_violations
	FieldMovesParty.restore(runtime, party_before)
	_bot.restore_save()
	if fail.is_empty():
		runtime.emit_trace("playtest_field_soak_passed", "SmokeScenarios", {
			"seed": FIELD_SOAK_SEED, "iterations": iterations, "steps": int(stats["steps"]),
			"field_moves_used": int(stats["field_moves_used"]), "spatial_violations": _bot.spatial_violations})
	else:
		runtime.emit_trace("playtest_field_soak_failed", "SmokeScenarios", {"fail": fail, "seed": FIELD_SOAK_SEED})
		push_error("Playtest field soak failed at iteration %d: %s" % [iterations, fail])
	await get_tree().create_timer(0.1).timeout


# Fresh game through the runtime + the world resync main.gd performs. (No
# check_fresh_game here: the all-moves party replaces the starter immediately.)
func _fresh_game(runtime) -> String:
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	_runner.teleport_player(_world(), _player(), runtime, runtime.get_player_tile())
	_world().set_time_of_day(runtime.get_time_of_day_minutes())
	return ""


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
