extends RefCounted

# Player-journey proof for the chamber encounter. The battle must start from a REAL avatar
# step through Main's tile_changed -> note_player_step -> encounter_requested bridge; direct
# attack_entity/generate_wild_encounter calls cannot prove that a normal party can engage it.

const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd")
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const DungeonMaps := DungeonRuntime.DungeonMaps


static func contact_battle_proof(runtime, species_id: String, player, world, battle_view, runner, failures: Array) -> bool:
	var start: int = failures.size()
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp := DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id)
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "contact: the warp into %s refused" % dungeon_id, failures):
		return false
	var chamber := DungeonMaps.chamber_tile_for(dungeon_id)
	var approach: Dictionary = runner.stand_spot(world, chamber)
	if not LegendarySpawnChecks.ensure(not approach.is_empty(), "contact: chamber %s has no walkable approach" % str(chamber), failures):
		runtime.dungeon_runtime.exit_dungeon(); return false
	runner.teleport_player(world, player, runtime, approach["from_tile"])
	var cursor: int = runner.trace_log_line_count()
	if not LegendarySpawnChecks.ensure(player.smoke_step(approach["direction"]), "contact: the real step onto %s refused" % str(chamber), failures):
		runtime.dungeon_runtime.exit_dungeon(); return false
	await player.tile_changed
	await player.get_tree().process_frame
	LegendarySpawnChecks.ensure(player.tile_position == chamber and runtime.session.player_tile == chamber, "contact: the avatar/session did not land on the chamber tile", failures)
	LegendarySpawnChecks.ensure(runtime.battle_runtime._active and battle_view.visible and not player.input_enabled, "contact: the real chamber step did not open the battle UI", failures)
	LegendarySpawnChecks.ensure(str(runtime.battle_runtime._enemy_mon.get("species_id", "")) == species_id, "contact: the normal bridge opened the wrong enemy", failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("legendary_encounter", cursor, {"species_id": species_id, "dungeon_id": dungeon_id}), "contact: no legendary_encounter trace from the normal bridge", failures)
	if runtime.battle_runtime._active:
		battle_view.run_smoke_escape()
		await player.get_tree().process_frame
		LegendarySpawnChecks.ensure(not runtime.battle_runtime._active and not battle_view.visible and player.input_enabled, "contact: the normal battle escape did not restore overworld input", failures)
	if runtime.dungeon_runtime.in_dungeon(): runtime.dungeon_runtime.exit_dungeon()
	return failures.size() == start


static func loaded_position_proof(runtime, species_id: String, player, world, runner, failures: Array) -> bool:
	var start: int = failures.size()
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	LegendarySpawnChecks.ensure(not bool(DungeonMaps.cell_for(dungeon_id, Vector2i.ZERO).get("walkable", true)), "load: the blocked-tile fixture stopped being blocked", failures)
	for bad_tile in [Vector2i(-999, -999), Vector2i.ZERO]:
		var payload: Dictionary = runtime.session.to_save_payload(runtime._world_gen.overrides_for_save(), runtime._world_gen.placements_for_save())
		payload["active_area"] = dungeon_id
		payload["player_x"] = bad_tile.x
		payload["player_y"] = bad_tile.y
		LegendarySpawnChecks.ensure(runtime._apply_loaded_payload(payload), "load: the production payload apply refused %s" % str(bad_tile), failures)
		world.rebuild(runtime.get_world_seed())
		runner.resync_player_tile(world, player, runtime)
		LegendarySpawnChecks.ensure(str(runtime.session.active_area) == dungeon_id, "load: a valid dungeon id was discarded", failures)
		LegendarySpawnChecks.ensure(runtime.session.player_tile == DungeonMaps.spawn_tile_for(dungeon_id), "load: invalid dungeon tile %s was not normalized to spawn" % str(bad_tile), failures)
	if runtime.dungeon_runtime.in_dungeon(): runtime.dungeon_runtime.exit_dungeon()
	world.rebuild(runtime.get_world_seed())
	runner.resync_player_tile(world, player, runtime)
	return failures.size() == start


static func provoked_interact_proof(runtime, species_id: String, player, world, battle_view, runner, failures: Array) -> bool:
	var start: int = failures.size()
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp := DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id)
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "interact: the warp into %s refused" % dungeon_id, failures): return false
	var chamber := DungeonMaps.chamber_tile_for(dungeon_id)
	var approach: Dictionary = runner.stand_spot(world, chamber)
	if approach.is_empty():
		failures.append("interact: chamber has no walkable faced-tile approach"); runtime.dungeon_runtime.exit_dungeon(); return false
	runner.teleport_player(world, player, runtime, approach["from_tile"])
	player._facing = approach["direction"]
	var cursor: int = runner.trace_log_line_count()
	var accumulated_before := Input.use_accumulated_input
	Input.use_accumulated_input = true
	await SmokeTap.tap(player.get_tree(), "action_a") # real Z -> Main poll -> field router -> entity interact
	Input.use_accumulated_input = accumulated_before
	LegendarySpawnChecks.ensure(runtime.battle_runtime._active and battle_view.visible and not player.input_enabled, "interact: real Z did not open the chamber battle", failures)
	LegendarySpawnChecks.ensure(str(runtime.battle_runtime._enemy_mon.get("species_id", "")) == species_id, "interact: the normal bridge opened the wrong enemy", failures)
	LegendarySpawnChecks.ensure(int(runtime.battle_runtime._enemy_mon.get("attack_stages", 0)) == 3, "interact: ordinary Z did not provoke the legendary's +3 stage", failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("legendary_encounter", cursor, {"species_id": species_id, "dungeon_id": dungeon_id}), "interact: no legendary_encounter trace from real Z", failures)
	if runtime.battle_runtime._active:
		battle_view.run_smoke_escape(); await player.get_tree().process_frame
	if runtime.dungeon_runtime.in_dungeon(): runtime.dungeon_runtime.exit_dungeon()
	return failures.size() == start
