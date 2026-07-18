extends Node

# Smoke scenario orchestration extracted from the app scene so main.gd stays
# under its line budget. Hand-written scenarios live below; self-contained
# audit scenarios (nav/texture/data/layout audits, visual_sweep) dispatch
# through qa_scenarios.gd. Every non-playtest scenario runs inside the
# runner's save backup/restore guard; playtest_* scenarios guard themselves.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const PlaytestScenarios := preload("res://scripts/app/playtest_scenarios.gd")
const QaScenarios := preload("res://scripts/app/qa_scenarios.gd")

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _playtests: Node = null


func run(scenario: String, ctx: Dictionary) -> void:
	_ctx = ctx
	var guard_save := not scenario.begins_with("playtest_")
	if guard_save:
		_runner.backup_save()
	if QaScenarios.handles(scenario):
		await QaScenarios.run(scenario, self, _ctx)
	else:
		match scenario:
			"boot":
				await get_tree().create_timer(0.4).timeout
			"overworld_step":
				await _scenario_overworld_step()
			"menu_save":
				await _scenario_menu_save()
			"wild_battle":
				await _scenario_wild_battle()
			"biome_probe":
				await _scenario_biome_probe()
			"biome_traverse":
				await _scenario_biome_traverse()
			"field_move":
				await _scenario_field_move()
			"playtest_journey":
				await _playtest_scenarios().run_journey(_ctx)
			"playtest_soak":
				await _playtest_scenarios().run_soak(_ctx)
			_:
				_runtime().warn("SmokeScenarios", "Unknown smoke scenario requested.", {"scenario": scenario})
				await get_tree().create_timer(0.2).timeout
	if guard_save:
		_runner.restore_save()
	get_tree().quit()


func _scenario_overworld_step() -> void:
	await get_tree().create_timer(0.2).timeout
	var direction = _runner.find_safe_step_direction(_world(), _player(), _runtime())
	if direction == Vector2i.ZERO:
		_runtime().warn("SmokeScenarios", "Smoke scenario could not find a safe overworld step.", {})
	elif _player().smoke_step(direction):
		await _player().tile_changed
	await get_tree().create_timer(0.2).timeout


func _scenario_menu_save() -> void:
	await get_tree().create_timer(0.2).timeout
	_call("toggle_menu")
	await get_tree().create_timer(0.2).timeout
	_start_menu().perform_save()
	await get_tree().create_timer(0.2).timeout
	_start_menu().hide_menu()
	await get_tree().create_timer(0.2).timeout


func _scenario_wild_battle() -> void:
	await get_tree().create_timer(0.2).timeout
	var wild_mon = _runtime().generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if wild_mon.is_empty():
		_runtime().warn("SmokeScenarios", "Smoke scenario could not create a wild encounter.", {})
		return
	await _run_smoke_battle(wild_mon)


func _scenario_field_move() -> void:
	await get_tree().create_timer(0.2).timeout
	var fail := ""
	var found = _runner.find_field_move_tile(_world(), _player().tile_position, 20, "cut")
	if found.is_empty():
		fail = "no cut-gated tile within 20 tiles of the player"
	var tile: Vector2i = found.get("tile", Vector2i.ZERO)
	var pre_unlocked = _runtime().is_field_move_unlocked("cut")
	var log_cursor = _runner.trace_log_line_count()
	if fail.is_empty() and not pre_unlocked and _world().is_tile_walkable(tile):
		fail = "cut-gated tile was already walkable before unlocking"
	if fail.is_empty():
		_call("field_move", ["cut"])
		await get_tree().create_timer(0.2).timeout
		if not _runtime().is_field_move_unlocked("cut"):
			fail = "cut stayed locked after the menu handler ran"
		elif not _world().is_tile_walkable(tile):
			fail = "cut-gated tile stayed blocked after unlocking"
		elif not _runner.trace_log_has_since("field_move_used", log_cursor, {"move_id": "cut"}):
			fail = "menu handler emitted no field_move_used trace"
	if fail.is_empty():
		_runtime().emit_trace("field_move_scenario_passed", "SmokeScenarios", {
			"move_id": "cut",
			"tile": [tile.x, tile.y],
			"pre_unlocked": pre_unlocked
		})
	else:
		_runtime().warn("SmokeScenarios", "Field move smoke scenario failed: %s." % fail, {"tile": [tile.x, tile.y]})
	await get_tree().create_timer(0.2).timeout


func _scenario_biome_probe() -> void:
	await get_tree().create_timer(0.2).timeout
	var result = _world().validate_world_invariants()
	if bool(result.get("ok", false)):
		_runtime().emit_trace("biome_probe_passed", "SmokeScenarios", {
			"seed": int(result.get("seed", 0)),
			"spawn": result.get("spawn", []),
			"reachable": int(result.get("reachable", 0))
		})
	else:
		_runtime().warn("SmokeScenarios", "Biome probe failed invariants.", {
			"seed": int(result.get("seed", 0)),
			"failures": result.get("failures", [])
		})
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
	_message_box().hide_message()
	_music_router().play_battle_track("wild")
	_battle_view().start_wild_battle(wild_mon)
	await get_tree().create_timer(0.2).timeout
	_battle_view().run_smoke_turn()
	await get_tree().create_timer(0.2).timeout
	if _battle_view().visible:
		_battle_view().run_smoke_escape()
		await get_tree().create_timer(0.2).timeout


func _walk_until_biome_change(start_biome: String, max_steps: int) -> bool:
	var player = _player()
	var saved_encounter = player.encounter_chance
	player.encounter_chance = 0.0
	var crossed = false
	for _step in range(max_steps):
		var direction = _runner.find_walkable_step_direction(_world(), player.tile_position)
		if direction == Vector2i.ZERO:
			break
		if not player.smoke_step(direction):
			break
		await player.tile_changed
		if _world().get_tile_biome(player.tile_position) != start_biome:
			crossed = true
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


# Lazily hosts the playtest entrypoints as a child so they can await the tree.
func _playtest_scenarios() -> Node:
	if _playtests == null:
		_playtests = PlaytestScenarios.new()
		add_child(_playtests)
	return _playtests


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _message_box() -> Node: return _ctx["message_box"]
func _music_router() -> Object: return _ctx["music_router"]
