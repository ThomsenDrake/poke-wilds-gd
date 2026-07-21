extends RefCounted

# Smoke-harness support: scenario-request consumption, the world-scan / trace-log
# probe helpers shared by scripts/app/smoke_scenarios.gd, and the save backup/
# restore guard so scenarios never clobber the player's real save.

const SaveStore := preload("res://scripts/runtime/save_store.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")

const REQUEST_PATH := "res://.godot-smoke/scenario.json"
const TRACE_LOG_PATH := "user://logs/agent_trace.jsonl"
const SAVE_BACKUP_PATH := "user://godot_port_save.json.smoke.bak"

var _had_save := false
var _backup_armed := false


func consume_requested_scenario() -> String:
	if not FileAccess.file_exists(REQUEST_PATH):
		return ""
	var file = FileAccess.open(REQUEST_PATH, FileAccess.READ)
	if file == null:
		return ""
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	_cleanup_request_file()
	if parsed is Dictionary:
		return str(parsed.get("scenario", ""))
	return ""


# Copies the real save aside so a scenario can write freely; restore_save() puts it back.
func backup_save() -> void:
	_had_save = false
	_backup_armed = true
	if not FileAccess.file_exists(SaveStore.SAVE_PATH):
		return
	var source := FileAccess.open(SaveStore.SAVE_PATH, FileAccess.READ)
	if source == null:
		return
	var bytes := source.get_buffer(source.get_length())
	source.close()
	var backup := FileAccess.open(SAVE_BACKUP_PATH, FileAccess.WRITE)
	if backup == null:
		return
	backup.store_buffer(bytes)
	backup.close()
	_had_save = true


# Restores the original save (or deletes a scenario-created one when none existed)
# and removes the backup sibling; no-ops unless backup_save() armed the guard.
func restore_save() -> void:
	if not _backup_armed:
		return
	_backup_armed = false
	if _had_save and FileAccess.file_exists(SAVE_BACKUP_PATH):
		var source := FileAccess.open(SAVE_BACKUP_PATH, FileAccess.READ)
		var restored := FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
		if source != null and restored != null:
			restored.store_buffer(source.get_buffer(source.get_length()))
		if source != null:
			source.close()
		if restored != null:
			restored.close()
		_had_save = false
	elif not _had_save and FileAccess.file_exists(SaveStore.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveStore.SAVE_PATH))
	if FileAccess.file_exists(SAVE_BACKUP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_BACKUP_PATH))


# Party crafting for capability audits: builds a fresh party from species ids
# and swaps it in, returning the previous party for restore_party (unknown ids skipped).
func swap_party(runtime, species_ids: Array, level: int = 10) -> Array:
	var previous: Array = runtime.session.party
	var party: Array = []
	for species_id in species_ids:
		var entry: Dictionary = runtime.catalog.get_species(str(species_id))
		if not entry.is_empty():
			party.append(runtime.pokemon_rules.create_pokemon_instance(entry, level, Callable(runtime.catalog, "get_move")))
	runtime.session.party = party
	return previous


func restore_party(runtime, previous: Array) -> void:
	runtime.session.party = previous


# Nearest tile gated by the given field move, scanned ring by ring outward
# from center. Returns {"tile": Vector2i} or {} when the bound holds nothing.
func find_field_move_tile(world, center: Vector2i, radius: int, move_id: String) -> Dictionary:
	for ring in range(0, radius + 1):
		for tile in ring_around(center, ring):
			if world.tile_requires_field_move(tile) == move_id:
				return {"tile": tile}
	return {}


# First blocked, field-move-gated tile with a walkable stand neighbor, shaped
# {"from_tile", "direction", "gated_tile", "field_move"}; move_id pins one gate.
func find_gated_pair(world, center: Vector2i, radius: int, move_id: String = "") -> Dictionary:
	var directions = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var tile = center + Vector2i(dx, dy)
			if world.is_tile_walkable(tile):
				continue
			var field_move = world.tile_requires_field_move(tile)
			if field_move.is_empty():
				continue
			if not move_id.is_empty() and field_move != move_id:
				continue
			for direction in directions:
				var neighbor = tile + direction
				if world.is_tile_walkable(neighbor):
					return {"from_tile": neighbor, "direction": direction, "gated_tile": tile, "field_move": field_move}
	return {}


