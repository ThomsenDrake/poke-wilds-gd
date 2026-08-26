extends Node

# The biome smoke scenarios (probe + traverse) extracted from smoke_scenarios.gd for the
# app line budget (the seed_for_smoke pins on boot/overworld_step/menu_save grew that
# file). Behavior is unchanged: the probe validates the world invariants; the traverse
# walks to a biome change (forcing a crossing past 30 steps), trips the traversal gate,
# then proves a wild encounter + the smoke battle. Lazily hosted as a child of
# smoke_scenarios so the awaits have a tree.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const PIN := 2026080902 # seed_for_smoke pin (the new_game_flow precedent; NOT a double-run consumer): the traverse encounter + smoke battle ride the pinned stream — the probe draws nothing

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()


func run(scenario: String, ctx: Dictionary) -> void:
	_ctx = ctx
	_runtime().seed_for_smoke(PIN) # BEFORE the traverse draws: self-pinned, never the wall-clock randomize()
	match scenario:
		"biome_probe": await _scenario_biome_probe()
		"biome_traverse": await _scenario_biome_traverse()


func _scenario_biome_probe() -> void:
	await get_tree().create_timer(0.2).timeout
	var result = _world().validate_world_invariants()
	if bool(result.get("ok", false)):
		_runtime().emit_trace("biome_probe_passed", "SmokeScenarios", {"seed": int(result.get("seed", 0)), "spawn": result.get("spawn", []), "reachable": int(result.get("reachable", 0))})
	else:
		_runtime().warn("SmokeScenarios", "Biome probe failed invariants.", {"seed": int(result.get("seed", 0)), "failures": result.get("failures", [])})
	await get_tree().create_timer(0.2).timeout


func _scenario_biome_traverse() -> void:
	await get_tree().create_timer(0.2).timeout
	var start_biome = _world().get_tile_biome(_player().tile_position)
	var crossed = await _walk_until_biome_change(start_biome, 30)
	if not crossed:
		_force_biome_crossing(start_biome)
	_trigger_traversal_gate()
	var biome = _world().get_tile_biome(_player().tile_position)
	var wild_mon = _runtime().generate_wild_encounter(_player().tile_position, biome)
	if wild_mon.is_empty():
		_runtime().warn("SmokeScenarios", "Biome traverse could not create a wild encounter.", {})
		return
	await _run_smoke_battle(wild_mon)


func _run_smoke_battle(wild_mon: Dictionary) -> void:
	_call("set_battle", [true])
	_ctx["message_box"].hide_message()
	_ctx["music_router"].play_battle_track("wild")
	_ctx["battle_view"].start_wild_battle(wild_mon)
	_ctx["battle_view"].run_smoke_turn()
	await _await_battle_idle()
	if _ctx["battle_view"].visible:
		_ctx["battle_view"].run_smoke_escape()
		await _await_battle_idle()


func _await_battle_idle() -> void:
	var view: Node = _ctx["battle_view"]
	for _i in range(240):
		if not view.visible or not view.is_animating():
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _walk_until_biome_change(start_biome: String, max_steps: int) -> bool:
	var player = _player()
	var saved_encounter = player.encounter_chance
	player.encounter_chance = 0.0
	var crossed = false
	for _step in range(max_steps):
		var direction = _runner.find_walkable_step_direction(_world(), player.tile_position)
		if direction == Vector2i.ZERO or not player.smoke_step(direction):
			break
		await player.tile_changed
		crossed = _world().get_tile_biome(player.tile_position) != start_biome
		if crossed:
			break
	player.encounter_chance = saved_encounter
	return crossed


func _force_biome_crossing(start_biome: String) -> void:
	var center = _player().tile_position
	for radius in range(12, 26):
		for tile in _runner.ring_around(center, radius):
			if _world().is_tile_walkable(tile) and _world().get_tile_biome(tile) != start_biome:
				_runner.teleport_player(_world(), _player(), _runtime(), tile)
				return


func _trigger_traversal_gate() -> void:
	var pair = _runner.find_gated_pair(_world(), _player().tile_position, 20)
	if pair.is_empty():
		_runtime().warn("SmokeScenarios", "Biome traverse could not find a gated tile to block on.", {})
		return
	_runner.teleport_player(_world(), _player(), _runtime(), pair["from_tile"])
	_player().smoke_step(pair["direction"])


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
