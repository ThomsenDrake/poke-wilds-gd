class_name WorldGenerator
extends RefCounted
## WorldGenerator - Procedural terrain generation using noise
## Generates Pokemon-style overworld terrain with grass, water, trees, etc.

# Tile types with their properties
enum TileType {
	GRASS,
	TALL_GRASS,
	WATER,
	DEEP_WATER,
	SAND,
	DIRT,
	TREE,
	ROCK,
	FLOWER,
	PATH
}

# Tile properties
const TILE_DATA := {
	TileType.GRASS: {
		"name": "grass",
		"solid": false,
		"encounter": false,
		"walkable": true,
		"swimmable": false
	},
	TileType.TALL_GRASS: {
		"name": "tall_grass",
		"solid": false,
		"encounter": true,
		"walkable": true,
		"swimmable": false
	},
	TileType.WATER: {
		"name": "water",
		"solid": true,  # Solid unless you have Surf
		"encounter": true,
		"walkable": false,
		"swimmable": true
	},
	TileType.DEEP_WATER: {
		"name": "deep_water",
		"solid": true,
		"encounter": true,
		"walkable": false,
		"swimmable": true
	},
	TileType.SAND: {
		"name": "sand",
		"solid": false,
		"encounter": false,
		"walkable": true,
		"swimmable": false
	},
	TileType.DIRT: {
		"name": "dirt",
		"solid": false,
		"encounter": false,
		"walkable": true,
		"swimmable": false
	},
	TileType.TREE: {
		"name": "tree",
		"solid": true,
		"encounter": false,
		"walkable": false,
		"swimmable": false
	},
	TileType.ROCK: {
		"name": "rock",
		"solid": true,
		"encounter": false,
		"walkable": false,
		"swimmable": false
	},
	TileType.FLOWER: {
		"name": "flower",
		"solid": false,
		"encounter": false,
		"walkable": true,
		"swimmable": false
	},
	TileType.PATH: {
		"name": "path",
		"solid": false,
		"encounter": false,
		"walkable": true,
		"swimmable": false
	}
}

# Generation parameters
var world_seed: int = 0
var chunk_size: int = 32  # Tiles per chunk

# Noise generators
var _elevation_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _detail_noise: FastNoiseLite

# Thresholds for biome determination
const WATER_THRESHOLD := -0.2
const DEEP_WATER_THRESHOLD := -0.4
const SAND_THRESHOLD := -0.05
const TREE_THRESHOLD := 0.6
const TALL_GRASS_THRESHOLD := 0.3

# Generation settings
var tree_density := 0.15      # Chance of tree in forest area
var tall_grass_density := 0.4 # Chance of tall grass
var flower_density := 0.05    # Chance of flowers in grass
var rock_density := 0.02      # Chance of rocks


func _init(seed_value: int = 0) -> void:
	if seed_value == 0:
		seed_value = randi()
	world_seed = seed_value
	_setup_noise()


func _setup_noise() -> void:
	# Elevation noise - determines water vs land
	_elevation_noise = FastNoiseLite.new()
	_elevation_noise.seed = world_seed
	_elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_elevation_noise.frequency = 0.02
	_elevation_noise.fractal_octaves = 4
	_elevation_noise.fractal_lacunarity = 2.0
	_elevation_noise.fractal_gain = 0.5
	
	# Moisture noise - determines forest vs plains
	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.seed = world_seed + 1000
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.frequency = 0.03
	_moisture_noise.fractal_octaves = 3
	
	# Detail noise - for small variations
	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = world_seed + 2000
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.frequency = 0.1


## Generate a chunk of terrain
## Returns a 2D array of TileType values
func generate_chunk(chunk_x: int, chunk_y: int) -> Array:
	var tiles: Array = []
	
	for local_y in range(chunk_size):
		var row: Array = []
		for local_x in range(chunk_size):
			var world_x := chunk_x * chunk_size + local_x
			var world_y := chunk_y * chunk_size + local_y
			var tile := _get_tile_at(world_x, world_y)
			row.append(tile)
		tiles.append(row)
	
	return tiles