# Nearest tile whose resolver action (cut/dig/smash) matches, with a stand spot:
# {"tile", "from_tile", "direction"}; biome pins the tile's biome ({} when empty).
func find_harvest_target(world, center: Vector2i, radius: int, action: String, biome: String = "") -> Dictionary:
	for ring in range(0, radius + 1):
		for tile in ring_around(center, ring):
			var logic: Dictionary = world.get_tile_logic(tile)
			if HarvestResolver.action_for_tile(logic) != action:
				continue
			if not biome.is_empty() and str(logic.get("biome", "")) != biome:
				continue
			var spot := stand_spot(world, tile)
			if not spot.is_empty():
				return {"tile": tile, "from_tile": spot["from_tile"], "direction": spot["direction"]}
	return {}


# First walkable neighbor of tile plus the step into it: {"from_tile", "direction"}; {} when landlocked.
func stand_spot(world, tile: Vector2i) -> Dictionary:
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var neighbor = tile + direction
		if world.is_tile_walkable(neighbor):
			return {"from_tile": neighbor, "direction": -direction}
	return {}


# Tops up every party member's move PP so battle audits can always activate move row 0.
func refill_party_pp(runtime) -> void:
	var party: Array = runtime.get_party_snapshot()
	for i in range(party.size()):
		var mon: Dictionary = party[i]
		var moves: Array = mon.get("moves", [])
		var changed := false
		for j in range(moves.size()):
			var move: Dictionary = moves[j]
			var max_pp := int(move.get("max_pp", 0))
			if max_pp > 0 and int(move.get("pp", 0)) < max_pp:
				move["pp"] = max_pp
				moves[j] = move
				changed = true
		if changed:
			mon["moves"] = moves
			runtime.session.set_party_member(i, mon)


# PP of every move slot of a battle snapshot mon, for row-level spend checks.
func move_pp_list(moves: Array) -> Array:
	var out: Array = []
	for move in moves:
		out.append(int(move.get("pp", 0)))
	return out


# Move rows whose PP dropped between two move_pp_list snapshots.
func spent_move_rows(before: Array, after: Array) -> Array:
	var rows: Array = []
	for i in range(mini(before.size(), after.size())):
		if int(after[i]) < int(before[i]):
			rows.append(i)
	return rows


# Prefers a non-encounter walkable neighbor; falls back to the origin so overworld_step never soft-locks.
func find_safe_step_direction(world, player, runtime) -> Vector2i:
	for origin in [player.tile_position, Vector2i.ZERO]:
		if origin != player.tile_position:
			teleport_player(world, player, runtime, origin)
		for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var next_tile = origin + direction
			if world.is_tile_walkable(next_tile) and not world.is_encounter_tile(next_tile):
				return direction
	return Vector2i.ZERO


func find_walkable_step_direction(world, tile: Vector2i) -> Vector2i:
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		if world.is_tile_walkable(tile + direction):
			return direction
	return Vector2i.ZERO


func ring_around(center: Vector2i, radius: int) -> Array:
	if radius == 0:
		return [center]
	var tiles: Array = []
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if max(abs(x), abs(y)) == radius:
				tiles.append(center + Vector2i(x, y))
	return tiles


# Deterministic spread of up to cap entries from a larger scan, so ring audits cover the whole radius.
func even_samples(entries: Array, cap: int) -> Array:
	if entries.size() <= cap:
		return entries
	var samples: Array = []
	for i in range(cap):
		samples.append(entries[int(i * entries.size() / float(cap))])
	return samples


func teleport_player(world, player, runtime, tile: Vector2i) -> void:
	player.set_tile_position(tile)
	world.sync_visible(tile)
	runtime.set_player_tile(tile)


