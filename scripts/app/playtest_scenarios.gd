extends Node

# Automated in-game playtests dispatched from SmokeScenarios: run_journey plays
# a scripted full loop, run_soak a seeded random bot. Both restore the real
# save on every exit path; battle/invariant/save logic lives in PlaytestBot.

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const SOAK_SEED := 20260717
const SOAK_ITERATIONS := 150
const JOURNEY_STEPS := 5
const TERMINAL_OUTCOMES := ["victory", "caught", "caught_box_full", "defeat", "escaped"]
const DIRECTIONS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _bot = PlaytestBot.new()


func run_journey(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	_bot.backup_save()
	var outcome := ""
	var save_ok := false
	var fail := _fresh_game()
	if fail.is_empty():
		fail = await _journey_steps()
	if fail.is_empty():
		var battle := await _journey_battle()
		fail = str(battle.get("fail", ""))
		outcome = str(battle.get("outcome", ""))
	if fail.is_empty():
		fail = await _journey_menu()
	if fail.is_empty():
		var verify: Dictionary = _bot.verify_save_roundtrip(_runtime())
		save_ok = bool(verify.get("ok", false))
		fail = str(verify.get("fail", ""))
	_bot.restore_save()
	if fail.is_empty():
		_runtime().emit_trace("playtest_journey_passed", "SmokeScenarios", {
			"outcome": outcome, "steps": int(_runtime().session.total_steps),
			"party_size": _runtime().get_party_snapshot().size(), "save_ok": save_ok
		})
	else:
		push_error("Playtest journey failed: %s" % fail)
	await get_tree().create_timer(0.1).timeout


func run_soak(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	_bot.backup_save()
	var rng := RandomNumberGenerator.new()
	rng.seed = SOAK_SEED
	var stats := {"steps": 0, "battles": 0, "victories": 0, "catches": 0, "escapes": 0, "defeats": 0, "warnings": 0}
	var fail := _fresh_game()
	var warn_cursor := _runner.trace_log_line_count()
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var iterations := 0
	for i in range(SOAK_ITERATIONS):
		if not fail.is_empty():
			break
		iterations += 1
		fail = await _soak_iteration(rng, stats)
		if fail.is_empty():
			fail = _bot.check_invariants(_runtime())
	_player().encounter_chance = saved_chance
	if fail.is_empty():
		var verify: Dictionary = _bot.verify_save_roundtrip(_runtime())
		if not bool(verify.get("ok", false)):
			fail = "final save check: " + str(verify.get("fail", ""))
	stats["warnings"] = _bot.count_warnings_since(warn_cursor)
	_bot.restore_save()
	if fail.is_empty():
		_runtime().emit_trace("playtest_soak_passed", "SmokeScenarios", {
			"seed": SOAK_SEED, "iterations": iterations, "steps": int(stats["steps"]), "battles": int(stats["battles"]),
			"victories": int(stats["victories"]), "catches": int(stats["catches"]), "escapes": int(stats["escapes"]), "defeats": int(stats["defeats"])
		})
	else:
		push_error("Playtest soak failed at iteration %d: %s (warnings seen: %d)" % [iterations, fail, int(stats["warnings"])])
	await get_tree().create_timer(0.1).timeout


# Fresh game through the runtime, then the same world resync main.gd performs.
func _fresh_game() -> String:
	_runtime().new_game()
	_world().rebuild(_runtime().get_world_seed())
	_runner.teleport_player(_world(), _player(), _runtime(), _runtime().get_player_tile())
	_world().set_time_of_day(_runtime().get_time_of_day_minutes())
	return _bot.check_fresh_game(_runtime())


func _journey_steps() -> String:
	var steps_before: int = _runtime().session.total_steps
	var time_before: int = _runtime().get_time_of_day_minutes()
	var stepped := 0
	for _i in range(JOURNEY_STEPS):
		var direction := _runner.find_safe_step_direction(_world(), _player(), _runtime())
		if direction == Vector2i.ZERO:
			break
		if _player().smoke_step(direction):
			await _player().tile_changed
			stepped += 1
	if stepped == 0:
		return "could not take any overworld step"
	if int(_runtime().session.total_steps) != steps_before + stepped:
		return "total_steps did not advance with overworld steps"
	if _runtime().get_time_of_day_minutes() != posmod(time_before + stepped, SessionState.DAY_MINUTES):
		return "time_of_day_minutes did not advance with overworld steps"
	return ""


func _journey_battle() -> Dictionary:
	var wild_mon: Dictionary = _runtime().generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if wild_mon.is_empty():
		return {"fail": "could not create a wild encounter", "outcome": ""}
	var exp_before := _bot.total_party_exp(_runtime())
	_call("set_battle", [true])
	_message_box().hide_message()
	var result: Dictionary = _bot.play_scripted_battle(_runtime(), wild_mon)
	_call("set_battle", [false])
	_resync_player_tile()
	var outcome := str(result.get("outcome", ""))
	if not outcome in TERMINAL_OUTCOMES:
		return {"fail": "battle reached no terminal outcome (got '%s')" % outcome, "outcome": outcome}
	if outcome == "victory" and _bot.total_party_exp(_runtime()) <= exp_before:
		return {"fail": "victory awarded no EXP", "outcome": outcome}
	return {"fail": "", "outcome": outcome}


func _journey_menu() -> String:
	_call("toggle_menu")
	await get_tree().create_timer(0.2).timeout
	var fail := ""
	var snapshot: Array = _runtime().get_party_snapshot()
	if snapshot.size() > 1:
		fail = await _swap_lead_via_party_screen(snapshot)
	_call("toggle_menu")
	await get_tree().create_timer(0.2).timeout
	return fail


# Drives the same handlers the party screen's input path uses to SWAP LEAD.
func _swap_lead_via_party_screen(before: Array) -> String:
	_start_menu()._activate_entry(0) # POKEMON entry; opens the party screen
	await get_tree().process_frame
	var party_screen := _start_menu().get_node_or_null("PartyScreen")
	if party_screen == null:
		_runtime().set_party_lead(1)
	else:
		party_screen._move(1)
		party_screen._confirm() # open the action menu (SWAP LEAD preselected)
		party_screen._confirm() # activate SWAP LEAD
		party_screen._back() # close the party screen
	await get_tree().process_frame
	var after: Array = _runtime().get_party_snapshot()
	if after.size() != before.size() or after[0] != before[1]:
		return "party lead did not change after the swap"
	return ""


func _soak_iteration(rng: RandomNumberGenerator, stats: Dictionary) -> String:
	var roll := rng.randf()
	if roll < 0.55: # walk; blocked moves are fine and expected
		var direction: Vector2i = DIRECTIONS[rng.randi_range(0, DIRECTIONS.size() - 1)]
		if _player().smoke_step(direction):
			await _player().tile_changed
			stats["steps"] += 1
		return ""
	if roll < 0.75: # force a wild encounter and auto-play it
		var wild_mon: Dictionary = _runtime().generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
		if wild_mon.is_empty():
			return ""
		_call("set_battle", [true])
		var result: Dictionary = _bot.play_random_battle(_runtime(), wild_mon, rng)
		_call("set_battle", [false])
		stats["battles"] += 1
		var outcome := str(result.get("outcome", ""))
		var counter := str({"victory": "victories", "caught": "catches", "caught_box_full": "catches", "escaped": "escapes", "defeat": "defeats"}.get(outcome, ""))
		if counter.is_empty():
			return "battle ended without a terminal outcome"
		stats[counter] += 1
		_resync_player_tile()
		return ""
	if roll < 0.85: # open and close the menu
		_call("toggle_menu")
		await get_tree().create_timer(0.1).timeout
		_call("toggle_menu")
		await get_tree().create_timer(0.1).timeout
		return ""
	if roll < 0.90: # save
		_runtime().save_game()
		return ""
	await get_tree().create_timer(0.05).timeout # idle
	return ""


# A defeat returns the player to the start; mirror the app-side resync.
func _resync_player_tile() -> void:
	if _runtime().get_player_tile() != _player().tile_position:
		_runner.teleport_player(_world(), _player(), _runtime(), _runtime().get_player_tile())


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _message_box() -> Node: return _ctx["message_box"]
