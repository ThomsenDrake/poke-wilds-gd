class_name TileMapManager
extends Node2D
## TileMapManager - Manages multi-layer tilemaps for the overworld
## Handles terrain rendering, collision data, and chunk loading

# Signals
signal chunk_loaded(chunk_pos: Vector2i)
signal tile_changed(world_pos: Vector2i, new_tile: WorldGenerator.TileType)

# Tilemap layers - initialized in _ready(), not @onready to avoid errors
var ground_layer: TileMapLayer = null
var decoration_layer: TileMapLayer = null
var collision_layer: TileMapLayer = null

# World generator reference
var world_generator: WorldGenerator

# Loaded chunks cache
var _loaded_chunks: Dictionary = {}  # Vector2i -> Array (chunk data)
var _chunk_size: int = 32

# View distance in chunks
var load_distance: int = 2

# Tile atlas coordinates (will be set up properly with actual tileset)
# For now using simple source_id = 0 with atlas coords
const TILE_COORDS := {
	WorldGenerator.TileType.GRASS: Vector2i(0, 0),
	WorldGenerator.TileType.TALL_GRASS: Vector2i(1, 0),
	WorldGenerator.TileType.WATER: Vector2i(2, 0),
	WorldGenerator.TileType.DEEP_WATER: Vector2i(3, 0),
	WorldGenerator.TileType.SAND: Vector2i(4, 0),
	WorldGenerator.TileType.DIRT: Vector2i(5, 0),
	WorldGenerator.TileType.TREE: Vector2i(6, 0),       # Tree bottom (trunk)
	WorldGenerator.TileType.ROCK: Vector2i(7, 0),
	WorldGenerator.TileType.FLOWER: Vector2i(0, 1),
	WorldGenerator.TileType.PATH: Vector2i(1, 1)
}

# Additional tile coords for multi-tile objects
const TREE_TOP_COORDS := Vector2i(2, 1)  # Tree top (foliage)


func _ready() -> void:
	# Try to get existing child layers first
	ground_layer = get_node_or_null("GroundLayer") as TileMapLayer
	decoration_layer = get_node_or_null("DecorationLayer") as TileMapLayer
	collision_layer = get_node_or_null("CollisionLayer") as TileMapLayer
	
	# Create layers if they don't exist as children
	if ground_layer == null:
		ground_layer = TileMapLayer.new()
		ground_layer.name = "GroundLayer"
		add_child(ground_layer)
	
	if decoration_layer == null:
		decoration_layer = TileMapLayer.new()
		decoration_layer.name = "DecorationLayer"
		decoration_layer.z_index = 1  # Render above ground layer
		add_child(decoration_layer)
	
	if collision_layer == null:
		collision_layer = TileMapLayer.new()
		collision_layer.name = "CollisionLayer"
		collision_layer.visible = false  # Collision layer is invisible
		add_child(collision_layer)


## Initialize with a world generator
func initialize(generator: WorldGenerator) -> void:
	world_generator = generator
	_chunk_size = generator.chunk_size


## Update loaded chunks based on player position
func update_chunks(player_world_pos: Vector2) -> void:
	if world_generator == null:
		return
	
	var player_chunk := Vector2i(
		int(player_world_pos.x / 16) / _chunk_size,
		int(player_world_pos.y / 16) / _chunk_size
	)
	
	# Load chunks in range
	for cx in range(player_chunk.x - load_distance, player_chunk.x + load_distance + 1):
		for cy in range(player_chunk.y - load_distance, player_chunk.y + load_distance + 1):
			var chunk_pos := Vector2i(cx, cy)
			if not _loaded_chunks.has(chunk_pos):
				_load_chunk(chunk_pos)
	
	# Unload distant chunks
	var chunks_to_unload: Array[Vector2i] = []
	for chunk_pos in _loaded_chunks.keys():
		var dist := Vector2(chunk_pos - player_chunk).length()
		if dist > load_distance + 2:
			chunks_to_unload.append(chunk_pos)
	
	for chunk_pos in chunks_to_unload:
		_unload_chunk(chunk_pos)


## Load a chunk
func _load_chunk(chunk_pos: Vector2i) -> void:
	if world_generator == null:
		return
	
	# Generate chunk data
	var chunk_data := world_generator.generate_chunk(chunk_pos.x, chunk_pos.y)
	_loaded_chunks[chunk_pos] = chunk_data
	
	# Place tiles
	var base_x := chunk_pos.x * _chunk_size
	var base_y := chunk_pos.y * _chunk_size
	
	for local_y in range(_chunk_size):
		for local_x in range(_chunk_size):
			var world_tile := Vector2i(base_x + local_x, base_y + local_y)
			var tile_type: WorldGenerator.TileType = chunk_data[local_y][local_x]
			_set_tile(world_tile, tile_type)
	
	chunk_loaded.emit(chunk_pos)


## Unload a chunk
func _unload_chunk(chunk_pos: Vector2i) -> void:
	if not _loaded_chunks.has(chunk_pos):
		return
	
	var base_x := chunk_pos.x * _chunk_size
	var base_y := chunk_pos.y * _chunk_size
	
	# Clear tiles
	for local_y in range(_chunk_size):
		for local_x in range(_chunk_size):
			var world_tile := Vector2i(base_x + local_x, base_y + local_y)
			ground_layer.erase_cell(world_tile)
			decoration_layer.erase_cell(world_tile)
			collision_layer.erase_cell(world_tile)
	
	_loaded_chunks.erase(chunk_pos)


