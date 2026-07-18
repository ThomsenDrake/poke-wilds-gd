extends RefCounted

# Journey/soak engine behind scripts/app/playtest_scenarios.gd. Drives battles
# through the public GameRuntime API (the same methods live input uses), checks
# party/bag invariants, verifies save round-trips, and owns the save
# backup/restore discipline so playtests never clobber the player's save.

const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const BACKUP_PATH := "user://godot_port_save.json.playtest.bak"
const MAX_BATTLE_ROUNDS := 120
const JOURNEY_BALL_CAP := 5
const LOW_HP_PERCENT := 30
const CATCH_HP_PERCENT := 25

var _had_save := false

# Per-step spatial invariant violations seen by note_spatial_step; the soak
# reports the count and refuses to pass while it is above zero.
var spatial_violations := 0


# Per-step soak invariant (spec Lane 3): after a completed step the player's
# 16x16 world rect must not overlap the solid tile rect of any neighboring
# tile rendered with a blocking prop.
func note_spatial_step(player, world) -> void:
	var rect: Rect2 = player.world_rect()
	for offset in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var tile: Vector2i = player.tile_position + offset
		var logic: Dictionary = world.get_tile_logic(tile)
		if bool(logic.get("walkable", true)) or str(logic.get("prop_path", "")).is_empty():
			continue
		if rect.intersects(Rect2(world.map_to_world(tile), Vector2(world.TILE_SIZE, world.TILE_SIZE))):
			spatial_violations += 1


# Copies the real save aside; restore_save() must run on every exit path.
func backup_save() -> void:
	_had_save = false
	if not FileAccess.file_exists(SaveStore.SAVE_PATH):
		return
	var source := FileAccess.open(SaveStore.SAVE_PATH, FileAccess.READ)
	if source == null:
		return
	var bytes := source.get_buffer(source.get_length())
	source.close()
	var backup := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
	if backup == null:
		return
	backup.store_buffer(bytes)
	backup.close()
	_had_save = true


# Puts the original save back (or deletes the playtest save when none existed)
# and always removes the backup sibling.
func restore_save() -> void:
	if _had_save and FileAccess.file_exists(BACKUP_PATH):
		var source := FileAccess.open(BACKUP_PATH, FileAccess.READ)
		var restored := FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
		if source != null and restored != null:
			restored.store_buffer(source.get_buffer(source.get_length()))
		if source != null:
			source.close()
		if restored != null:
			restored.close()
	elif FileAccess.file_exists(SaveStore.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveStore.SAVE_PATH))
	if FileAccess.file_exists(BACKUP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP_PATH))


# "" when a fresh new game matches the documented starting state.
func check_fresh_game(runtime) -> String:
	var party: Array = runtime.get_party_snapshot()
	if party.is_empty():
		return "new game produced an empty party"
	var species_id := str(party[0].get("species_id", ""))
	if species_id.is_empty() or species_id == "SMOKE_MON":
		return "starter '%s' is not a real catalog species" % species_id
	if runtime.get_item_count("poke_ball") != int(SessionState.STARTING_BAG.get("poke_ball", 5)):
		return "new game bag does not start with poke_ball x5"
	if runtime.get_item_count("potion") != int(SessionState.STARTING_BAG.get("potion", 3)):
		return "new game bag does not start with potion x3"
	if runtime.get_time_of_day_minutes() != SessionState.NEW_GAME_TIME_OF_DAY:
		return "new game clock does not read %d" % SessionState.NEW_GAME_TIME_OF_DAY
	return ""


# Journey policy: first damaging move; potion when the active mon is about to
# faint; balls (capped) once the wild mon is below ~25% HP; run as last resort.
func play_scripted_battle(runtime, wild_mon: Dictionary) -> Dictionary:
	return _drive_battle(runtime, wild_mon, Callable(self, "_journey_action"), {"ball_attempts": 0})