# A battle defeat returns the player to the session tile; mirrors the
# app-side resync so playtests never leave the two disagreeing.
func resync_player_tile(world, player, runtime) -> void:
	if runtime.get_player_tile() != player.tile_position:
		teleport_player(world, player, runtime, runtime.get_player_tile())


# Writes the save, reloads it through the runtime apply path, and rebuilds the view.
func save_and_reload(world, runtime) -> Dictionary:
	runtime.save_game()
	var payload: Dictionary = runtime.save_store.load_payload()
	runtime._apply_loaded_payload(payload)
	world.rebuild(runtime.get_world_seed())
	return payload


# Save-recovery audits for save_migration: (0.3) an unparseable save loads empty,
# is preserved as .corrupt.bak, and traces a warning-tier save_recovery; (0.1) a
# populated campsite hold + non-spawn anchor round-trips save/load intact. "" = pass.
func assert_save_recovery(runtime, cursor: int) -> String:
	var file = FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("{ not parseable json ")
		file.close()
	var refused: Dictionary = runtime.save_store.load_payload()
	if not (refused.is_empty() and FileAccess.file_exists(SaveStore.SAVE_PATH + ".corrupt.bak") and trace_log_has_since("warning", cursor, {"reason": "corrupt"})):
		return "corrupt save was not recovered non-destructively"
	var session = runtime.session
	var ids: Array = runtime.catalog.species.keys()
	if ids.is_empty():
		return "no catalog species for the campsite round-trip"
	var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species(str(ids[0])), 8, Callable(runtime.catalog, "get_move"))
	session.party = [mon.duplicate(true)]
	session.campsite_pokemon = [mon.duplicate(true)]
	session.campsite_tile = session.player_tile + Vector2i(3, -2)
	var anchor: Vector2i = session.campsite_tile
	runtime.save_game()
	var held: Array = session.get_campsite_pokemon() if runtime._apply_loaded_payload(runtime.save_store.load_payload()) else []
	var got: Dictionary = held[0] if held.size() == 1 else {}
	var want_moves: Array = mon.get("moves", [])
	var got_moves: Array = got.get("moves", [])
	var want_id := "" if want_moves.is_empty() else str((want_moves[0] as Dictionary).get("move_id", ""))
	var got_id := "" if got_moves.is_empty() else str((got_moves[0] as Dictionary).get("move_id", ""))
	var ok: bool = session.campsite_tile == anchor and str(got.get("species_id", "")) == str(mon.get("species_id", "")) and int(got.get("level", 0)) == 8 and got_id == want_id
	return "" if ok else "campsite hold did not survive the save round-trip"


# Line count of the JSONL trace log; capture before an action to scope trace_log_has_since.
func trace_log_line_count() -> int:
	return _trace_log_lines().size()


# True when a trace at/after from_line matches the event name and every key/value of payload_match.
func trace_log_has_since(event_name: String, from_line: int, payload_match: Dictionary = {}) -> bool:
	var lines = _trace_log_lines()
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if not (parsed is Dictionary):
			continue
		if str((parsed as Dictionary).get("event", "")) != event_name:
			continue
		if _payload_matches((parsed as Dictionary).get("payload", {}), payload_match):
			return true
	return false


func _trace_log_lines() -> PackedStringArray:
	if not FileAccess.file_exists(TRACE_LOG_PATH):
		return PackedStringArray()
	var file = FileAccess.open(TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text = file.get_as_text()
	file.close()
	return text.split("\n", false)


func _payload_matches(payload: Variant, expected: Dictionary) -> bool:
	if not (payload is Dictionary):
		return expected.is_empty()
	# The log is parsed back from JSON (which floats every number) and Array equality
	# is type-strict, so round-trip the expectation through JSON to normalize types.
	var normalized: Dictionary = JSON.parse_string(JSON.stringify(expected))
	for key in normalized.keys():
		if (payload as Dictionary).get(key) != normalized[key]:
			return false
	return true


func _cleanup_request_file() -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
