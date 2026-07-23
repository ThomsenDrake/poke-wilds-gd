extends RefCounted

# Mutable gameplay session: party, bag, world position, the in-game clock,
# and the lifetime step counter.
#
# Save schema v3 adds `world_overrides` (threaded in by GameRuntime from the
# world generator) and drops the v2 `unlocked_field_moves` key: field-move
# capability is derived from the party now, so the legacy key is ignored on
# load. v1/v2 payloads are still accepted; missing keys are backfilled with
# new-game defaults. Bag item ids are the lowercase i18n keys ("poke_ball");
# legacy ids from older saves are remapped on load (see LEGACY_ITEM_IDS).
# v3 also carries campsite_x/campsite_y/campsite_pokemon (additive keys): the
# non-losing hold for full-party captures, retrievable from the party screen.
# The build loop's placed structures ride the same v3-additive pattern under a
# separate "structures" key (SAVE_VERSION stays 3): older saves and saves from
# before building simply lack the key and backfill to {} on load.

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")

const SAVE_VERSION := 3
const DAY_MINUTES := 1440
const NEW_GAME_TIME_OF_DAY := 600 # 10:00
const STARTING_BAG := {
	"poke_ball": 5,
	"potion": 3
}
const LEGACY_ITEM_IDS := {
	"pokeball": "poke_ball",
}

var world_seed: int = 1337
var player_tile: Vector2i = Vector2i.ZERO
# Non-losing overflow hold: a capture with a full party relocates the mon to
# the player's last campsite (the anchor defaults to spawn until Phase 2 rest
# sites) instead of losing it. Phase 0 hold + retrieval, not Phase 3 boxes.
var campsite_tile: Vector2i = Vector2i.ZERO
var campsite_pokemon: Array = []
# Load-time handoff for placed structures (save-shape "x,y" -> entry). Populated
# by apply_loaded_state from the "structures" key so GameRuntime can feed it to
# the generator's placement map; the live canonical map lives on the generator.
var structures: Dictionary = {}
var party: Array = []
var bag: Dictionary = {}
var unlocked_field_moves: Dictionary = {}
var time_of_day_minutes: int = NEW_GAME_TIME_OF_DAY
var total_steps: int = 0


func reset_for_new_game(new_world_seed: int, starter: Dictionary, spawn_tile: Vector2i = Vector2i.ZERO) -> void:
	world_seed = new_world_seed
	player_tile = spawn_tile
	campsite_tile = spawn_tile
	campsite_pokemon.clear()
	structures = {}
	party.clear()
	unlocked_field_moves.clear()
	bag = STARTING_BAG.duplicate()
	time_of_day_minutes = NEW_GAME_TIME_OF_DAY
	total_steps = 0
	if not starter.is_empty():
		party.append(starter)


func apply_loaded_state(data: Dictionary, normalized_party: Array) -> void:
	world_seed = int(data.get("world_seed", 1337))
	player_tile = Vector2i(int(data.get("player_x", 0)), int(data.get("player_y", 0)))
	# Absent campsite keys (v1/v2/pre-hold v3 saves) anchor to the player tile.
	campsite_tile = Vector2i(int(data.get("campsite_x", player_tile.x)), int(data.get("campsite_y", player_tile.y)))
	campsite_pokemon = _normalize_campsite(data.get("campsite_pokemon", []))
	# Absent/invalid structures (pre-building saves) backfill to {} exactly like
	# the campsite keys; invalid entries are dropped (see _normalize_structures).
	structures = _normalize_structures(data.get("structures", {}))
	party = normalized_party
	var raw_bag: Variant = data.get("bag", null)
	bag = _normalize_bag(raw_bag) if raw_bag is Dictionary else STARTING_BAG.duplicate()
	time_of_day_minutes = _wrap_time(int(data.get("time_of_day_minutes", NEW_GAME_TIME_OF_DAY)))
	total_steps = maxi(0, int(data.get("total_steps", 0)))
	# v3 ignores the legacy `unlocked_field_moves` key; the dict below stays
	# only as audit scratch space (smoke_scenario_runner pokes it directly).
	unlocked_field_moves.clear()


func to_save_payload(world_overrides: Dictionary = {}, structures_overrides: Dictionary = {}) -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"world_seed": world_seed,
		"player_x": player_tile.x,
		"player_y": player_tile.y,
		"party": party,
		"bag": bag,
		"time_of_day_minutes": time_of_day_minutes,
		"total_steps": total_steps,
		"world_overrides": world_overrides,
		# Split save key for placed structures; the canonical value is the
		# generator's placements map, passed in by GameRuntime.save_game.
		"structures": structures_overrides,
		"campsite_x": campsite_tile.x,
		"campsite_y": campsite_tile.y,
		"campsite_pokemon": campsite_pokemon
	}