# Soak policy: uniform pick among the legal actions for the current snapshot.
func play_random_battle(runtime, wild_mon: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	return _drive_battle(runtime, wild_mon, Callable(self, "_random_action"), {"rng": rng})


# First move with power and PP, else any move with PP, else -1.
func first_damaging_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	var fallback := -1
	for index in range(moves.size()):
		var move: Dictionary = moves[index]
		if int(move.get("pp", 0)) <= 0:
			continue
		if fallback < 0:
			fallback = index
		if int(move.get("power", 0)) > 0:
			return index
	return fallback


func total_party_exp(runtime) -> int:
	var total := 0
	for mon in runtime.get_party_snapshot():
		total += int(mon.get("exp", 0))
	return total


# Warning events appended to the JSONL trace log at or after from_line.
func count_warnings_since(from_line: int) -> int:
	if not FileAccess.file_exists(SmokeScenarioRunner.TRACE_LOG_PATH):
		return 0
	var file := FileAccess.open(SmokeScenarioRunner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return 0
	var lines := file.get_as_text().split("\n", false)
	file.close()
	var count := 0
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if parsed is Dictionary and str((parsed as Dictionary).get("event", "")) == "warning":
			count += 1
	return count


# "" while every party mon, move, and bag count stays within legal bounds.
func check_invariants(runtime) -> String:
	for mon in runtime.get_party_snapshot():
		var max_hp := int(mon.get("max_hp", 0))
		var current_hp := int(mon.get("current_hp", -1))
		if current_hp < 0 or current_hp > max_hp:
			return "party mon %s hp %d outside [0, %d]" % [str(mon.get("name", "?")), current_hp, max_hp]
		for move in mon.get("moves", []):
			var max_pp := int(move.get("max_pp", 0))
			var pp := int(move.get("pp", -1))
			if pp < 0 or pp > max_pp:
				return "move %s pp %d outside [0, %d]" % [str(move.get("move_id", "?")), pp, max_pp]
	for item_id in runtime.session.bag.keys():
		if int(runtime.session.bag[item_id]) < 0:
			return "bag item %s has a negative count" % str(item_id)
	return ""


# Saves, re-reads the file independently, and compares the key fields against
# the live session. {"ok": bool, "fail": String}.
func verify_save_roundtrip(runtime) -> Dictionary:
	runtime.save_game()
	var payload: Dictionary = runtime.save_store.load_payload()
	if payload.is_empty():
		return {"ok": false, "fail": "save payload did not parse as JSON"}
	if int(payload.get("version", 0)) != SessionState.SAVE_VERSION:
		return {"ok": false, "fail": "save version is not %d" % SessionState.SAVE_VERSION}
	if int(payload.get("world_seed", 0)) != runtime.get_world_seed():
		return {"ok": false, "fail": "world seed did not round-trip"}
	var tile: Vector2i = runtime.get_player_tile()
	if int(payload.get("player_x", -1)) != tile.x or int(payload.get("player_y", -1)) != tile.y:
		return {"ok": false, "fail": "player tile did not round-trip"}
	var saved_party: Array = payload.get("party", [])
	var party: Array = runtime.get_party_snapshot()
	if saved_party.size() != party.size():
		return {"ok": false, "fail": "party size did not round-trip"}
	for index in range(party.size()):
		if str(saved_party[index].get("species_id", "")) != str(party[index].get("species_id", "")):
			return {"ok": false, "fail": "party species did not round-trip"}
	var saved_bag: Dictionary = payload.get("bag", {})
	for item_id in ["poke_ball", "potion"]:
		if int(saved_bag.get(item_id, 0)) != runtime.get_item_count(item_id):
			return {"ok": false, "fail": "bag count for %s did not round-trip" % item_id}
	if int(payload.get("time_of_day_minutes", -1)) != runtime.get_time_of_day_minutes():
		return {"ok": false, "fail": "time_of_day_minutes did not round-trip"}
	return {"ok": true, "fail": ""}


# Runs a wild battle to a terminal outcome; the chooser picks each round's
# action from the latest public snapshot. {"outcome": String, "rounds": int}.
func _drive_battle(runtime, wild_mon: Dictionary, chooser: Callable, state: Dictionary) -> Dictionary:
	var response: Dictionary = runtime.start_wild_battle(wild_mon)
	var rounds := 0
	while not response.is_empty() and not bool(response.get("finished", false)):
		if rounds >= MAX_BATTLE_ROUNDS:
			response = runtime.run_from_battle()
			break
		var action: Dictionary = chooser.call(response.get("snapshot", {}), state)
		response = _apply_battle_action(runtime, action)
		rounds += 1
	if response.is_empty():
		return {"outcome": "stalled", "rounds": rounds}
	return {"outcome": str(response.get("outcome", "")), "rounds": rounds}


func _apply_battle_action(runtime, action: Dictionary) -> Dictionary:
	match str(action.get("type", "run")):
		"move":
			return runtime.perform_battle_move(int(action.get("index", 0)))
		"ball":
			return runtime.use_pokeball()
		"potion":
			return runtime.use_potion()
		_:
			return runtime.run_from_battle()


func _journey_action(snapshot: Dictionary, state: Dictionary) -> Dictionary:
	var player_mon: Dictionary = snapshot.get("player_mon", {})
	var enemy_mon: Dictionary = snapshot.get("enemy_mon", {})
	var bag: Dictionary = snapshot.get("bag", {})
	var max_hp := maxi(1, int(player_mon.get("max_hp", 1)))
	if int(player_mon.get("current_hp", 1)) * 100 <= max_hp * LOW_HP_PERCENT and int(bag.get("potion", 0)) > 0:
		return {"type": "potion"}
	var enemy_max_hp := maxi(1, int(enemy_mon.get("max_hp", 1)))
	var attempts := int(state.get("ball_attempts", 0))
	if int(enemy_mon.get("current_hp", 1)) * 100 <= enemy_max_hp * CATCH_HP_PERCENT and int(bag.get("poke_ball", 0)) > 0 and attempts < JOURNEY_BALL_CAP:
		state["ball_attempts"] = attempts + 1
		return {"type": "ball"}
	var move_index := first_damaging_move_index(player_mon)
	if move_index >= 0:
		return {"type": "move", "index": move_index}
	return {"type": "run"}


func _random_action(snapshot: Dictionary, state: Dictionary) -> Dictionary:
	var rng: RandomNumberGenerator = state.get("rng")
	var player_mon: Dictionary = snapshot.get("player_mon", {})
	var bag: Dictionary = snapshot.get("bag", {})
	var options: Array = []
	var move_index := first_damaging_move_index(player_mon)
	if move_index >= 0:
		options.append({"type": "move", "index": move_index})
	if int(bag.get("poke_ball", 0)) > 0:
		options.append({"type": "ball"})
	var max_hp := maxi(1, int(player_mon.get("max_hp", 1)))
	if int(player_mon.get("current_hp", 1)) < max_hp and int(bag.get("potion", 0)) > 0:
		options.append({"type": "potion"})
	options.append({"type": "run"})
	return options[rng.randi_range(0, options.size() - 1)]
