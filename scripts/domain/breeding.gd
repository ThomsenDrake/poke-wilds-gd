extends RefCounted

# Breeding + shiny domain (Phase 5; spec: docs/product-specs/breeding-shinies-drops-
# fishing.md). Pure rules: pairing compatibility, egg payloads, hatch data, pen enclosure
# detection (shared with breeding_runtime). The habitat comfort gate lives SOLELY in
# habitat_drops.gd — breeding_runtime's lay scan calls it (one table, never two).
# FAITHFUL (wiki-breeding.md): a female lays eggs of HER species near a compatible male of
# the SAME EGG GROUP; Ditto breeds with any breedable species and lays when the partner is
# male; exactly ONE compatible pair per pen (a third breaks attraction); eggs carry gender/
# moveset/shiny VISIBLE before hatch; egg moves come from the FATHER. Shiny odds are
# 1/shiny_odds (FAQ "1 in 256"). DIVERGENCE HOOK: ALLOW_UNDISCOVERED_BREEDING — the original
# does NOT breed genderless/Undiscovered/legendaries even with Ditto (wiki Note b, v0.8.9-
# 0.8.11) and the port defaults to that; the exec plan's workaround lives behind the const.

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")

const EGG_SPECIES_ID := "EGG"
const DITTO_GROUP := "DITTO"
const UNDISCOVERED_GROUP := "UNDISCOVERED"
const ALLOW_UNDISCOVERED_BREEDING := false # faithful default; see the DIVERGENCE note
const HATCH_LEVEL := 5 # hatched mons enter at level 5 (egg-battle trivia anchor)
# Gen 2 minimum hatch cycle; per-species hatch data is NOT in the asm dump — every egg uses
# the minimum (a DOCUMENTED ASSUMPTION; the Eevee/Dratini spread is future data).
const DEFAULT_STEPS_TO_HATCH := 2560
const EGG_NAME := "Egg"
const FENCE_ID := "fence"

# The user-adjustable-odds hook (FAQ "adjustable by the user in a subsiquent update"):
# the shiny_odds scenario flips it live (rides pokemon_rules' static var, one-way dep).
static func set_shiny_odds(odds: int) -> void:
	PokemonRules.shiny_odds = maxi(1, odds)
static func shiny_odds() -> int:
	return PokemonRules.shiny_odds

# True when two catalog species entries may breed (genders come from the live mons).
static func can_breed(entry_a: Dictionary, gender_a: String, entry_b: Dictionary, gender_b: String) -> bool:
	if entry_a.is_empty() or entry_b.is_empty():
		return false
	var a_ditto := is_ditto(entry_a)
	var b_ditto := is_ditto(entry_b)
	if a_ditto and b_ditto:
		return false # Ditto never breeds with Ditto
	if is_unbreedable(entry_a) or is_unbreedable(entry_b):
		return ALLOW_UNDISCOVERED_BREEDING and (a_ditto or b_ditto)
	if a_ditto or b_ditto:
		return true
	if gender_a == gender_b or PokemonRules.GENDERLESS in [gender_a, gender_b]:
		return false
	return not _shared_egg_groups(entry_a, entry_b).is_empty()

# The pasture's breeding pair {"mother": index, "father": index}, or {} when none OR MORE
# THAN ONE (a third compatible mon breaks attraction). Mother lays; with Ditto the non-Ditto
# female is the mother, else the Ditto lays (male + Ditto).
static func find_pair(mons: Array, get_species: Callable) -> Dictionary:
	var pairs: Array = []
	for i in range(mons.size()):
		for j in range(i + 1, mons.size()):
			var mon_a: Dictionary = mons[i] if mons[i] is Dictionary else {}
			var mon_b: Dictionary = mons[j] if mons[j] is Dictionary else {}
			if bool(mon_a.get("is_egg", false)) or bool(mon_b.get("is_egg", false)):
				continue
			var entry_a := _entry(mon_a, get_species)
			var entry_b := _entry(mon_b, get_species)
			var gender_a := str(mon_a.get("gender", ""))
			var gender_b := str(mon_b.get("gender", ""))
			if not can_breed(entry_a, gender_a, entry_b, gender_b):
				continue
			pairs.append(_pair_roles(i, entry_a, gender_a, j, entry_b, gender_b))
	return pairs[0] if pairs.size() == 1 else {}
