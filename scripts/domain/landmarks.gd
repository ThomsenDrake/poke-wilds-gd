extends RefCounted

# Phase 7 Build 1 — landmarks (spec: docs/product-specs/world-depth.md § Landmarks).
# Deterministic-from-seed multi-tile footprints (Mansion / Desert Ruins / Heart Tower)
# stamped into base tile logic at world_generator's single mutation boundary — NOT
# placements. Every world (origin AND chained) hosts all three from (world_seed,
# chain); presence is never seed/chain-gated. NO RandomNumberGenerator / engine
# hash() / dict iteration: anchors ride overworld_mons._mix SplitMix + SALT_LANDMARK_ANCHOR;
# the land-test mirrors world_generator's FastNoiseLite elevation channel (deterministic noise).

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")
const BiomeField := preload("res://scripts/domain/biome_field.gd") # the ONE elevation/biome source (infinite-world slice 2; the local mirror is gone)
const ContentScatter := preload("res://scripts/domain/content_scatter.gd") # the instance-key grammar (slice 3; no cycle — it never imports this file)

const SALT_LANDMARK_ANCHOR := 0x23 # pinned (scenario contract)
const ANCHOR_SEARCH_BUDGET := 400
const MANSION_STATUES := 3
const MANSION_LEVEL_BAND := [18, 26]       # FLAGGED #11 (no documented levels)
const RUINS_OUTER_LEVEL_BAND := [22, 30]   # FLAGGED #11
const RUINS_INNER_LEVEL_FLOOR := 30
# FLAGGED #9: Volcarona/Golurk are bare db TYPE sentinels with NO RUINS_* token — a PORT CURATION over the faithful Lunatone-only RUINS_INNER token.
const RUINS_INNER_CURATED := {"VOLCARONA": [38, 45], "GOLURK": [38, 45]}
# Dusclops Underground = ALWAYS-AGGRESSIVE (wiki :270); Phase 6 held it DORMANT — now that a ruins sub-region exists it goes LIVE (runtime entity).
const RUINS_UNDERGROUND_SPECIES := "DUSCLOPS"
const MANSION_KEY_ID := "mansion_key"
const MANSION_LOOT_BALL_ID := "poke_ball"  # FLAGGED #11: Ultra Ball until Phase 8 ball tiers
# Dormant source tokens (catalog spawn_biomes carry them VERBATIM): footprint-scoped ONLY — NOT aliased in biome_encounters (port-wide aliasing would admit Beldum everywhere).
const TOKEN_MANSION := "PKMNMANSION"
const TOKEN_RUINS_OUTER := "RUINS_OUTER"
const TOKEN_RUINS_INNER := "RUINS_INNER"
const MANSION_ID := "pkmn_mansion"
const RUINS_ID := "desert_ruins"
const TOWER_ID := "heart_tower"
const LANDMARK_IDS := [MANSION_ID, RUINS_ID, TOWER_ID]
const MANSION_SIZE := Vector2i(13, 10)
const RUINS_SIZE := Vector2i(15, 11)
const TOWER_SIZE := Vector2i(9, 8)
# Target Manhattan rings: inside the >=28 DESERT band, under the 60 SNOW/LAVA band; ring minus
# footprint half-diagonal > SPAWN_SEARCH_RADIUS (24, spec gate (c)); anchor_for ALSO keeps siblings disjoint.
const _RINGS := {MANSION_ID: 40, RUINS_ID: 34, TOWER_ID: 48}
const _SIZES := {MANSION_ID: MANSION_SIZE, RUINS_ID: RUINS_SIZE, TOWER_ID: TOWER_SIZE}
const _M_WALL := "res://assets/source/tiles/ruined_city/wall1.png"
const _M_ROOM_WALL := "res://assets/source/tiles/buildings/pkmnmansion_wall_NS.png"
const _M_FLOOR := "res://assets/source/tiles/ruined_city/floor1.png"
const _M_ROOM_FLOOR := "res://assets/source/tiles/buildings/pkmnmansion_floor1.png"
const _M_SEWER_FLOOR := "res://assets/source/tiles/buildings/pkmnmansion_floor2.png"
const _M_PILLAR := "res://assets/source/tiles/ruined_city/pillar1.png"
const _M_STATUE := "res://assets/source/tiles/buildings/pkmnmansion_statue1.png"
const _M_JOURNAL := "res://assets/source/tiles/ruined_city/house_table1_journal1.png"
const _M_JOURNAL2 := "res://assets/source/tiles/ruined_city/house_table1_journal2.png"
const _M_STAIRS := "res://assets/source/tiles/ruined_city/stairs_down1.png"
const _M_DOOR := "res://assets/source/tiles/buildings/pkmnmansion_ext_door.png"
const _M_SHELF := "res://assets/source/tiles/buildings/pkmnmansion_shelf1.png"
const _R_PATH := "res://assets/source/tiles/ruins2_path1.png"
const _R_WALL := "res://assets/source/tiles/ruins2_wall1.png"
const _R_WALL2 := "res://assets/source/tiles/ruins2_wall2.png"
const _R_DOOR := "res://assets/source/tiles/ruins2_door.png"
const _R_FLOOR := "res://assets/source/tiles/ruins2_floor.png"
const _R_UNDER_FLOOR := "res://assets/source/tiles/ruins_floor2.png"
const _R_STATUE := "res://assets/source/tiles/ruins_statue1.png"
const _R_PILLAR_BROKEN := "res://assets/source/tiles/ruins1_pillar1_broken.png"
const _R_PICTURE := "res://assets/source/tiles/ruins2_volcarona_picture1.png"
const _T_WALL := "res://assets/source/tiles/heart_tower/heart-tower-1856.png" # numbered tiles ship UNLABELED — pinned picks (FLAGGED #7)
const _T_FLOOR := "res://assets/source/tiles/heart_tower/heart-tower-733.png"
const _T_DECOR := "res://assets/source/tiles/heart_tower/heart-tower-1914.png"
const _WALL_REASON := "The landmark wall blocks the way."
const _STATUE_REASON := "A glowing statue hums."
const _M_STATUE_TILES := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7)]
const MANSION_KEY_TABLE_TILE := Vector2i(9, 3)   # COURTYARD journal table holding mansion_key (the key gates the room grid, so it lies in the OPEN outer ruin)
const MANSION_LOOT_TILE := Vector2i(6, 3)        # FLAGGED #11 loot shelf
# [walkable, encounter, token, prop, region, reason] special tiles; rules fill the rest.
const _M_SPECIAL := {
	Vector2i(6, 0): [true, false, "", _M_FLOOR, "entry", ""], # north opening: the entry walks straight into the OPEN courtyard (the key gates the room grid, NEVER the outer ruin)
	Vector2i(7, 5): [false, false, "", _M_DOOR, "room_door", "The room door is locked."],
	Vector2i(4, 5): [false, false, "", _M_DOOR, "sewer_door", "The basement seal holds."],
	Vector2i(2, 7): [false, false, "", _M_STAIRS, "sewer", _WALL_REASON],
	Vector2i(6, 7): [false, false, "", _M_STATUE, "room", "A mansion statue stands here."],
	Vector2i(7, 7): [false, false, "", _M_STATUE, "room", "A mansion statue stands here."],
	Vector2i(8, 7): [false, false, "", _M_STATUE, "room", "A mansion statue stands here."],
	MANSION_KEY_TABLE_TILE: [false, false, "", _M_JOURNAL, "courtyard", "A table with a journal."],
	Vector2i(6, 6): [false, false, "", _M_JOURNAL2, "room", "A table with a journal."],
	Vector2i(2, 2): [false, false, "", _M_PILLAR, "courtyard", _WALL_REASON],
	Vector2i(10, 2): [false, false, "", _M_PILLAR, "courtyard", _WALL_REASON],
	MANSION_LOOT_TILE: [false, false, "", _M_SHELF, "courtyard", "A dusty shelf."],
}
const _R_SPECIAL := {
	Vector2i(7, 7): [true, false, "", _R_DOOR, "inner", ""],
	Vector2i(6, 4): [false, false, "", _R_STATUE, "inner", _STATUE_REASON],
	Vector2i(8, 4): [false, false, "", _R_STATUE, "inner", _STATUE_REASON],
	Vector2i(10, 5): [true, false, "", _R_UNDER_FLOOR, "underground", ""],
	Vector2i(11, 4): [false, false, "", _M_STAIRS, "underground", _WALL_REASON],
	Vector2i(13, 4): [false, false, "", _R_PICTURE, "underground", "An ancient painting."],
	Vector2i(2, 2): [false, false, "", _R_PILLAR_BROKEN, "outer", _WALL_REASON],
	Vector2i(12, 2): [false, false, "", _R_PILLAR_BROKEN, "outer", _WALL_REASON],
	Vector2i(3, 5): [false, false, "", _R_STATUE, "outer", _STATUE_REASON],
	Vector2i(11, 9): [false, false, "", _R_STATUE, "outer", _STATUE_REASON],
}
# Anchor cache: pure function of (seed, chain); single-key access, never feeds hash derivation.
static var _world_cache: Dictionary = {}
# --- Frozen generator seam (chaining never rewrites these); every world hosts all three. Entries: {landmark_id, anchor, footprint}. ---
static func landmarks_in_world(world_seed: int, chain: Vector2i) -> Array:
	var key := "%d:%d:%d" % [world_seed, chain.x, chain.y]
	if _world_cache.has(key):
		return (_world_cache[key] as Array).duplicate(true)
	var landmarks: Array = []
	for landmark_id in LANDMARK_IDS:
		var anchor := anchor_for(world_seed, chain, str(landmark_id))
		var size: Vector2i = _SIZES[landmark_id]
		landmarks.append({"landmark_id": str(landmark_id), "anchor": anchor, "footprint": Rect2i(anchor - size / 2, size)})
	_world_cache[key] = landmarks.duplicate(true)
	return landmarks
