extends RefCounted

const BiomeDefs := preload("res://scripts/domain/biome_defs.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")
const WorldInvariants := preload("res://scripts/domain/world_invariants.gd")
const TILE_SIZE := 16
const ROCK_PROP_PATH := "res://pokewilds/rock_small1.png"
const SPAWN_SEARCH_RADIUS := 24
const SPAWN_MIN_WALK_NEIGHBORS := 2
const SPAWN_MIN_SAFE_NEIGHBORS := 1

var _seed: int = 1337
var _elevation_noise: FastNoiseLite
var _tall_grass_noise: FastNoiseLite
var _biome_noise: FastNoiseLite
var _defs: Dictionary = {}
var _textures: Dictionary = {}
# Two independent sparse maps (one save key each): harvest clears and build
# placements. They coexist per tile (build on a cleared tile) and share one 10k
# cap; the merged view mirror is built by mutations_for_view().
var _overrides: Dictionary = {}
var _placements: Dictionary = {}


func setup(seed_value: int) -> void:
	_seed = seed_value
	_defs = BiomeDefs.new().definitions()

	_elevation_noise = FastNoiseLite.new()
	_elevation_noise.seed = _seed
	_elevation_noise.frequency = 0.010
	_elevation_noise.fractal_octaves = 4
	_elevation_noise.fractal_lacunarity = 2.0
	_elevation_noise.fractal_gain = 0.45

	# Patch-scale noise for tall-grass scatter: 0.16 frequency blobs a handful
	# of tiles wide, so encounter grass reads as patches, not carpets.
	_tall_grass_noise = FastNoiseLite.new()
	_tall_grass_noise.seed = _seed + 9931
	_tall_grass_noise.frequency = 0.16
	_tall_grass_noise.fractal_octaves = 3
	_tall_grass_noise.fractal_lacunarity = 2.2
	_tall_grass_noise.fractal_gain = 0.50

	_biome_noise = FastNoiseLite.new()
	_biome_noise.seed = _seed + 4242
	_biome_noise.frequency = 0.004
	_biome_noise.fractal_octaves = 2
	_biome_noise.fractal_lacunarity = 2.0
	_biome_noise.fractal_gain = 0.50


func get_tile_logic(map_pos: Vector2i) -> Dictionary:
	var elevation = _elevation_noise.get_noise_2d(map_pos.x, map_pos.y)
	var biome = _pick_biome(map_pos, elevation)
	var def: Dictionary = _defs[biome]

	var walkable: bool = bool(def["walkable"])
	var encounter: bool = bool(def["encounter"])

	# Encounter biomes with tall-grass data only trigger wild battles on the
	# scattered tall-grass tiles; the rest of the biome is safe to cross.
	var tall_grass_path := ""
	var tall_grass_key := ""
	var tall_grass = def.get("tall_grass", null)
	if encounter and walkable and tall_grass is Dictionary:
		if _tall_grass_noise.get_noise_2d(map_pos.x, map_pos.y) >= float((tall_grass as Dictionary).get("threshold", 0.15)):
			tall_grass_path = str((tall_grass as Dictionary)["path"])
			tall_grass_key = str((tall_grass as Dictionary).get("key_color", ""))
		else:
			encounter = false

	var prop_path := ""
	var prop_region: Variant = null
	var block_reason := str(def["block_reason"])
	var field_move := str(def["field_move"])

	var props = def["props"]
	if props is Array and walkable:
		var picked: Variant = _pick_prop(map_pos, props)
		if picked is Dictionary:
			prop_path = str(picked["path"])
			prop_region = picked.get("region", null)
			if bool(picked["block"]):
				walkable = false
				block_reason = str(picked["reason"])
				field_move = str(picked["field_move"])

	if elevation > 0.55 and walkable:
		prop_path = ROCK_PROP_PATH
		prop_region = null
		walkable = false
		block_reason = "A rocky cliff blocks the way."
		field_move = "smash"

	var logic := {
		"biome": biome,
		"walkable": walkable,
		"encounter": encounter,
		"block_reason": block_reason,
		"requires_field_move": field_move,
		"base_path": str(def["base_path"]),
		"base_region": def.get("base_region", null),
		"prop_path": prop_path,
		"prop_region": prop_region,
		"tall_grass_path": tall_grass_path,
		"tall_grass_key_color": tall_grass_key
	}
	# Mutations apply last, at this single boundary, clears then placements so a
	# built structure shadows a cleared tile; empty maps keep base byte-identical.
	if _overrides.has(map_pos):
		logic = WorldOverrides.apply(logic, _overrides[map_pos])
	if _placements.has(map_pos):
		logic = WorldOverrides.apply(logic, _placements[map_pos])
	return logic