static func _pair_roles(index_a: int, entry_a: Dictionary, gender_a: String, index_b: int, entry_b: Dictionary, gender_b: String) -> Dictionary:
	var a_ditto := is_ditto(entry_a)
	var b_ditto := is_ditto(entry_b)
	if b_ditto and not a_ditto and gender_a == PokemonRules.GENDER_FEMALE:
		return {"mother": index_a, "father": index_b}
	if a_ditto and not b_ditto and gender_b == PokemonRules.GENDER_FEMALE:
		return {"mother": index_b, "father": index_a}
	if gender_a == PokemonRules.GENDER_FEMALE:
		return {"mother": index_a, "father": index_b}
	if gender_b == PokemonRules.GENDER_FEMALE:
		return {"mother": index_b, "father": index_a}
	return {"mother": index_a, "father": index_b} if a_ditto else {"mother": index_b, "father": index_a}

# Egg payload + party-slot shell, fixed at lay time and VISIBLE pre-hatch (faithful). The
# top-level dict rides the party array with max_hp/current_hp 0, so healthy-party scans skip
# it and normalize_loaded_mon passes it through untouched (guarded by shape, not code).
static func build_egg(mother_mon: Dictionary, father_mon: Dictionary, child_entry: Dictionary, move_lookup: Callable, rng, seed_hint: String = "") -> Dictionary:
	var rules := PokemonRules.new()
	var gender := rules.resolve_gender(str(child_entry.get("gender_ratio", "")), seed_hint + str(child_entry.get("species_id", "")))
	var is_shiny := rules.roll_shiny(rng)
	var father_move_ids := _mon_move_ids(father_mon)
	var move_ids := _fill_moveset(_inherited_egg_moves(father_move_ids, child_entry), child_entry)
	return {
		"species_id": EGG_SPECIES_ID, "name": EGG_NAME, "level": HATCH_LEVEL, "exp": 0,
		"types": PackedStringArray(["NORMAL", "NORMAL"]),
		"stats": {"hp": 0, "atk": 0, "def": 0, "spe": 0, "sat": 0, "sdf": 0},
		"max_hp": 0, "current_hp": 0, "status": "", "happiness": PokemonRules.DEFAULT_HAPPINESS,
		"sleep_turns": 0, "moves": [], "gender_ratio": "", "gender": PokemonRules.GENDERLESS,
		"front_path": "", "back_path": "", "is_shiny": is_shiny, "is_egg": true,
		"egg": {
			"species_id": str(child_entry.get("species_id", "")),
			"display_name": str(child_entry.get("display_name", "Pokemon")),
			"gender": gender, "is_shiny": is_shiny, "moves": move_ids,
			"father_moves": father_move_ids, "steps_to_hatch": DEFAULT_STEPS_TO_HATCH
		}
	}

# The hatched instance: a real level-5 child overridden with the egg payload (gender/shiny
# rolled at lay time; the father's egg moves). NEVER built from the sprite-only EGG entry.
static func hatch_egg(egg_mon: Dictionary, child_entry: Dictionary, move_lookup: Callable, rng) -> Dictionary:
	var payload: Dictionary = egg_mon.get("egg", {})
	var rules := PokemonRules.new()
	var mon := rules.create_pokemon_instance(child_entry, HATCH_LEVEL, move_lookup, rng)
	if mon.is_empty():
		return {}
	mon["gender"] = str(payload.get("gender", mon.get("gender", "")))
	mon["is_shiny"] = bool(payload.get("is_shiny", false))
	var moves := rules.build_move_set(_payload_moves(payload), move_lookup)
	if not moves.is_empty():
		mon["moves"] = moves
	return mon

# --- Pen detection (fence-enclosure flood fill; shared with breeding_runtime) -----

# Pens from live placements: flood every walkable tile adjacent to a fence; a region under
# `budget` is enclosed -> {"x,y" anchor -> Array[Vector2i]} (door-in-fence escapes: faithful).
static func detect_pens(placements: Dictionary, get_tile_logic: Callable, budget: int) -> Dictionary:
	var pens := {}
	var claimed := {} # interior tile -> seen (failed floods mark too, so they skip)
	for key in placements.keys():
		if str((placements[key] as Dictionary).get("structure_id", "")) != FENCE_ID:
			continue
		var fence_tile := parse_tile_key(str(key))
		for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var candidate: Vector2i = fence_tile + direction
			if claimed.has(candidate):
				continue
			var tiles := flood_region(candidate, get_tile_logic, budget)
			if tiles.is_empty():
				claimed[candidate] = true
				continue
			var pen_key := anchor_key(tiles)
			for tile in tiles:
				claimed[tile] = true
			if not pens.has(pen_key):
				tiles.sort()
				pens[pen_key] = tiles
	return pens

# Walkable flood from `start`; reaching the budget means UNBOUNDED (no enclosure) -> [].
static func flood_region(start: Vector2i, get_tile_logic: Callable, budget: int) -> Array:
	if not bool(get_tile_logic.call(start)["walkable"]):
		return []
	var visited: Dictionary = {start: true}
	var frontier: Array = [start]
	var tiles: Array = []
	while not frontier.is_empty():
		if tiles.size() >= budget:
			return []
		var current = frontier.pop_front()
		tiles.append(current)
		for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next = current + direction
			if visited.has(next):
				continue
			visited[next] = true
			if bool(get_tile_logic.call(next)["walkable"]):
				frontier.append(next)
	return tiles
