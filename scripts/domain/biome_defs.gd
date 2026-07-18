extends RefCounted

# Biome and traversal definitions for the overworld generator.
# Pure data: texture paths, encounter flags, walkability, and prop scatter
# rules. Field-move keys record which future HM would clear a blocker; they are
# not enforced yet but are carried on every blocked tile so the field-moves
# slice can unlock traversal without rewriting world generation.

const BASE_WATER := "res://pokewilds/tiles/water1.png"
const BASE_SAND := "res://pokewilds/tiles/ground3.png"
const BASE_PLAINS := "res://pokewilds/ground1.png"
const BASE_GRASS := "res://pokewilds/grass1.png"
const BASE_SAVANNA := "res://pokewilds/tiles/green_savanna1.png"
const BASE_DESERT := "res://pokewilds/tiles/desert1.png"
const BASE_SWAMP := "res://pokewilds/tiles/swamp/swamp1.png"
const BASE_ROCK := "res://pokewilds/tiles/rock4.png"
const BASE_SNOW := "res://pokewilds/tiles/ice2.png"
const BASE_LAVA := "res://pokewilds/tiles/desert4_cracked.png"

# Solid ground colors composited under base textures that are really overlays
# (white-background detail sheets like grass1/ground1/water1, or alpha sheets
# like desert4_cracked). Null means the base texture is fully opaque as-is.
# The source Java engine color-keyed these over a filled tile; the compositing
# itself lives in scripts/runtime/tile_texture_cache.gd.
const GROUND_WATER := Color8(72, 144, 240)
const GROUND_SAND := Color8(226, 204, 148)
const GROUND_PLAINS := Color8(206, 210, 144)
const GROUND_GRASS := Color8(106, 186, 90)
const GROUND_FOREST := Color8(74, 148, 74)
const GROUND_LAVA := Color8(198, 52, 36)

const PROP_FLOWER := "res://pokewilds/tiles/flower1.png"
# tree1.png is a proper green tree; the old tree_small1 was a white-bodied
# stump that read as a ghost pawn even after background keying. Its grass
# background is baked in (opaque source greens), so it uses the "border"
# corner-color keying hint in tile_texture_cache.gd.
const PROP_TREE := "res://pokewilds/tiles/tree1.png"
const PROP_CACTUS := "res://pokewilds/tiles/cactus1.png"
const PROP_BUSH := "res://pokewilds/tiles/bush_savanna1.png"
const PROP_SWAMP_TREE := "res://pokewilds/tiles/swamp/tree13.png"
const PROP_LILLY := "res://pokewilds/tiles/swamp/lillypad1.png"
const PROP_ROCK := "res://pokewilds/rock_small1.png"
const PROP_SNOW_TREE := "res://pokewilds/tiles/spooky/tree1.png"
const PROP_LAVA := "res://pokewilds/tiles/lava_sheet1.png"

# Tall-grass encounter overlays for the grass biomes. These are white-
# background tuft sheets (verified: grass2_over/grass3_over/grass_savanna2 are
# 16x16 RGBA with opaque white borders), so they ride the same "white" flood-
# fill keying as the base overlays and composite over the ground in
# tile_texture_cache.gd. grass2_over is a bright 4-tuft patch for the open
# grassland, grass3_over a deeper green for the forest floor, grass_savanna2 a
# single yellowed tuft matching the savanna palette.
const TALL_GRASS_FIELD := "res://pokewilds/tiles/grass2_over.png"
const TALL_GRASS_FOREST := "res://pokewilds/tiles/grass3_over.png"
const TALL_GRASS_SAVANNA := "res://pokewilds/tiles/grass_savanna2.png"

const TILE_PIXELS := 16