# Load-time structures handoff (save-shape); GameRuntime feeds this to the
# generator's placement map after re-seeding the world.
func get_structures() -> Dictionary:
	return structures.duplicate(true)


func get_active_party_index() -> int:
	for i in range(party.size()):
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_next_healthy_party_index(excluding_index: int) -> int:
	for i in range(party.size()):
		if i == excluding_index:
			continue
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_party_member(index: int) -> Dictionary:
	if index < 0 or index >= party.size():
		return {}
	return party[index]


func set_party_member(index: int, mon: Dictionary) -> void:
	if index < 0 or index >= party.size():
		return
	party[index] = mon


func add_pokemon_to_party(mon: Dictionary) -> bool:
	if party.size() >= 6:
		return false
	party.append(mon)
	return true


# --- Campsite hold (non-losing overflow for full-party captures) -------------

func relocate_to_campsite(mon: Dictionary) -> void:
	if not mon.is_empty():
		campsite_pokemon.append(mon)


func get_campsite_pokemon() -> Array:
	return campsite_pokemon.duplicate(true)


# Pops the held mon at index ({} when out of bounds) for party re-insertion.
func retrieve_campsite_mon(index: int) -> Dictionary:
	if index < 0 or index >= campsite_pokemon.size():
		return {}
	var mon: Dictionary = campsite_pokemon[index]
	campsite_pokemon.remove_at(index)
	return mon


func campsite_count() -> int:
	return campsite_pokemon.size()


func set_party_lead(index: int) -> void:
	if index <= 0 or index >= party.size():
		return
	var selected = party[index]
	party.remove_at(index)
	party.insert(0, selected)


func heal_party_full() -> void:
	for i in range(party.size()):
		var mon = party[i]
		mon["current_hp"] = int(mon.get("max_hp", 1))
		# Blackout heal (defect 0.5): restore HP AND clear status/sleep_turns.
		mon["status"] = ""
		mon["sleep_turns"] = 0
		party[i] = mon


func get_item_count(item_id: String) -> int:
	return int(bag.get(item_id, 0))


func add_item(item_id: String, count: int = 1) -> void:
	if item_id.is_empty() or count <= 0:
		return
	bag[item_id] = get_item_count(item_id) + count


func remove_item(item_id: String, count: int = 1) -> bool:
	var current = get_item_count(item_id)
	if count <= 0:
		return true
	if current < count:
		return false
	if current == count:
		bag.erase(item_id)
	else:
		bag[item_id] = current - count
	return true


# Kept for battle_runtime; prefer remove_item for new callers.
func consume_item(item_id: String, amount: int = 1) -> bool:
	return remove_item(item_id, amount)


func get_party_snapshot() -> Array:
	return party.duplicate(true)


# Sorted [{item_id, count}] entries with count > 0, stable for UI and saves.
func get_bag_snapshot() -> Array:
	var item_ids = bag.keys()
	item_ids.sort()
	var snapshot: Array = []
	for item_id in item_ids:
		var count = int(bag[item_id])
		if count > 0:
			snapshot.append({"item_id": str(item_id), "count": count})
	return snapshot


func advance_time(minutes: int) -> void:
	time_of_day_minutes = _wrap_time(time_of_day_minutes + minutes)


func note_step_taken() -> void:
	total_steps += 1


# Audit scratch accessor: smoke_scenario_runner snapshots/restores gate locks
# by poking unlocked_field_moves directly; there is no stored unlock model.
func get_unlocked_field_moves() -> Array:
	return unlocked_field_moves.keys()


func _wrap_time(minutes: int) -> int:
	return posmod(minutes, DAY_MINUTES)


# The same normalization the runtime applies to a loaded party, run here so
# campsite-held mons stay legal without a GameRuntime round-trip.
func _normalize_campsite(raw: Variant) -> Array:
	var normalized: Array = []
	if raw is Array:
		var rules = PokemonRules.new()
		for mon in raw:
			if mon is Dictionary and not (mon as Dictionary).is_empty():
				normalized.append(rules.normalize_loaded_mon(mon))
	return normalized


# Validates a loaded "structures" map into save shape ("x,y" -> entry), dropping
# malformed keys and entries that fail the placement validator (mirrors
# WorldOverrides.merge_placements' defensiveness, minus a trace logger here).
func _normalize_structures(raw: Variant) -> Dictionary:
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
		normalized["%d,%d" % [parts[0].to_int(), parts[1].to_int()]] = (entry as Dictionary).duplicate(true)
	return normalized


func _normalize_bag(raw: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	for item_id in raw.keys():
		var count = int(raw[item_id])
		if count > 0 and not str(item_id).is_empty():
			var canonical := str(LEGACY_ITEM_IDS.get(str(item_id), str(item_id)))
			normalized[canonical] = int(normalized.get(canonical, 0)) + count
	return normalized