## Set a tile at world position
func _set_tile(world_tile: Vector2i, tile_type: WorldGenerator.TileType) -> void:
	var atlas_coords: Vector2i = TILE_COORDS.get(tile_type, Vector2i(0, 0))
	
	# Ground layer - base terrain
	match tile_type:
		WorldGenerator.TileType.GRASS, WorldGenerator.TileType.SAND, \
		WorldGenerator.TileType.DIRT, WorldGenerator.TileType.PATH:
			ground_layer.set_cell(world_tile, 0, atlas_coords)
		WorldGenerator.TileType.WATER, WorldGenerator.TileType.DEEP_WATER:
			ground_layer.set_cell(world_tile, 0, atlas_coords)
		WorldGenerator.TileType.TALL_GRASS:
			# Tall grass: grass underneath, decoration on top
			ground_layer.set_cell(world_tile, 0, TILE_COORDS[WorldGenerator.TileType.GRASS])
			decoration_layer.set_cell(world_tile, 0, atlas_coords)
		WorldGenerator.TileType.TREE:
			# Trees: grass underneath, tree bottom (trunk) + tree top (foliage) above
			ground_layer.set_cell(world_tile, 0, TILE_COORDS[WorldGenerator.TileType.GRASS])
			decoration_layer.set_cell(world_tile, 0, atlas_coords)  # Tree trunk
			# Render tree top one tile above (foliage)
			var top_tile := Vector2i(world_tile.x, world_tile.y - 1)
			decoration_layer.set_cell(top_tile, 0, TREE_TOP_COORDS)
		WorldGenerator.TileType.ROCK:
			# Rocks: grass underneath, rock on decoration layer
			ground_layer.set_cell(world_tile, 0, TILE_COORDS[WorldGenerator.TileType.GRASS])
			decoration_layer.set_cell(world_tile, 0, atlas_coords)
		WorldGenerator.TileType.FLOWER:
			# Flowers: grass underneath, flower on decoration
			ground_layer.set_cell(world_tile, 0, TILE_COORDS[WorldGenerator.TileType.GRASS])
			decoration_layer.set_cell(world_tile, 0, atlas_coords)


## Get tile type at world tile position
func get_tile_type(world_tile: Vector2i) -> WorldGenerator.TileType:
	# Check cache first
	var chunk_pos := Vector2i(world_tile.x / _chunk_size, world_tile.y / _chunk_size)
	if _loaded_chunks.has(chunk_pos):
		var local_x := world_tile.x % _chunk_size
		var local_y := world_tile.y % _chunk_size
		# Handle negative coordinates
		if local_x < 0:
			local_x += _chunk_size
		if local_y < 0:
			local_y += _chunk_size
		return _loaded_chunks[chunk_pos][local_y][local_x]
	
	# Generate on-demand
	if world_generator:
		return world_generator.get_tile_at(world_tile.x, world_tile.y)
	
	return WorldGenerator.TileType.GRASS


## Check if a tile is solid (blocks movement)
func is_tile_solid(world_tile: Vector2i) -> bool:
	var tile_type := get_tile_type(world_tile)
	if world_generator:
		return world_generator.is_solid(tile_type)
	return false


## Check if a tile triggers encounters
func is_encounter_tile(world_tile: Vector2i) -> bool:
	var tile_type := get_tile_type(world_tile)
	if world_generator:
		return world_generator.is_encounter_tile(tile_type)
	return false


## Check if a tile is swimmable
func is_tile_swimmable(world_tile: Vector2i) -> bool:
	var tile_type := get_tile_type(world_tile)
	if world_generator:
		return world_generator.is_swimmable(tile_type)
	return false


## Get tile name at position
func get_tile_name(world_tile: Vector2i) -> String:
	var tile_type := get_tile_type(world_tile)
	if world_generator:
		return world_generator.get_tile_name(tile_type)
	return "unknown"


## Convert world position to tile position
func world_to_tile(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(world_pos.x) / 16, int(world_pos.y) / 16)


## Convert tile position to world position (center of tile)
func tile_to_world(tile_pos: Vector2i) -> Vector2:
	return Vector2(tile_pos.x * 16 + 8, tile_pos.y * 16 + 8)


## Set a tile at world position by name (for field moves like CUT, ROCK_SMASH)
func set_tile(world_tile: Vector2i, tile_name: String) -> bool:
	var tile_type := _name_to_tile_type(tile_name)
	if tile_type == -1:
		return false
	
	# Update chunk cache
	var chunk_pos := Vector2i(world_tile.x / _chunk_size, world_tile.y / _chunk_size)
	if _loaded_chunks.has(chunk_pos):
		var local_x := world_tile.x % _chunk_size
		var local_y := world_tile.y % _chunk_size
		if local_x < 0:
			local_x += _chunk_size
		if local_y < 0:
			local_y += _chunk_size
		_loaded_chunks[chunk_pos][local_y][local_x] = tile_type
	
	# Clear old decorations
	decoration_layer.erase_cell(world_tile)
	
	# Set new tile
	_set_tile(world_tile, tile_type)
	
	tile_changed.emit(world_tile, tile_type)
	return true


## Convert tile name to TileType enum
func _name_to_tile_type(tile_name: String) -> int:
	match tile_name.to_lower():
		"grass": return WorldGenerator.TileType.GRASS
		"tall_grass": return WorldGenerator.TileType.TALL_GRASS
		"water": return WorldGenerator.TileType.WATER
		"deep_water": return WorldGenerator.TileType.DEEP_WATER
		"sand": return WorldGenerator.TileType.SAND
		"dirt": return WorldGenerator.TileType.DIRT
		"tree": return WorldGenerator.TileType.TREE
		"rock": return WorldGenerator.TileType.ROCK
		"flower": return WorldGenerator.TileType.FLOWER
		"path": return WorldGenerator.TileType.PATH
		_: return -1