func add_override(tile: Vector2i, kind: String, by: String, step: int) -> bool:
	return WorldOverrides.put(_overrides, tile, WorldOverrides.make_entry(kind, by, step), _placements.size())

func apply_overrides(saved: Dictionary) -> void:
	WorldOverrides.merge_save(_overrides, saved, _placements.size())

func overrides_for_save() -> Dictionary:
	return WorldOverrides.to_save(_overrides)

func clear_overrides() -> void:
	_overrides.clear()


# --- Build placements (second sparse map, second save key) --------------------

func add_placement(tile: Vector2i, structure_id: String, by: String, step: int, gate: bool = false) -> bool:
	return WorldOverrides.put_placement(_placements, tile, WorldOverrides.make_placement(structure_id, by, step, gate), _overrides.size())

# Demolition: erases the placement entry and returns it ({} when none). The
# tile's clear (if any) lives in the SEPARATE clears map and is untouched, so
# demolished ground reverts to cleared ground — never respawns its raw prop.
func remove_placement(tile: Vector2i) -> Dictionary:
	var entry: Dictionary = _placements.get(tile, {})
	if not entry.is_empty():
		_placements.erase(tile)
	return entry

func apply_placements(saved: Dictionary) -> void:
	WorldOverrides.merge_placements(_placements, saved, _overrides.size())

func placements_for_save() -> Dictionary:
	return WorldOverrides.to_save(_placements)

func clear_placements() -> void:
	_placements.clear()

# Merged clears+placements in save shape, placements shadowing same-tile clears,
# for the zero-touch view mirror + audit (never written to the save, which keeps
# the two keys split). Bounded by MAX_OVERRIDES via the shared cap, so a single
# merge_save into the view's one map can never truncate.
func mutations_for_view() -> Dictionary:
	var merged := WorldOverrides.to_save(_overrides)
	for tile: Vector2i in _placements.keys():
		merged["%d,%d" % [tile.x, tile.y]] = (_placements[tile] as Dictionary).duplicate(true)
	return merged


func get_tile(map_pos: Vector2i) -> Dictionary:
	var logic = get_tile_logic(map_pos)
	var base_texture = _texture(str(logic["base_path"]), logic.get("base_region", null))
	var prop_texture: Texture2D = null
	if str(logic["prop_path"]) != "":
		prop_texture = _texture(str(logic["prop_path"]), logic.get("prop_region", null))
	return {
		"biome": logic["biome"],
		"walkable": logic["walkable"],
		"encounter": logic["encounter"],
		"base_texture": base_texture,
		"prop_texture": prop_texture,
		"block_reason": logic["block_reason"],
		"requires_field_move": logic["requires_field_move"],
		# Source paths/regions and the biome ground color let the view layer
		# color-key overlay sheets and composite them; see tile_texture_cache.gd.
		"base_path": str(logic["base_path"]),
		"base_region": logic.get("base_region", null),
		"prop_path": str(logic["prop_path"]),
		"prop_region": logic.get("prop_region", null),
		"tall_grass_path": str(logic.get("tall_grass_path", "")),
		"tall_grass_key_color": str(logic.get("tall_grass_key_color", "")),
		"ground_color": (_defs[str(logic["biome"])] as Dictionary).get("ground_color", null),
		"key_color": str((_defs[str(logic["biome"])] as Dictionary).get("key_color", "")),
		"prop_key_color": _prop_key_color(str(logic["biome"]), str(logic["prop_path"]))
	}


# Prop keying hints live on the prop defs, but get_tile_logic only forwards
# the picked path; resolve the hint here so the logic path stays untouched.
func _prop_key_color(biome: String, prop_path: String) -> String:
	if prop_path.is_empty():
		return ""
	var def: Dictionary = _defs.get(biome, {})
	for prop in def.get("props", []):
		if str((prop as Dictionary).get("path", "")) == prop_path:
			return str((prop as Dictionary).get("key_color", ""))
	return ""