# Stamps per-tile logic into base_logic; OUTSIDE every footprint returns base_logic UNCHANGED. Adds landmark_id + encounter_token; biome stays the HOST biome.
static func tile_logic_for(world_seed: int, chain: Vector2i, map_pos: Vector2i, base_logic: Dictionary) -> Dictionary:
	var hit := _lookup(world_seed, chain, map_pos)
	if hit.is_empty():
		return base_logic
	var logic := cell_logic_for(hit["cell"], str(hit["landmark_id"]), base_logic)
	# The instance key (slice 3): "id@ax,ay" off the footprint anchor — additive per-instance identity; landmark_id stays BARE.
	logic["landmark_instance"] = ContentScatter.instance_key(str(hit["landmark_id"]), (hit["footprint"] as Rect2i).position + (hit["footprint"] as Rect2i).size / 2)
	return logic
# The cell -> logic stamp, the SINGLE source (landmark_scatter.gd's consult rides it too — a mirror would drift).
static func cell_logic_for(cell: Dictionary, landmark_id: String, base_logic: Dictionary) -> Dictionary:
	var logic := base_logic.duplicate()
	logic["landmark_id"] = landmark_id
	logic["landmark_region"] = str(cell["region"]) # slice 3: the consults' region reads ride the stamp (no second lookup; covers scattered instances)
	logic["encounter_token"] = str(cell["token"])
	logic["walkable"] = bool(cell["walkable"])
	logic["encounter"] = bool(cell["encounter"])
	logic["block_reason"] = str(cell["reason"])
	logic["requires_field_move"] = ""
	logic["prop_path"] = str(cell["prop"])
	logic["prop_region"] = null
	logic["tall_grass_path"] = ""
	logic["tall_grass_key_color"] = ""
	return logic
