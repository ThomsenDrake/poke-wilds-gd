extends Node2D

const TILE_SIZE := 16
const WorldGenerator := preload("res://scripts/domain/world_generator.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")
const RuntimePath := "/root/GameRuntime"
const TIME_OF_DAY_DEFAULT := 720
# Piecewise-linear tint keyframes (minute of day, color): midnight blue holds
# through the night, warms at dawn, neutral through midday, warms at dusk.
const TIME_OF_DAY_KEYFRAMES := [
	[0, Color(0.26, 0.28, 0.48)],
	[270, Color(0.26, 0.28, 0.48)],
	[390, Color(1.0, 0.78, 0.60)],
	[480, Color(1.0, 1.0, 1.0)],
	[1020, Color(1.0, 1.0, 1.0)],
	[1110, Color(1.0, 0.70, 0.52)],
	[1230, Color(0.26, 0.28, 0.48)],
	[1439, Color(0.26, 0.28, 0.48)]
]

@export var world_seed: int = 1337
@export var half_width_tiles: int = 30
@export var half_height_tiles: int = 20

@onready var _ground_layer: Node2D = $GroundLayer
@onready var _prop_layer: Node2D = $PropLayer

var _generator = WorldGenerator.new()
var _texture_cache = TileTextureCache.new()
var _tile_cache: Dictionary = {} # bounded to the synced window (_evict_tile_cache)
var _ground_nodes: Dictionary = {}
var _prop_nodes: Dictionary = {}
var _last_biome := ""
var _canvas_modulate: CanvasModulate = null


func _ready() -> void:
	_setup_canvas_order()
	_canvas_modulate = CanvasModulate.new()
	_canvas_modulate.name = "DayNightModulate"
	add_child(_canvas_modulate)
	set_time_of_day(TIME_OF_DAY_DEFAULT)
	var runtime := _runtime_or_null()
	if runtime != null:
		runtime.world_overridden.connect(_on_world_overridden)
	rebuild(world_seed)


# Y-sort delivers the north/south depth contract: prop sprites sort by their
# tile bottom, the player sprite by its feet (player_avatar.gd), and ground
# tiles stay at z -1 below every actor (Godot sorts by z_index first, then by
# Y within one z_index). Every canvas ancestor must be y-sort-enabled or its
# subtree renders as a single block, so the parent (Main, which also parents
# the player sibling) joins the chain here.
func _setup_canvas_order() -> void:
	y_sort_enabled = true
	_ground_layer.y_sort_enabled = true
	_prop_layer.y_sort_enabled = true
	var parent := get_parent()
	if parent is CanvasItem:
		(parent as CanvasItem).y_sort_enabled = true


func sync_visible(center_tile: Vector2i) -> void:
	var active_tiles: Dictionary = {}
	for y in range(center_tile.y - half_height_tiles, center_tile.y + half_height_tiles + 1):
		for x in range(center_tile.x - half_width_tiles, center_tile.x + half_width_tiles + 1):
			var tile = Vector2i(x, y)
			active_tiles[tile] = true
			_ensure_tile_nodes(tile)
	_cleanup_inactive_nodes(active_tiles)
	_evict_tile_cache(active_tiles)
	_emit_biome_entered(center_tile)


func map_to_world(map_pos: Vector2i) -> Vector2:
	return Vector2(map_pos.x * TILE_SIZE, map_pos.y * TILE_SIZE)


func is_tile_walkable(map_pos: Vector2i) -> bool:
	var tile = _get_tile_data(map_pos)
	if bool(tile.get("walkable", false)):
		return true
	# Surf is the only traversal gate that opens passively, via party
	# capability; cut/smash-gated tiles open only by being cleared.
	if str(tile.get("requires_field_move", "")) != "surf":
		return false
	var runtime = _runtime_or_null()
	if runtime == null:
		return false
	return runtime.party_has_field_move_ability("surf")


func is_encounter_tile(map_pos: Vector2i) -> bool:
	return _get_tile_data(map_pos)["encounter"]


func get_tile_biome(map_pos: Vector2i) -> String:
	return str(_get_tile_data(map_pos).get("biome", ""))