func definitions() -> Dictionary:
	return {
		"WATER": _def("Water", BASE_WATER, false, false, "Deep water blocks your path.", "surf", _rect(0, 0), [], GROUND_WATER, "white"),
		"SAND": _def("Sand", BASE_SAND, false, true, "", "", null, [], GROUND_SAND),
		"PLAINS": _def("Plains", BASE_PLAINS, false, true, "", "", null, [
			_prop(PROP_FLOWER, false, 0.06, "", "")
		], GROUND_PLAINS),
		"GRASSLAND": _def("Grassland", BASE_GRASS, true, true, "", "", null, [
			_prop(PROP_FLOWER, false, 0.10, "", ""),
			_prop(PROP_TREE, true, 0.06, "A tall tree blocks the way.", "cut", null, "border")
		], GROUND_GRASS, "", _tall_grass(TALL_GRASS_FIELD, 0.10)),
		"FOREST": _def("Forest", BASE_GRASS, true, true, "", "", null, [
			_prop(PROP_TREE, true, 0.38, "A tall tree blocks the way.", "cut", null, "border"),
			_prop(PROP_FLOWER, false, 0.04, "", "")
		], GROUND_FOREST, "", _tall_grass(TALL_GRASS_FOREST, 0.20)),
		"SAVANNA": _def("Savanna", BASE_SAVANNA, true, true, "", "", null, [
			_prop(PROP_CACTUS, true, 0.14, "A cactus blocks the way.", ""),
			_prop(PROP_BUSH, false, 0.08, "", "")
		], null, "", _tall_grass(TALL_GRASS_SAVANNA, 0.15)),
		"DESERT": _def("Desert", BASE_DESERT, true, true, "", "", null, [
			_prop(PROP_CACTUS, true, 0.12, "A cactus blocks the way.", "")
		]),
		"SWAMP": _def("Swamp", BASE_SWAMP, true, true, "", "", null, [
			_prop(PROP_SWAMP_TREE, true, 0.18, "A swamp tree blocks the way.", "cut"),
			_prop(PROP_LILLY, false, 0.10, "", "")
		]),
		"ROCK": _def("Rock", BASE_ROCK, false, true, "", "", null, [
			_prop(PROP_ROCK, true, 0.22, "A rocky cliff blocks the way.", "smash")
		]),
		"SNOW": _def("Snow", BASE_SNOW, true, true, "", "", null, [
			_prop(PROP_SNOW_TREE, true, 0.16, "A snow-covered tree blocks the way.", "cut")
		]),
		"LAVA": _def("Lava", BASE_LAVA, true, true, "", "", null, [
			_prop(PROP_LAVA, true, 0.20, "Lava is too hot to cross.", "", _rect(0, 0))
		], GROUND_LAVA)
	}


func _def(display_name: String, base_path: String, encounter: bool, walkable: bool, block_reason: String, field_move: String, base_region: Variant, props: Array, ground_color: Variant = null, key_color := "", tall_grass: Variant = null) -> Dictionary:
	return {
		"display_name": display_name,
		"base_path": base_path,
		"base_region": base_region,
		"ground_color": ground_color,
		# Optional flood-fill hint for tile_texture_cache.gd ("white"/"black");
		# empty means auto-detect from the border. water1's waves reach its
		# border, so auto-detect cannot see its white background.
		"key_color": key_color,
		"encounter": encounter,
		"walkable": walkable,
		"block_reason": block_reason,
		"field_move": field_move,
		"props": props,
		# Optional tall-grass overlay data. When present (and the biome flags
		# encounter), wild encounters only fire on the scattered tall-grass
		# tiles instead of across the whole biome; see world_generator.gd.
		"tall_grass": tall_grass
	}


func _prop(path: String, block: bool, chance: float, reason: String, field_move: String, region: Variant = null, key_color := "") -> Dictionary:
	return {
		"path": path,
		"region": region,
		"block": block,
		"chance": chance,
		"reason": reason,
		"field_move": field_move,
		# Optional flood-fill hint for tile_texture_cache.gd ("border" keys the
		# corner-colored baked background); empty means auto-detect.
		"key_color": key_color
	}


# threshold is the tall-grass noise cutoff (world_generator.gd); higher means
# sparser patches. key_color forwards to the overlay keyer (these sheets all
# carry opaque white backgrounds, so "white" is the honest hint).
func _tall_grass(path: String, threshold: float, key_color := "white") -> Dictionary:
	return {
		"path": path,
		"threshold": threshold,
		"key_color": key_color
	}


func _rect(x: int, y: int) -> Rect2:
	return Rect2(x, y, TILE_PIXELS, TILE_PIXELS)