static func anchor_key(tiles: Array) -> String:
	var anchor: Vector2i = tiles[0]
	for tile in tiles:
		if tile.y < anchor.y or (tile.y == anchor.y and tile.x < anchor.x):
			anchor = tile
	return "%d,%d" % [anchor.x, anchor.y]
static func parse_tile_key(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.MAX
	return Vector2i(parts[0].to_int(), parts[1].to_int())

# --- Internals --------------------------------------------------------------------
static func is_ditto(entry: Dictionary) -> bool:
	var groups: Variant = entry.get("egg_groups", PackedStringArray())
	if (groups is PackedStringArray or groups is Array) and DITTO_GROUP in groups:
		return true
	return str(entry.get("species_id", "")) == "DITTO"

# Genderless (no GENDER_F ratio) or Undiscovered egg group: faithful UNBREEDABLE.
# Ditto is genderless yet the universal exception (its whole mechanic).
static func is_unbreedable(entry: Dictionary) -> bool:
	if is_ditto(entry):
		return false
	var groups: Variant = entry.get("egg_groups", PackedStringArray())
	if (groups is PackedStringArray or groups is Array) and UNDISCOVERED_GROUP in groups:
		return true
	return not str(entry.get("gender_ratio", "")).begins_with(PokemonRules.GENDER_RATIO_PREFIX)
static func _shared_egg_groups(entry_a: Dictionary, entry_b: Dictionary) -> Array:
	var shared: Array = []
	var groups_a: Variant = entry_a.get("egg_groups", PackedStringArray())
	var groups_b: Variant = entry_b.get("egg_groups", PackedStringArray())
	if not (groups_a is PackedStringArray or groups_a is Array) or not (groups_b is PackedStringArray or groups_b is Array):
		return shared
	for group in groups_a:
		var group_name := str(group)
		if group_name != UNDISCOVERED_GROUP and group_name in groups_b and not shared.has(group_name):
			shared.append(group_name)
	return shared
static func _entry(mon: Dictionary, get_species: Callable) -> Dictionary:
	if mon.is_empty() or not get_species.is_valid():
		return {}
	var entry: Variant = get_species.call(str(mon.get("species_id", "")))
	return entry if entry is Dictionary else {}
static func _mon_move_ids(mon: Dictionary) -> Array:
	var ids: Array = []
	var moves: Variant = mon.get("moves", [])
	if moves is Array:
		for move_variant in moves:
			if move_variant is Dictionary:
				var move_id := str((move_variant as Dictionary).get("move_id", ""))
				if not move_id.is_empty() and not ids.has(move_id):
					ids.append(move_id)
	return ids

# Father inheritance (the CONFIRMED wiki rule): the father's known moves that the child
# lists as egg moves (catalog "egg_moves"), in the father's move order ([] when absent).
static func _inherited_egg_moves(father_move_ids: Array, child_entry: Dictionary) -> Array:
	var inherited: Array = []
	var egg_moves: Variant = child_entry.get("egg_moves", PackedStringArray())
	if not (egg_moves is PackedStringArray or egg_moves is Array):
		return inherited
	for move_id in father_move_ids:
		if str(move_id) in egg_moves and inherited.size() < 4:
			inherited.append(str(move_id))
	return inherited

# Fills inherited egg moves to a level-5 moveset with the child's earliest level-up
# moves (then TACKLE as the last resort), matching create_pokemon_instance's shape.
static func _fill_moveset(egg_move_ids: Array, child_entry: Dictionary) -> Array:
	var move_ids := egg_move_ids.duplicate()
	var learnset: Variant = child_entry.get("learnset", [])
	if learnset is Array:
		for entry_variant in learnset:
			if move_ids.size() >= 4 or entry_variant is not Dictionary:
				continue
			var move_id := str((entry_variant as Dictionary).get("move_id", ""))
			if int((entry_variant as Dictionary).get("level", 101)) <= HATCH_LEVEL and not move_id.is_empty() and not move_ids.has(move_id):
				move_ids.append(move_id)
	if move_ids.is_empty():
		move_ids.append("TACKLE")
	return move_ids
static func _payload_moves(payload: Dictionary) -> Array:
	var move_ids: Array = []
	var moves: Variant = payload.get("moves", [])
	if moves is Array:
		for move_variant in moves:
			if not str(move_variant).is_empty():
				move_ids.append(str(move_variant))
	return move_ids