# Footprint region of a tile ("" outside) — runtime first-entry traces + door overlay.
static func region_at(world_seed: int, chain: Vector2i, map_pos: Vector2i) -> String:
	return str(_lookup(world_seed, chain, map_pos).get("region", ""))
static func mansion_statue_index(world_seed: int, chain: Vector2i, map_pos: Vector2i) -> int:
	var hit := _lookup(world_seed, chain, map_pos)
	if str(hit.get("landmark_id", "")) != MANSION_ID:
		return -1
	return _M_STATUE_TILES.find(map_pos - (hit["footprint"] as Rect2i).position)
# Instance-aware statue index (slice 3): footprint-relative, so a SCATTERED mansion's statues resolve (the origin _lookup sees only the origin three).
static func mansion_statue_index_local(local: Vector2i) -> int: return _M_STATUE_TILES.find(local)
# Door walkability FROM PUZZLE STATE: the seam stamps both doors sealed; landmark_runtime overlays this via the frozen location-keyed seam, never the keying.
static func mansion_door_walkable(state: Dictionary, region: String) -> bool:
	if region == "room_door":
		return bool(state.get("key_taken", false))
	if region == "sewer_door":
		return bool(state.get("unlocked", false))
	return false

# --- Anchors (pure SplitMix; bounded search; never absent; siblings disjoint) ------
# The search ALSO requires disjoint (borders included) from earlier-anchored siblings (LANDMARK_IDS order; sibling anchors re-derive by the same pure recursion — cache never feeds derivation): one step past ANY edge stays un-stamped.
static func anchor_for(world_seed: int, chain: Vector2i, landmark_id: String) -> Vector2i:
	var index := LANDMARK_IDS.find(landmark_id)
	if index < 0:
		push_warning("Landmarks: unknown landmark id '%s'" % str(landmark_id))
		return Vector2i.ZERO
	var ring := int(_RINGS[landmark_id])
	var h := OverworldMons._mix(world_seed, chain.x, chain.y * 4 + index, SALT_LANDMARK_ANCHOR)
	var candidate := _ring_tile(ring, int(h & 3), int((h >> 2) % (ring + 1)))
	var size: Vector2i = _SIZES[landmark_id]
	var noise := BiomeField.elevation_noise(world_seed)
	var siblings: Array = []
	for earlier in range(index):
		var esize: Vector2i = _SIZES[LANDMARK_IDS[earlier]]
		siblings.append(Rect2i(anchor_for(world_seed, chain, LANDMARK_IDS[earlier]) - esize / 2, esize))
	var checked := 0
	var radius := 0
	while checked < ANCHOR_SEARCH_BUDGET:
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if checked >= ANCHOR_SEARCH_BUDGET:
					break
				if radius == 0 or maxi(absi(x), absi(y)) == radius:
					checked += 1
					var probe := candidate + Vector2i(x, y)
					if _fits_on_land(noise, probe, size) and _disjoint(probe - size / 2, size, siblings):
						return probe
		radius += 1
	# Budget exhausted -> fixed ring fallback: NEVER absent, NEVER unbounded (FAQ :208-210).
	return candidate

