extends RefCounted

# Phase 7 Build 1 — session payload marshalling EXTRACTED from session_state.gd
# (spec: world-depth.md § Implementation shape). The shared extraction HOME for the
# three world-depth builds (strictly serial touches — no merge conflict): Build 2
# adds the legendary_removals key; Build 3 wraps apply_into with SaveMigration.migrate
# FIRST + the v5 keys + per-world landmark_state under chained_worlds. That module
# (save_migration.gd) does NOT exist until Build 3, so this file never references it.
#
# No preload cycle: session_state delegates here, so this file takes the session as a
# parameter and its schema constants (SAVE_VERSION, STARTING_BAG, LEGACY_ITEM_IDS,
# DAY_MINUTES, NEW_GAME_TIME_OF_DAY) as explicit arguments — session_state stays the
# single owner of the schema constants.

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")
const Structures := preload("res://scripts/domain/structures.gd")


# Session -> save payload (the existing 15 v4 keys, unchanged shape).
static func to_payload(session: RefCounted, world_overrides: Dictionary, structures_overrides: Dictionary, save_version: int) -> Dictionary:
	var payload := {
		"version": save_version,
		"world_seed": session.world_seed,
		"player_x": session.player_tile.x,
		"player_y": session.player_tile.y,
		"party": session.party,
		"bag": session.bag,
		"time_of_day_minutes": session.time_of_day_minutes,
		"total_steps": session.total_steps,
		"repel_steps": session.repel_steps,
		"world_overrides": world_overrides,
		# Split save key for placed structures (canonical: the generator's map).
		"structures": structures_overrides,
		"campsite_x": session.campsite_tile.x,
		"campsite_y": session.campsite_tile.y,
		"campsite_pokemon": session.campsite_pokemon,
		"pastures": session.pastures
	}
	# Phase 7 v4-ADDITIVE (NO SAVE_VERSION bump): per-landmark puzzle progress, written
	# ONLY when non-empty so a puzzle-untouched save keeps the exact pre-Phase-7 byte
	# shape (the frozen golden fixture carries no landmark_state key).
	if not (session.landmark_state as Dictionary).is_empty():
		payload["landmark_state"] = session.landmark_state
	# Phase 7 Build 2 v4-ADDITIVE (NO SAVE_VERSION bump): gone-for-good legendary removal
	# keys ("<cx>,<cy>:<SPECIES>", the LegendaryPlacement.removal_key grammar), a
	# chain-scoped flat list; written ONLY when non-empty so a legendary-untouched save
	# keeps the exact pre-Build-2 byte shape (the frozen golden fixture carries no
	# legendary_removals key — spec § Save v5 byte-preservation witness).
	if not (session.legendary_removals as Array).is_empty():
		payload["legendary_removals"] = session.legendary_removals
	return payload


# Payload -> session; absent keys backfill with new-game defaults (the schema is
# ADDITIVE after v2). Build 3 prepends SaveMigration.migrate(parsed) to `data` here.
static func apply_into(session: RefCounted, data: Dictionary, normalized_party: Array, starting_bag: Dictionary, legacy_item_ids: Dictionary, day_minutes: int, new_game_minutes: int) -> void:
	session.world_seed = int(data.get("world_seed", 1337))
	session.player_tile = Vector2i(int(data.get("player_x", 0)), int(data.get("player_y", 0)))
	# Absent campsite keys (v1/v2/pre-hold v3 saves) anchor to the player tile.
	session.campsite_tile = Vector2i(int(data.get("campsite_x", session.player_tile.x)), int(data.get("campsite_y", session.player_tile.y)))
	session.campsite_pokemon = normalize_campsite(data.get("campsite_pokemon", []))
	# Absent/invalid structures backfill to {} like the campsite keys (invalid
	# entries dropped; see normalize_structures).
	session.structures = normalize_structures(data.get("structures", {}))
	# v4 additive: breeding pen state (breeding_runtime validates on apply_save_state).
	var raw_pastures: Variant = data.get("pastures", {})
	session.pastures = (raw_pastures as Dictionary).duplicate(true) if raw_pastures is Dictionary else {}
	session.party = normalized_party
	var raw_bag: Variant = data.get("bag", null)
	session.bag = normalize_bag(raw_bag, legacy_item_ids) if raw_bag is Dictionary else starting_bag.duplicate()
	session.time_of_day_minutes = wrap_time(int(data.get("time_of_day_minutes", new_game_minutes)), day_minutes)
	session.total_steps = maxi(0, int(data.get("total_steps", 0)))
	session.repel_steps = maxi(0, int(data.get("repel_steps", 0))) # Phase 4 additive (absent -> 0).
	# Phase 7 v4-additive (absent -> {}): per-landmark puzzle progress. The frozen
	# location-keyed seam (SessionState.landmark_state_for / set_landmark_state)
	# resolves to this flat top-level key in Builds 1-2; Build 3 relocates it per-world
	# under chained_worlds["<cx>,<cy>"].landmark_state without touching landmark_runtime.
	var raw_landmarks: Variant = data.get("landmark_state", {})
	session.landmark_state = (raw_landmarks as Dictionary).duplicate(true) if raw_landmarks is Dictionary else {}
	# Phase 7 Build 2 v4-additive (absent -> []): gone-for-good legendary removal keys;
	# LegendaryPlacement re-derives stamp-time suppression from this set per world/chain.
	var raw_removals: Variant = data.get("legendary_removals", [])
	session.legendary_removals = (raw_removals as Array).duplicate(true) if raw_removals is Array else []
	# Legacy `unlocked_field_moves` key is ignored; the dict stays as audit scratch
	# space (smoke_scenario_runner pokes it directly).
	session.unlocked_field_moves.clear()


static func wrap_time(minutes: int, day_minutes: int) -> int:
	return posmod(minutes, day_minutes)


# The same normalization the runtime applies to a loaded party, run here so
# campsite-held mons AND v4 box contents stay legal (corrupt contents degrade to an
# empty list, never a crash or a torn placement entry).
static func normalize_campsite(raw: Variant) -> Array:
	var normalized: Array = []
	if raw is Array:
		var rules = PokemonRules.new()
		for mon in raw:
			if mon is Dictionary and not (mon as Dictionary).is_empty():
				normalized.append(rules.normalize_loaded_mon(mon))
	return normalized


# Validates a loaded "structures" map into save shape ("x,y" -> entry), dropping
# malformed keys/entries (mirrors WorldOverrides.merge_placements' defensiveness).
static func normalize_structures(raw: Variant) -> Dictionary:
	var normalized: Dictionary = {}
	if not (raw is Dictionary):
		return normalized
	var raw_map: Dictionary = raw
	for key in raw_map.keys():
		var parts := str(key).split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var entry: Variant = raw_map[key]
		if not (entry is Dictionary) or not WorldOverrides.is_valid_placement(entry):
			continue
		var placement: Dictionary = (entry as Dictionary).duplicate(true)
		# v4 additive: a storage_box entry may carry box contents (absent = empty).
		if str(placement.get("structure_id", "")) == Structures.BOX_ID:
			placement["contents"] = normalize_campsite(placement.get("contents", []))
		normalized["%d,%d" % [parts[0].to_int(), parts[1].to_int()]] = placement
	return normalized


static func normalize_bag(raw: Dictionary, legacy_item_ids: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	for item_id in raw.keys():
		var count = int(raw[item_id])
		if count > 0 and not str(item_id).is_empty():
			var canonical := str(legacy_item_ids.get(str(item_id), str(item_id)))
			normalized[canonical] = int(normalized.get(canonical, 0)) + count
	return normalized
