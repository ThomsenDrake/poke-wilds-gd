extends RefCounted

# Phase 7 Build 1 — session payload marshalling EXTRACTED from session_state.gd
# (spec: world-depth.md § Implementation shape). The shared extraction HOME for the
# three world-depth builds (strictly serial touches — no merge conflict): Build 2
# added the legendary_removals key; Build 3 (landed) prepends SaveMigration.migrate
# to apply_into + emits the v5 keys (root_seed/active_chain/chained_worlds) + nests
# every world's landmark_state under chained_worlds["<cx>,<cy>"].landmark_state.
#
# No preload cycle: session_state delegates here, so this file takes the session as a
# parameter and its schema constants (SAVE_VERSION, STARTING_BAG, LEGACY_ITEM_IDS,
# DAY_MINUTES, NEW_GAME_TIME_OF_DAY) as explicit arguments — session_state stays the
# single owner of the schema constants. SaveMigration (domain) imports nothing from
# runtime, so the Build-3 preload below closes no cycle.

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")
const Structures := preload("res://scripts/domain/structures.gd")
const SaveMigration := preload("res://scripts/domain/save_migration.gd")


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
	# Phase 7 Build 3 (v5): chain identity + the per-world chained_worlds dict. The 15
	# keys above keep v4 keying EXACTLY (semantically the ACTIVE world's); the active
	# world's puzzle state nests under chained_worlds[active_chain].landmark_state
	# (EVERY world's puzzle state nests — origin at ["0,0"]; omitted when {} so a
	# chain-less no-progress save keeps chained_worlds == {}). The v4 top-level
	# landmark_state seat is gone in v5 (migrate() relocates it on load).
	payload["root_seed"] = session.root_seed
	payload["active_chain"] = session.active_chain
	payload["chained_worlds"] = chained_worlds_for_save(session)
	# Phase 7 Build 2 v4-ADDITIVE (NO SAVE_VERSION bump): gone-for-good legendary removal
	# keys ("<cx>,<cy>:<SPECIES>", the LegendaryPlacement.removal_key grammar), a
	# chain-scoped flat list; written ONLY when non-empty so a legendary-untouched save
	# keeps the exact pre-Build-2 byte shape (the frozen golden fixture carries no
	# legendary_removals key — spec § Save v5 byte-preservation witness).
	if not (session.legendary_removals as Array).is_empty():
		payload["legendary_removals"] = session.legendary_removals
	return payload


# Payload -> session; absent keys backfill with new-game defaults (the schema is
# ADDITIVE after v2). Build 3 prepends SaveMigration.migrate FIRST (a PURE copy —
# `data` is never mutated), then reads the v5 keys.
static func apply_into(session: RefCounted, data: Dictionary, normalized_party: Array, starting_bag: Dictionary, legacy_item_ids: Dictionary, day_minutes: int, new_game_minutes: int, save_version: int) -> void:
	var migrated: Dictionary = SaveMigration.migrate(data, save_version)
	session.world_seed = int(migrated.get("world_seed", 1337))
	session.player_tile = Vector2i(int(migrated.get("player_x", 0)), int(migrated.get("player_y", 0)))
	# Absent campsite keys (v1/v2/pre-hold v3 saves) anchor to the player tile.
	session.campsite_tile = Vector2i(int(migrated.get("campsite_x", session.player_tile.x)), int(migrated.get("campsite_y", session.player_tile.y)))
	session.campsite_pokemon = normalize_campsite(migrated.get("campsite_pokemon", []))
	# Absent/invalid structures backfill to {} like the campsite keys (invalid
	# entries dropped; see normalize_structures).
	session.structures = normalize_structures(migrated.get("structures", {}))
	# v4 additive: breeding pen state (breeding_runtime validates on apply_save_state).
	var raw_pastures: Variant = migrated.get("pastures", {})
	session.pastures = (raw_pastures as Dictionary).duplicate(true) if raw_pastures is Dictionary else {}
	session.party = normalized_party
	var raw_bag: Variant = migrated.get("bag", null)
	session.bag = normalize_bag(raw_bag, legacy_item_ids) if raw_bag is Dictionary else starting_bag.duplicate()
	session.time_of_day_minutes = wrap_time(int(migrated.get("time_of_day_minutes", new_game_minutes)), day_minutes)
	session.total_steps = maxi(0, int(migrated.get("total_steps", 0)))
	session.repel_steps = maxi(0, int(migrated.get("repel_steps", 0))) # Phase 4 additive (absent -> 0).
	# Phase 7 Build 3 (v5): chain identity (absent -> origin backfill; migrate()
	# guarantees these on every v<=5 payload — the .get defaults are belt-and-braces).
	session.root_seed = int(migrated.get("root_seed", int(migrated.get("world_seed", 1337))))
	session.active_chain = str(migrated.get("active_chain", "0,0"))
	var raw_chained: Variant = migrated.get("chained_worlds", {})
	session.chained_worlds = (raw_chained as Dictionary).duplicate(true) if raw_chained is Dictionary else {}
	# The ACTIVE world's puzzle state returns from its chained_worlds[active_chain]
	# nest to the flat seam var (the nest is the v5 save seat; the live session keeps
	# the v4 shape for the active world — migrate() moved a v4 top-level key here).
	# Non-active nests stay BYTE-IDENTICAL in session.chained_worlds: that map is the
	# world_chain_runtime deserialization source (never normalized here).
	var active_entry: Variant = session.chained_worlds.get(session.active_chain, {})
	var raw_landmarks: Variant = (active_entry as Dictionary).get("landmark_state", {}) if active_entry is Dictionary else {}
	session.landmark_state = (raw_landmarks as Dictionary).duplicate(true) if raw_landmarks is Dictionary else {}
	if active_entry is Dictionary and (active_entry as Dictionary).has("landmark_state"):
		(active_entry as Dictionary).erase("landmark_state")
		if (active_entry as Dictionary).is_empty():
			session.chained_worlds.erase(session.active_chain)
	# Phase 7 Build 2 v4-additive (absent -> []): gone-for-good legendary removal keys;
	# LegendaryPlacement re-derives stamp-time suppression from this set per world/chain.
	var raw_removals: Variant = migrated.get("legendary_removals", [])
	session.legendary_removals = (raw_removals as Array).duplicate(true) if raw_removals is Array else []
	# Legacy `unlocked_field_moves` key is ignored; the dict stays as audit scratch
	# space (smoke_scenario_runner pokes it directly).
	session.unlocked_field_moves.clear()


# Non-active entries deep-copied as stored, + the ACTIVE world's puzzle state nested
# under chained_worlds[active_chain].landmark_state; empty landmark_state sub-keys
# omitted (world-depth.md § Save v5 — "omitted from an entry when {}" so a chain-less
# no-progress save keeps chained_worlds == {}).
static func chained_worlds_for_save(session: RefCounted) -> Dictionary:
	var out := (session.chained_worlds as Dictionary).duplicate(true)
	for key in out.keys():
		var entry: Variant = out[key]
		if entry is Dictionary and (entry as Dictionary).has("landmark_state"):
			var nested: Variant = (entry as Dictionary)["landmark_state"]
			if nested is Dictionary and (nested as Dictionary).is_empty():
				(entry as Dictionary).erase("landmark_state")
	if not (session.landmark_state as Dictionary).is_empty():
		if not out.has(session.active_chain) or not (out[session.active_chain] is Dictionary):
			out[session.active_chain] = {}
		(out[session.active_chain] as Dictionary)["landmark_state"] = (session.landmark_state as Dictionary).duplicate(true)
	return out


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