# --- Mansion statue-switch puzzle (PURE transitions; argument NEVER mutated; seam-read state). Phases: locked -> statues_set -> unlocked. ---
static func default_mansion_state() -> Dictionary:
	return {"statues": [false, false, false], "unlocked": false, "key_taken": false}
static func mansion_state_from(raw: Dictionary) -> Dictionary:
	var state := default_mansion_state()
	var raw_statues: Variant = raw.get("statues", [])
	if raw_statues is Array:
		var statues: Array = state["statues"]
		for i in range(mini(MANSION_STATUES, (raw_statues as Array).size())):
			statues[i] = bool((raw_statues as Array)[i])
	state["unlocked"] = bool(raw.get("unlocked", false))
	state["key_taken"] = bool(raw.get("key_taken", false))
	return state
# Returns {"state": next, "payload": puzzle_state_changed payload}; all three ON opens the basement (solved: true); once unlocked it STAYS unlocked.
static func toggle_mansion_statue(state: Dictionary, index: int) -> Dictionary:
	var next := mansion_state_from(state)
	if index < 0 or index >= MANSION_STATUES:
		push_warning("Landmarks: statue index %d out of range" % index)
		return {"state": next, "payload": {}}
	var statues: Array = next["statues"]
	statues[index] = not bool(statues[index])
	var all_on := true
	for on in statues:
		all_on = all_on and bool(on)
	if all_on:
		next["unlocked"] = true
	var named := "statue_%d_%s" % [index, "on" if bool(statues[index]) else "off"]
	return {"state": next, "payload": {"landmark_id": MANSION_ID, "puzzle_id": "statues", "state": "unlocked" if all_on else named, "solved": all_on}}