func find_walkable_spawn(seed_value: int) -> Vector2i:
	setup(seed_value)
	for ring in range(0, SPAWN_SEARCH_RADIUS):
		for tile in _ring_tiles(ring):
			if bool(get_tile_logic(tile)["walkable"]) and _spawn_meets_neighbors(tile):
				return tile
	return Vector2i.ZERO


# `blocked` is one extra tile treated as unwalkable — the build trap guard's
# hypothetical stamp, so the guard flood-fills without mutating the live placements map.
func reachable_walkable_count(start: Vector2i, max_tiles: int, blocked: Vector2i = Vector2i.MAX) -> int:
	if start == blocked or not bool(get_tile_logic(start)["walkable"]):
		return 0
	var visited: Dictionary = {start: true}
	var frontier: Array = [start]
	var count = 0
	while not frontier.is_empty() and count < max_tiles:
		var current = frontier.pop_front()
		count += 1
		for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next = current + direction
			if next == blocked or visited.has(next):
				continue
			if bool(get_tile_logic(next)["walkable"]):
				visited[next] = true
				frontier.append(next)
	return count


# Determinism + biome-ring + spawn-reach audit, split into world_invariants.gd
# (it was the budget pressure that forced the pre-split); thin delegate so the
# view's validate_world_invariants() call site is unchanged.
func validate_invariants(seed_value: int) -> Dictionary:
	return WorldInvariants.validate_invariants(self, seed_value)


func _spawn_meets_neighbors(tile: Vector2i) -> bool:
	var walk_neighbors = 0
	var safe_neighbors = 0
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var logic = get_tile_logic(tile + direction)
		if bool(logic["walkable"]):
			walk_neighbors += 1
			if not bool(logic["encounter"]):
				safe_neighbors += 1
	return walk_neighbors >= SPAWN_MIN_WALK_NEIGHBORS and safe_neighbors >= SPAWN_MIN_SAFE_NEIGHBORS


func _ring_tiles(ring: int) -> Array:
	if ring == 0:
		return [Vector2i.ZERO]
	var tiles: Array = []
	for y in range(-ring, ring + 1):
		for x in range(-ring, ring + 1):
			if max(abs(x), abs(y)) == ring:
				tiles.append(Vector2i(x, y))
	return tiles


func _pick_biome(map_pos: Vector2i, elevation: float) -> String:
	if elevation < -0.30:
		return "WATER"
	if elevation < -0.12:
		return "SAND"
	var candidates = _ring_candidates(abs(map_pos.x) + abs(map_pos.y))
	var region = (_biome_noise.get_noise_2d(map_pos.x, map_pos.y) + 1.0) * 0.5
	var index = clampi(int(region * float(candidates.size())), 0, candidates.size() - 1)
	return str(candidates[index])


func _ring_candidates(distance: int) -> Array:
	var candidates: Array = ["PLAINS", "GRASSLAND"]
	if distance >= 10:
		candidates.append_array(["FOREST", "SAVANNA"])
	if distance >= 28:
		candidates.append_array(["DESERT", "SWAMP", "ROCK"])
	if distance >= 60:
		candidates.append_array(["SNOW", "LAVA"])
	return candidates


func _pick_prop(map_pos: Vector2i, props: Array) -> Variant:
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		if _coord_noise(map_pos.x, map_pos.y, 101 + i * 7) < float(prop["chance"]):
			return prop
	return null


func _texture(path: String, region: Variant) -> Texture2D:
	var entry: Dictionary = _textures.get(path, {})
	if entry.is_empty():
		var base = load(path) as Texture2D
		if base == null:
			return null
		entry = {"full": base}
		_textures[path] = entry

	if not (region is Rect2):
		return entry["full"]
	if not entry.has("region"):
		var frame = AtlasTexture.new()
		frame.atlas = entry["full"]
		frame.region = region
		entry["region"] = frame
	return entry["region"]


func _coord_noise(x: int, y: int, salt: int) -> float:
	var n = int(x) * 374761393 + int(y) * 668265263 + _seed * 104729 + salt * 4256233
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / float(0x7fffffff)