# Traversal block reason shown when the player bumps this tile. Gated tiles
# get a hint: harvestable gates (cut/smash) name the clearing move, water
# points at a SURF-capable party member.
func get_traversal_block_reason(map_pos: Vector2i) -> String:
	var tile := _get_tile_data(map_pos)
	var reason := str(tile.get("block_reason", ""))
	var gate := str(tile.get("requires_field_move", ""))
	var hint := ""
	if gate == "surf":
		hint = "A SURF-capable Pokemon could cross."
	elif gate == "cut" or gate == "smash":
		hint = "It could be %s." % gate.to_upper()
	if hint.is_empty():
		return reason
	return reason + " " + hint if not reason.is_empty() else hint


func tile_requires_field_move(map_pos: Vector2i) -> String:
	return str(_get_tile_data(map_pos).get("requires_field_move", ""))


# Generator logic for one tile (biome, walkable, prop, gate, encounter).
# Audits cross-check it against the rendered scene and the collision answer;
# the view's generator is the one seeded from the session.
func get_tile_logic(map_pos: Vector2i) -> Dictionary:
	return _generator.get_tile_logic(map_pos)


# Full render data the view cached for one tile (textures, colors, paths).
func get_tile_render_data(map_pos: Vector2i) -> Dictionary:
	return _get_tile_data(map_pos)


# The texture the tile's ground sprite currently shows; null while the tile
# sits outside the synced window.
func get_tile_base_texture(map_pos: Vector2i) -> Texture2D:
	var node: Sprite2D = _ground_nodes.get(map_pos, null)
	return node.texture if node != null else null


# The texture the tile's prop sprite currently shows; null when the tile
# renders no prop (or sits outside the synced window).
func get_tile_prop_texture(map_pos: Vector2i) -> Texture2D:
	var node: Sprite2D = _prop_nodes.get(map_pos, null)
	return node.texture if node != null else null


# The live prop sprite for one tile (null when none); z-order audits read its
# canvas ordering relative to the player.
func get_prop_sprite(map_pos: Vector2i) -> Sprite2D:
	return _prop_nodes.get(map_pos, null)


func validate_world_invariants() -> Dictionary:
	return _generator.validate_invariants(world_seed)


# Presentational day/night tint. Nothing calls this yet (wave 2 wires the
# clock); the default keeps boot appearance unchanged (white == no tint).
# Calling it repeatedly with advancing minutes yields a smooth gradient.
func set_time_of_day(minutes_0_1439: int) -> void:
	if _canvas_modulate == null:
		return
	_canvas_modulate.color = _time_of_day_color(clampi(minutes_0_1439, 0, 1439))


func _time_of_day_color(minutes: int) -> Color:
	var prev_minute: int = TIME_OF_DAY_KEYFRAMES[0][0]
	var prev_color: Color = TIME_OF_DAY_KEYFRAMES[0][1]
	for keyframe in TIME_OF_DAY_KEYFRAMES:
		var key_minute: int = keyframe[0]
		var key_color: Color = keyframe[1]
		if minutes <= key_minute:
			if key_minute == prev_minute:
				return key_color
			var t := float(minutes - prev_minute) / float(key_minute - prev_minute)
			return prev_color.lerp(key_color, t)
		prev_minute = key_minute
		prev_color = key_color
	return prev_color


func rebuild(seed_value: int) -> void:
	world_seed = seed_value
	_generator.setup(world_seed)
	# The runtime owns the canonical override map; mirror it so rendering and
	# traversal see harvested tiles. Clear first: stale entries must never leak
	# across seeds or a New Game (setup() alone keeps the old map).
	_generator.clear_overrides()
	var runtime := _runtime_or_null()
	if runtime != null:
		_generator.apply_overrides(runtime.mutations_for_view())
	_tile_cache.clear()
	_last_biome = ""
	_clear_rendered_nodes()