# Key gates the ROOM grid (outer ruin is open). Payload = auxiliary key_item_used.
static func take_mansion_key(state: Dictionary) -> Dictionary:
	var next := mansion_state_from(state)
	next["key_taken"] = true
	return {"state": next, "payload": {"item_id": MANSION_KEY_ID, "landmark_id": MANSION_ID}}

# --- Footprint layouts (plane-abstracted regions; door tiles are transitions) -----
static func _lookup(world_seed: int, chain: Vector2i, map_pos: Vector2i) -> Dictionary:
	for landmark in landmarks_in_world(world_seed, chain):
		var footprint: Rect2i = landmark["footprint"]
		if footprint.has_point(map_pos):
			var cell := _tile_for(str(landmark["landmark_id"]), map_pos - footprint.position)
			return {"landmark_id": str(landmark["landmark_id"]), "cell": cell, "region": str(cell["region"]), "footprint": footprint}
	return {}
static func _tile_for(landmark_id: String, local: Vector2i) -> Dictionary:
	match landmark_id:
		MANSION_ID:
			return _mansion_tile(local)
		RUINS_ID:
			return _ruins_tile(local)
	return _tower_tile(local)
# Mansion 13x10: entry (6,0) -> OPEN courtyard (y1-4); key door (7,5) -> room grid (x6-9, y6-8); sewer door (4,5) -> sewer (x1-4, y6-8) — every door tile CARDINALLY adjacent to its region's floor.
static func _mansion_tile(local: Vector2i) -> Dictionary:
	if _M_SPECIAL.has(local):
		return _cell_v(_M_SPECIAL[local])
	var x := local.x
	var y := local.y
	if x == 0 or y == 0 or x == 12 or y == 9:
		return _cell(false, false, "", _M_WALL, "courtyard", _WALL_REASON)
	if y == 5:
		return _cell(false, false, "", _M_ROOM_WALL, "room", _WALL_REASON)
	if y >= 6:
		if x == 5 or x == 10 or x == 11:
			return _cell(false, false, "", _M_ROOM_WALL, "room", _WALL_REASON)
		if x <= 4: # the sewer reaches the x4 column so the sewer door (4,5) opens onto sewer FLOOR (4,6)
			return _cell(true, true, TOKEN_MANSION, _M_SEWER_FLOOR, "sewer")
		return _cell(true, true, TOKEN_MANSION, _M_ROOM_FLOOR, "room")
	return _cell(true, true, TOKEN_MANSION, _M_FLOOR, "courtyard")
# Ruins 15x11: RUINS_OUTER grounds + walled RUINS_INNER (x5-9, y3-7) + underground (x10-14, y3-7; NO random pool — aggressive Dusclops).
static func _ruins_tile(local: Vector2i) -> Dictionary:
	if _R_SPECIAL.has(local):
		return _cell_v(_R_SPECIAL[local])
	var x := local.x
	var y := local.y
	if x >= 5 and x <= 9 and y >= 3 and y <= 7:
		if x == 5 or x == 9 or y == 3 or y == 7:
			return _cell(false, false, "", _R_WALL, "inner", _WALL_REASON)
		return _cell(true, true, TOKEN_RUINS_INNER, _R_FLOOR, "inner")
	if x >= 10 and x <= 14 and y >= 3 and y <= 7:
		if x == 10 or x == 14 or y == 3 or y == 7:
			return _cell(false, false, "", _R_WALL2, "underground", _WALL_REASON)
		return _cell(true, false, "", _R_UNDER_FLOOR, "underground")
	return _cell(true, true, TOKEN_RUINS_OUTER, _R_PATH, "outer")