## Get tile type at a specific world position
func _get_tile_at(x: int, y: int) -> TileType:
	var elevation := _elevation_noise.get_noise_2d(x, y)
	var moisture := _moisture_noise.get_noise_2d(x, y)
	var detail := _detail_noise.get_noise_2d(x, y)
	
	# Deep water
	if elevation < DEEP_WATER_THRESHOLD:
		return TileType.DEEP_WATER
	
	# Shallow water
	if elevation < WATER_THRESHOLD:
		return TileType.WATER
	
	# Beach/sand near water
	if elevation < SAND_THRESHOLD:
		return TileType.SAND
	
	# Use RNG seeded by position for consistent random placement
	var pos_seed := _position_hash(x, y)
	var rng := RandomNumberGenerator.new()
	rng.seed = pos_seed
	
	# Forest areas (high moisture)
	if moisture > TREE_THRESHOLD:
		# Trees in forest
		if rng.randf() < tree_density:
			return TileType.TREE
		# Tall grass in forest clearings
		if rng.randf() < tall_grass_density * 0.5:
			return TileType.TALL_GRASS
		return TileType.GRASS
	
	# Grassy plains (medium moisture)
	if moisture > 0.0:
		# Tall grass patches
		if detail > TALL_GRASS_THRESHOLD and rng.randf() < tall_grass_density:
			return TileType.TALL_GRASS
		# Occasional flowers
		if rng.randf() < flower_density:
			return TileType.FLOWER
		# Occasional rocks
		if rng.randf() < rock_density:
			return TileType.ROCK
		return TileType.GRASS
	
	# Dry areas (low moisture)
	if rng.randf() < rock_density * 2:
		return TileType.ROCK
	if rng.randf() < 0.3:
		return TileType.DIRT
	return TileType.GRASS


## Get a consistent hash for a position (for deterministic random)
func _position_hash(x: int, y: int) -> int:
	# Simple hash combining position and world seed
	return world_seed + x * 73856093 + y * 19349663


## Check if a tile is solid (blocks movement)
func is_solid(tile_type: TileType) -> bool:
	return TILE_DATA[tile_type].solid


## Check if a tile triggers encounters
func is_encounter_tile(tile_type: TileType) -> bool:
	return TILE_DATA[tile_type].encounter


## Check if a tile is walkable
func is_walkable(tile_type: TileType) -> bool:
	return TILE_DATA[tile_type].walkable


## Check if a tile is swimmable
func is_swimmable(tile_type: TileType) -> bool:
	return TILE_DATA[tile_type].swimmable


## Get tile type at world position (convenience method)
func get_tile_at(x: int, y: int) -> TileType:
	return _get_tile_at(x, y)


## Get tile name for a type
func get_tile_name(tile_type: TileType) -> String:
	return TILE_DATA[tile_type].name


## Generate spawn point - finds a valid grass tile near origin
func find_spawn_point(search_radius: int = 50) -> Vector2i:
	# Start from center and spiral outward
	for radius in range(search_radius):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if absi(dx) == radius or absi(dy) == radius:  # Only check edge
					var tile := _get_tile_at(dx, dy)
					if tile == TileType.GRASS:
						return Vector2i(dx, dy)
	
	# Fallback to origin
	return Vector2i.ZERO


## Create a clearing around a point (for player bases, towns)
func create_clearing(center_x: int, center_y: int, radius: int, tiles: Array) -> void:
	var chunk_start_x := (center_x / chunk_size) * chunk_size
	var chunk_start_y := (center_y / chunk_size) * chunk_size
	
	for local_y in range(tiles.size()):
		for local_x in range(tiles[local_y].size()):
			var world_x := chunk_start_x + local_x
			var world_y := chunk_start_y + local_y
			var dist := Vector2(world_x - center_x, world_y - center_y).length()
			
			if dist < radius:
				# Clear trees and rocks in the clearing
				var current_tile: TileType = tiles[local_y][local_x]
				if current_tile == TileType.TREE or current_tile == TileType.ROCK:
					tiles[local_y][local_x] = TileType.GRASS
				# Make inner area dirt/path
				if dist < radius * 0.3:
					tiles[local_y][local_x] = TileType.DIRT