# Live mutation sync: the runtime just changed an override on this tile, so
# mirror the map, drop the tile's cached data, and re-render it in place when
# it sits inside the synced window (the ground texture too — dug tiles lose
# their tall-grass overlay). Off-window tiles refresh on the next sync_visible.
# Clear-then-apply (same shape as rebuild): demolition REMOVES entries, so a
# merge alone would keep a demolished structure rendered + colliding.
func _on_world_overridden(tile: Vector2i) -> void:
	var runtime := _runtime_or_null()
	if runtime == null:
		return
	_generator.clear_overrides()
	_generator.apply_overrides(runtime.mutations_for_view())
	_tile_cache.erase(tile)
	var ground: Sprite2D = _ground_nodes.get(tile, null)
	if ground == null and not _prop_nodes.has(tile):
		return
	if ground != null:
		ground.texture = _texture_cache.base_texture(_get_tile_data(tile))
	_ensure_tile_nodes(tile)


func _get_tile_data(map_pos: Vector2i) -> Dictionary:
	if not _tile_cache.has(map_pos):
		_tile_cache[map_pos] = _generator.get_tile(map_pos)
	return _tile_cache[map_pos]


func _ensure_tile_nodes(map_pos: Vector2i) -> void:
	var tile_data = _get_tile_data(map_pos)

	if not _ground_nodes.has(map_pos):
		var ground_sprite = Sprite2D.new()
		ground_sprite.centered = false
		ground_sprite.texture = _texture_cache.base_texture(tile_data)
		ground_sprite.position = map_to_world(map_pos)
		ground_sprite.z_index = -1
		_ground_layer.add_child(ground_sprite)
		_ground_nodes[map_pos] = ground_sprite

	var prop_texture: Texture2D = _texture_cache.prop_texture(tile_data)
	if prop_texture != null:
		if not _prop_nodes.has(map_pos):
			var prop_sprite = Sprite2D.new()
			prop_sprite.centered = false
			prop_sprite.texture = prop_texture
			# Origin at the tile bottom (the prop's base) so y-sort orders it
			# against the player's feet; offset keeps the draw position
			# unchanged, extending tall canopies into the tile above.
			prop_sprite.position = map_to_world(map_pos) + Vector2(0, TILE_SIZE)
			prop_sprite.offset = Vector2(0, -prop_texture.get_height())
			_prop_layer.add_child(prop_sprite)
			_prop_nodes[map_pos] = prop_sprite
	elif _prop_nodes.has(map_pos):
		_prop_nodes[map_pos].queue_free()
		_prop_nodes.erase(map_pos)


func _cleanup_inactive_nodes(active_tiles: Dictionary) -> void:
	for tile in _ground_nodes.keys():
		if not active_tiles.has(tile):
			_ground_nodes[tile].queue_free()
			_ground_nodes.erase(tile)
	for tile in _prop_nodes.keys():
		if not active_tiles.has(tile):
			_prop_nodes[tile].queue_free()
			_prop_nodes.erase(tile)


# Tile data cache eviction: runs AFTER the node cleanup (never mid-pass) and
# bounds _tile_cache to the synced window, so out-of-window entries from older
# windows or off-window audit queries are reclaimed on the very next sync.
# Without it the cache grows by a window-edge per step, unbounded.
func _evict_tile_cache(active_tiles: Dictionary) -> void:
	for tile in _tile_cache.keys():
		if not active_tiles.has(tile):
			_tile_cache.erase(tile)


func _clear_rendered_nodes() -> void:
	for tile in _ground_nodes.keys():
		_ground_nodes[tile].queue_free()
	_ground_nodes.clear()
	for tile in _prop_nodes.keys():
		_prop_nodes[tile].queue_free()
	_prop_nodes.clear()


func _emit_biome_entered(center_tile: Vector2i) -> void:
	var biome = get_tile_biome(center_tile)
	if biome == _last_biome:
		return
	_last_biome = biome
	if biome.is_empty():
		return
	_runtime().emit_trace("biome_entered", "WorldView", {
		"biome": biome,
		"tile": [center_tile.x, center_tile.y]
	})


func _runtime() -> Node:
	return get_node(RuntimePath)


func _runtime_or_null() -> Node:
	return get_node_or_null(RuntimePath)