# Tower 9x8: enterable base chamber (FLAGGED #7 — internals DEFERRED). No token/puzzle.
static func _tower_tile(local: Vector2i) -> Dictionary:
	if local == Vector2i(4, 7):
		return _cell(true, false, "", _T_FLOOR, "base")
	if local.x == 0 or local.y == 0 or local.x == 8 or local.y == 7:
		return _cell(false, false, "", _T_WALL, "base", _WALL_REASON)
	if local == Vector2i(4, 2):
		return _cell(false, false, "", _T_DECOR, "base", _WALL_REASON)
	return _cell(true, false, "", _T_FLOOR, "base")
static func _cell(walkable: bool, encounter: bool, token: String, prop: String, region: String, reason: String = "") -> Dictionary:
	return {"walkable": walkable, "encounter": encounter, "token": token, "prop": prop, "region": region, "reason": reason}
static func _cell_v(value: Array) -> Dictionary:
	return _cell(bool(value[0]), bool(value[1]), str(value[2]), str(value[3]), str(value[4]), str(value[5]))
static func _ring_tile(ring: int, face: int, along: int) -> Vector2i: # Manhattan ring: face 0-3, offset 0..ring
	match face:
		0:
			return Vector2i(ring - along, along)
		1:
			return Vector2i(-along, ring - along)
		2:
			return Vector2i(-(ring - along), -along)
	return Vector2i(along, -(ring - along))
static func _fits_on_land(noise: FastNoiseLite, anchor: Vector2i, size: Vector2i) -> bool: # land = elevation in (-0.30, 0.55), >= 7 of 9 probes
	var half := size / 2
	var probes := [anchor, anchor + Vector2i(-half.x, -half.y), anchor + Vector2i(half.x, -half.y), anchor + Vector2i(-half.x, half.y), anchor + Vector2i(half.x, half.y), anchor + Vector2i(-half.x, 0), anchor + Vector2i(half.x, 0), anchor + Vector2i(0, -half.y), anchor + Vector2i(0, half.y)]
	var land := 0
	for probe in probes:
		var elevation := noise.get_noise_2d(probe.x, probe.y)
		if elevation > -0.30 and elevation < ROCK_CLIFF_ELEVATION:
			land += 1
	return land >= 7
static func _disjoint(position: Vector2i, size: Vector2i, siblings: Array) -> bool: # borders INCLUDED: siblings never even touch
	var fp := Rect2i(position, size)
	for sibling in siblings:
		var s := sibling as Rect2i
		if fp.position.x <= s.end.x and s.position.x <= fp.end.x and fp.position.y <= s.end.y and s.position.y <= fp.end.y:
			return false
	return true

# --- Extracted from world_generator.gd (spec § Implementation shape: the at-cap generator delegates its ONE consult line) ---
const ROCK_CLIFF_ELEVATION := 0.55
static func coord_noise(x: int, y: int, world_seed: int, salt: int) -> float:
	var n = int(x) * 374761393 + int(y) * 668265263 + world_seed * 104729 + salt * 4256233
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / float(0x7fffffff)
static func pick_prop(map_pos: Vector2i, props: Array, world_seed: int) -> Variant:
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		if coord_noise(map_pos.x, map_pos.y, world_seed, 101 + i * 7) < float(prop["chance"]):
			return prop
	return null
static func is_rock_cliff(elevation: float, walkable: bool) -> bool:
	return elevation > ROCK_CLIFF_ELEVATION and walkable
