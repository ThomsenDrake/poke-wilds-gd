extends RefCounted

enum TileType {
	WATER,
	SAND,
	GROUND,
	GRASS
}

const TILE_SIZE := 16

var _seed: int = 1337
var _elevation_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _textures: Dictionary = {}


func setup(seed_value: int) -> void:
	_seed = seed_value

	_elevation_noise = FastNoiseLite.new()
	_elevation_noise.seed = _seed
	_elevation_noise.frequency = 0.010
	_elevation_noise.fractal_octaves = 4
	_elevation_noise.fractal_lacunarity = 2.0
	_elevation_noise.fractal_gain = 0.45

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.seed = _seed + 9931
	_moisture_noise.frequency = 0.016
	_moisture_noise.fractal_octaves = 3
	_moisture_noise.fractal_lacunarity = 2.2
	_moisture_noise.fractal_gain = 0.50

	_textures = {
		"ground": load("res://pokewilds/ground1.png"),
		"sand": load("res://pokewilds/tiles/sand1.png"),
		"grass": load("res://pokewilds/grass1.png"),
		"tree": load("res://pokewilds/tiles/tree_small1.png"),
		"water": _make_atlas_frame("res://pokewilds/tiles/water1.png", Rect2(0, 0, TILE_SIZE, TILE_SIZE))
	}


func get_tile(map_pos: Vector2i) -> Dictionary:
	var elevation = _elevation_noise.get_noise_2d(map_pos.x, map_pos.y)
	var moisture = _moisture_noise.get_noise_2d(map_pos.x, map_pos.y)

	var tile_type = TileType.GROUND
	var walkable = true
	var encounter = false
	var base_texture: Texture2D = _textures["ground"]
	var prop_texture: Texture2D = null

	if elevation < -0.30:
		tile_type = TileType.WATER
		walkable = false
		base_texture = _textures["water"]
	elif elevation < -0.12:
		tile_type = TileType.SAND
		base_texture = _textures["sand"]
	elif moisture > 0.18:
		tile_type = TileType.GRASS
		encounter = true
		base_texture = _textures["grass"]

	if walkable and tile_type != TileType.SAND:
		var tree_roll = _coord_noise(map_pos.x, map_pos.y, 17)
		if moisture > 0.36 and tree_roll > 0.82:
			walkable = false
			prop_texture = _textures["tree"]

	return {
		"type": tile_type,
		"walkable": walkable,
		"encounter": encounter,
		"base_texture": base_texture,
		"prop_texture": prop_texture
	}


func _coord_noise(x: int, y: int, salt: int) -> float:
	var n = int(x) * 374761393 + int(y) * 668265263 + _seed * 104729 + salt * 4256233
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / float(0x7fffffff)


func _make_atlas_frame(texture_path: String, region: Rect2) -> AtlasTexture:
	var frame = AtlasTexture.new()
	frame.atlas = load(texture_path)
	frame.region = region
	return frame
