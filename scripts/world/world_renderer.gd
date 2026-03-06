extends Node2D

const TILE_SIZE := 16
const WorldGenerator := preload("res://scripts/world/world_generator.gd")

@export var world_seed: int = 1337
@export var half_width_tiles: int = 30
@export var half_height_tiles: int = 20

@onready var _ground_layer: Node2D = $GroundLayer
@onready var _prop_layer: Node2D = $PropLayer

var _generator = WorldGenerator.new()
var _tile_cache: Dictionary = {}
var _ground_nodes: Dictionary = {}
var _prop_nodes: Dictionary = {}


func _ready() -> void:
	rebuild(world_seed)


func sync_visible(center_tile: Vector2i) -> void:
	var active_tiles: Dictionary = {}

	for y in range(center_tile.y - half_height_tiles, center_tile.y + half_height_tiles + 1):
		for x in range(center_tile.x - half_width_tiles, center_tile.x + half_width_tiles + 1):
			var tile = Vector2i(x, y)
			active_tiles[tile] = true
			_ensure_tile_nodes(tile)

	_cleanup_inactive_nodes(active_tiles)


func map_to_world(map_pos: Vector2i) -> Vector2:
	return Vector2(map_pos.x * TILE_SIZE, map_pos.y * TILE_SIZE)


func world_to_map(world_pos: Vector2) -> Vector2i:
	return Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))


func is_tile_walkable(map_pos: Vector2i) -> bool:
	return _get_tile_data(map_pos)["walkable"]


func is_encounter_tile(map_pos: Vector2i) -> bool:
	return _get_tile_data(map_pos)["encounter"]


func rebuild(seed_value: int) -> void:
	world_seed = seed_value
	_generator.setup(world_seed)
	_tile_cache.clear()
	_clear_rendered_nodes()


func _get_tile_data(map_pos: Vector2i) -> Dictionary:
	if not _tile_cache.has(map_pos):
		_tile_cache[map_pos] = _generator.get_tile(map_pos)
	return _tile_cache[map_pos]


func _ensure_tile_nodes(map_pos: Vector2i) -> void:
	var tile_data = _get_tile_data(map_pos)

	if not _ground_nodes.has(map_pos):
		var ground_sprite = Sprite2D.new()
		ground_sprite.centered = false
		ground_sprite.texture = tile_data["base_texture"]
		ground_sprite.position = map_to_world(map_pos)
		_ground_layer.add_child(ground_sprite)
		_ground_nodes[map_pos] = ground_sprite

	var prop_texture: Texture2D = tile_data["prop_texture"]
	if prop_texture != null:
		if not _prop_nodes.has(map_pos):
			var prop_sprite = Sprite2D.new()
			prop_sprite.centered = false
			prop_sprite.texture = prop_texture
			prop_sprite.position = map_to_world(map_pos) + Vector2(0, TILE_SIZE - prop_texture.get_height())
			prop_sprite.z_index = 2
			_prop_layer.add_child(prop_sprite)
			_prop_nodes[map_pos] = prop_sprite
	else:
		if _prop_nodes.has(map_pos):
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


func _clear_rendered_nodes() -> void:
	for tile in _ground_nodes.keys():
		_ground_nodes[tile].queue_free()
	_ground_nodes.clear()

	for tile in _prop_nodes.keys():
		_prop_nodes[tile].queue_free()
	_prop_nodes.clear()
