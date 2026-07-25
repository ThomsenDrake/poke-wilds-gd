extends Node

# Wild-battle scenario extracted from phase0_scenarios.gd (the save-schema-v4
# fixture work needed the room; app line budget). Proves the Phase-0 0.1/0.5
# defects stay fixed: a full-party capture relocates to the campsite hold and is
# retrievable (mon_relocated / mon_retrieved), and a blackout heal restores full
# HP AND clears status/sleep_turns. Dispatch stays in phase0_scenarios (the
# `wild_battle` name is stable for the transports); phase0's forwarder adds this
# node to the smoke host so get_tree() and the host's _run_smoke_battle resolve.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")


func run(ctx: Dictionary) -> void:
	await get_tree().create_timer(0.2).timeout
	var runtime: Node = ctx["runtime"]
	var world: Node = ctx["world"]
	var player: Node = ctx["player"]
	var runner := SmokeScenarioRunner.new()
	var fail := ""
	var wild_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if wild_mon.is_empty():
		fail = "could not create a wild encounter"
	else:
		await get_parent()._run_smoke_battle(wild_mon)
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(false)
	runner.resync_player_tile(world, player, runtime)
	var party_before: Array = runner.swap_party(runtime, _species_sample(runtime, 6))
	runtime.session.add_item("poke_ball", 5)
	var cursor := runner.trace_log_line_count()
	var target: Dictionary = _guaranteed_capture_mon(runtime)
	if fail.is_empty() and target.is_empty():
		fail = "no catalog species met the guaranteed-capture catch rate"
	if fail.is_empty():
		fail = _assert_campsite_capture(runtime, runner, target, cursor)
	if fail.is_empty():
		fail = _assert_defeat_clean_heal(runtime, runner)
	runner.resync_player_tile(world, player, runtime)
	runner.restore_party(runtime, party_before)
	if fail.is_empty():
		runtime.emit_trace("wild_battle_passed", "SmokeScenarios", {"campsite_hold": true, "defeat_heal": true})
	else:
		push_error("Wild battle scenario failed: %s" % fail)


func _assert_campsite_capture(runtime, runner, target: Dictionary, cursor: int) -> String:
	var session = runtime.session
	runtime.start_wild_battle(target)
	var caught: Dictionary = runtime.use_pokeball()
	var target_id := str(target.get("species_id", ""))
	if str(caught.get("outcome", "")) != "caught_box_full":
		return "full-party capture outcome was '%s', not caught_box_full" % str(caught.get("outcome", ""))
	var held: Array = session.get_campsite_pokemon()
	if session.campsite_count() != 1 or str(held[0].get("species_id", "")) != target_id:
		return "full-party capture did not land in the campsite hold"
	if not runner.trace_log_has_since("mon_relocated", cursor, {"species_id": target_id, "level": int(target.get("level", 1))}):
		return "no mon_relocated trace for the full-party capture"
	session.party.remove_at(session.party.size() - 1) # make room; retrieve via runtime (emits mon_retrieved)
	var retrieved: Dictionary = runtime.retrieve_campsite_mon(0)
	if retrieved.is_empty() or str(retrieved.get("species_id", "")) != target_id or session.campsite_count() != 0:
		return "campsite-held mon was not retrievable"
	if not runner.trace_log_has_since("mon_retrieved", cursor, {"species_id": target_id}):
		return "no mon_retrieved trace for the retrieval"
	return ""


func _assert_defeat_clean_heal(runtime, runner) -> String:
	runner.swap_party(runtime, _species_sample(runtime, 1))
	var sick: Dictionary = runtime.session.get_party_member(0)
	sick["status"] = "PSN"
	sick["sleep_turns"] = 2
	runtime.session.set_party_member(0, sick)
	var brute_id := str(runtime.catalog.species.keys()[0])
	var brute: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species(brute_id), 50, Callable(runtime.catalog, "get_move"))
	brute["max_hp"] = 9999
	brute["current_hp"] = 9999
	runtime.start_wild_battle(brute)
	runtime.battle_runtime._player_mon["current_hp"] = 0
	runtime.battle_runtime._player_mon["status"] = "PSN"
	runtime.battle_runtime._player_mon["sleep_turns"] = 2
	var result: Dictionary = runtime.perform_battle_move(_safe_move_index(runtime.battle_runtime._player_mon))
	if str(result.get("outcome", "")) != "defeat":
		return "defeat path reached outcome '%s'" % str(result.get("outcome", ""))
	for mon in runtime.session.party:
		if str(mon.get("status", "")) != "" or int(mon.get("sleep_turns", 0)) != 0:
			return "blackout heal left status '%s' / sleep_turns %d" % [str(mon.get("status", "")), int(mon.get("sleep_turns", 0))]
		if int(mon.get("current_hp", 0)) != int(mon.get("max_hp", 1)):
			return "blackout heal did not restore full HP"
	return ""


# A damaging move that cannot restore the fainted player mon (heal/leech would stall the defeat path).
func _safe_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var effect := str((moves[i] as Dictionary).get("effect", ""))
		if int(moves[i].get("power", 0)) > 0 and int(moves[i].get("pp", 0)) > 0 and effect != "EFFECT_LEECH_HIT" and effect != "EFFECT_HEAL":
			return i
	return 0


# 1 HP + asleep + catch_rate >= 192 pins capture probability at 1.0 (deterministic).
func _guaranteed_capture_mon(runtime) -> Dictionary:
	for entry in runtime.catalog.species.values():
		if entry is Dictionary and int((entry as Dictionary).get("catch_rate", 0)) >= 192:
			var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, 3, Callable(runtime.catalog, "get_move"))
			if mon.is_empty():
				continue
			mon["max_hp"] = 2
			mon["current_hp"] = 1
			mon["status"] = "SLP"
			return mon
	return {}


func _species_sample(runtime, count: int) -> Array:
	var ids: Array = []
	for species_id in runtime.catalog.species.keys():
		ids.append(str(species_id))
		if ids.size() >= count:
			break
	return ids
