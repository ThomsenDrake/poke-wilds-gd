extends RefCounted

# Cached texture processing for overworld rendering. The source PNGs were
# authored for the Java engine, which color-keyed opaque white (and sometimes
# black) backgrounds away at draw time; Godot renders them opaque, so tiles
# and props show solid white/black squares. For each unique texture path the
# source Image is loaded once, edge-connected near-white/near-black pixels are
# flood-filled to transparent from the borders (interior detail survives),
# base overlays are composited over the biome ground color, and tiny props are
# upscaled with nearest-neighbor so they read on a 16px tile.

const TILE_PIXELS := 16
# A border is keyed only when one extreme clearly dominates its opaque pixels.
# Thresholds are asymmetric on purpose: white backgrounds are common in this
# asset set (tree/flower/ground sheets sit at 40-80%), while the only true
# black background (rock_small1) sits above 90%. bush_savanna1's dark outline
# reaches ~50% of its border and must stay below the black threshold.
const WHITE_MIN := 0.88
const BLACK_MAX := 0.14
const WHITE_BORDER_NUM := 2  # keyed when white >= 2/5 (40%) of opaque border
const WHITE_BORDER_DEN := 5
const BLACK_BORDER_NUM := 3  # keyed when black >= 3/4 (75%) of opaque border
const BLACK_BORDER_DEN := 4
const KEY_NONE := 0
const KEY_WHITE := 1
const KEY_BLACK := 2
const KEY_MATCH := 3
# Tolerance for KEY_MATCH corner seeds; these sheets are hard-edged pixel art,
# so a small per-channel tolerance suffices.
const MATCH_TOL := 0.12

var _source_images: Dictionary = {}
var _processed: Dictionary = {}


func base_texture(tile_data: Dictionary) -> Texture2D:
	var ground = tile_data.get("ground_color", null)
	var tall_grass_path := str(tile_data.get("tall_grass_path", ""))
	if not (ground is Color) and tall_grass_path.is_empty():
		return tile_data["base_texture"]
	var path := str(tile_data.get("base_path", ""))
	var region = tile_data.get("base_region", null)
	var key_hint := str(tile_data.get("key_color", ""))
	var tall_grass_hint := str(tile_data.get("tall_grass_key_color", ""))
	var ground_key := (ground as Color).to_html() if ground is Color else "opaque"
	var key := "base|%s|%s|%s|%s|%s|%s" % [path, str(region), ground_key, key_hint, tall_grass_path, tall_grass_hint]
	if not _processed.has(key):
		var base_image := _region_image(path, region)
		if base_image.is_empty():
			return tile_data["base_texture"]
		var composed := base_image
		if ground is Color:
			_key_background(base_image, _forced_mode(key_hint))
			composed = Image.create(base_image.get_width(), base_image.get_height(), false, Image.FORMAT_RGBA8)
			composed.fill(ground)
			composed.blend_rect(base_image, Rect2i(0, 0, base_image.get_width(), base_image.get_height()), Vector2i.ZERO)
		if not tall_grass_path.is_empty():
			_blend_tall_grass(composed, tall_grass_path, tall_grass_hint)
		_processed[key] = ImageTexture.create_from_image(composed)
	return _processed[key]


# Tall-grass overlays are white-background tuft sheets keyed through the same
# flood fill as every other sheet, then stamped over the composited ground so
# encounter patches read on the base layer (world_generator.gd decides where).
func _blend_tall_grass(ground_image: Image, path: String, key_hint: String) -> void:
	var overlay := _region_image(path, null)
	if overlay.is_empty():
		return
	_key_background(overlay, _forced_mode(key_hint))
	var bounds := Rect2i(0, 0, ground_image.get_width(), ground_image.get_height())
	var rect := Rect2i(0, 0, overlay.get_width(), overlay.get_height()).intersection(bounds)
	if rect.size.x > 0 and rect.size.y > 0:
		ground_image.blend_rect(overlay, rect, Vector2i.ZERO)


func prop_texture(tile_data: Dictionary) -> Texture2D:
	var raw: Texture2D = tile_data.get("prop_texture", null)
	if raw == null:
		return null
	var path := str(tile_data.get("prop_path", ""))
	if path.is_empty():
		return raw
	var region = tile_data.get("prop_region", null)
	var key_hint := str(tile_data.get("prop_key_color", ""))
	var key := "prop|%s|%s|%s" % [path, str(region), key_hint]
	if not _processed.has(key):
		var image := _region_image(path, region)
		if image.is_empty():
			return raw
		_key_background(image, _forced_mode(key_hint))
		_processed[key] = ImageTexture.create_from_image(_upscaled_to_tile(image))
	return _processed[key]


func _forced_mode(key_hint: String) -> int:
	if key_hint == "white":
		return KEY_WHITE
	if key_hint == "black":
		return KEY_BLACK
	if key_hint == "border":
		return KEY_MATCH
	return KEY_NONE


func _region_image(path: String, region: Variant) -> Image:
	var full := _source_image(path)
	if full == null:
		return Image.new()
	if region is Rect2:
		var rect := Rect2i(region as Rect2).intersection(Rect2i(0, 0, full.get_width(), full.get_height()))
		if rect.size.x > 0 and rect.size.y > 0:
			return full.get_region(rect)
	return full.duplicate()


func _source_image(path: String) -> Image:
	if not _source_images.has(path):
		var image := Image.new()
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null or image.load_png_from_buffer(file.get_buffer(file.get_length())) != OK:
			_source_images[path] = null
		else:
			image.convert(Image.FORMAT_RGBA8)
			_source_images[path] = image
	return _source_images[path]


# Flood-fill from the borders: only background-colored pixels connected to an
# edge become transparent, so interior whites/blacks (outlines, highlights)
# are preserved. forced_mode skips border auto-detection (KEY_NONE = auto).
# KEY_MATCH keys the baked-in backgrounds of the source tree sheets: seeds are
# the distinct opaque corner colors (the source engine drew trees over its own
# grass green, so neither white nor black detection can see them).
func _key_background(image: Image, forced_mode: int) -> void:
	var mode := forced_mode
	if mode == KEY_NONE:
		mode = _border_key_mode(image)
	if mode == KEY_NONE:
		return
	var seeds: Array[Color] = []
	if mode == KEY_MATCH:
		seeds = _corner_seeds(image)
		if seeds.is_empty():
			return
	var width := image.get_width()
	var height := image.get_height()
	var visited := PackedByteArray()
	visited.resize(width * height)
	var stack: Array[Vector2i] = []
	for x in width:
		_seed(image, x, 0, mode, seeds, visited, stack)
		_seed(image, x, height - 1, mode, seeds, visited, stack)
	for y in range(1, height - 1):
		_seed(image, 0, y, mode, seeds, visited, stack)
		_seed(image, width - 1, y, mode, seeds, visited, stack)
	while not stack.is_empty():
		var pixel: Vector2i = stack.pop_back()
		for neighbor in _neighbors(pixel, mode):
			_seed(image, neighbor.x, neighbor.y, mode, seeds, visited, stack)


func _corner_seeds(image: Image) -> Array[Color]:
	var seeds: Array[Color] = []
	var w := image.get_width()
	var h := image.get_height()
	for corner in [image.get_pixel(0, 0), image.get_pixel(w - 1, 0), image.get_pixel(0, h - 1), image.get_pixel(w - 1, h - 1)]:
		if corner.a < 0.5:
			continue
		var known := false
		for seed in seeds:
			if _color_near(seed, corner, MATCH_TOL):
				known = true
				break
		if not known:
			seeds.append(corner)
	return seeds


# White backgrounds in this asset set are dithered (tree_small1 foliage is a
# white/green checkerboard); diagonal connectivity lets the fill thread the
# dither. Black backgrounds (rock_small1) and corner-matched backgrounds stay
# 4-connected so the fill cannot leak diagonally into sprite detail.
func _neighbors(pixel: Vector2i, mode: int) -> Array[Vector2i]:
	var straight: Array[Vector2i] = [pixel + Vector2i.LEFT, pixel + Vector2i.RIGHT, pixel + Vector2i.UP, pixel + Vector2i.DOWN]
	if mode != KEY_WHITE:
		return straight
	var all := straight
	for diagonal in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		all.append(pixel + diagonal)
	return all


func _seed(image: Image, x: int, y: int, mode: int, seeds: Array[Color], visited: PackedByteArray, stack: Array[Vector2i]) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	var index := y * image.get_width() + x
	if visited[index] == 1:
		return
	visited[index] = 1
	var color := image.get_pixel(x, y)
	if not _matches_key(color, mode, seeds):
		return
	image.set_pixel(x, y, Color(color.r, color.g, color.b, 0.0))
	stack.append(Vector2i(x, y))


func _border_key_mode(image: Image) -> int:
	var width := image.get_width()
	var height := image.get_height()
	var opaque := 0
	var white := 0
	var black := 0
	for x in width:
		for y in [0, height - 1]:
			var color := image.get_pixel(x, y)
			if color.a < 0.5:
				continue
			opaque += 1
			if _is_near_white(color):
				white += 1
			elif _is_near_black(color):
				black += 1
	for y in range(1, height - 1):
		for x in [0, width - 1]:
			var color := image.get_pixel(x, y)
			if color.a < 0.5:
				continue
			opaque += 1
			if _is_near_white(color):
				white += 1
			elif _is_near_black(color):
				black += 1
	if opaque == 0:
		return KEY_NONE
	if white * WHITE_BORDER_DEN >= opaque * WHITE_BORDER_NUM and white > 0:
		return KEY_WHITE
	if black * BLACK_BORDER_DEN >= opaque * BLACK_BORDER_NUM and black > 0:
		return KEY_BLACK
	return KEY_NONE


func _matches_key(color: Color, mode: int, seeds: Array[Color]) -> bool:
	if color.a < 0.5:
		return false
	if mode == KEY_MATCH:
		for seed in seeds:
			if _color_near(seed, color, MATCH_TOL):
				return true
		return false
	if mode == KEY_WHITE:
		return _is_near_white(color)
	return _is_near_black(color)


func _color_near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol


func _is_near_white(color: Color) -> bool:
	return color.r >= WHITE_MIN and color.g >= WHITE_MIN and color.b >= WHITE_MIN


func _is_near_black(color: Color) -> bool:
	return color.r <= BLACK_MAX and color.g <= BLACK_MAX and color.b <= BLACK_MAX


# Small props (rock_small1 is 8x8) are upscaled with an integer factor so they
# still read as crisp pixel art on a 16px tile.
func _upscaled_to_tile(image: Image) -> Image:
	var width := image.get_width()
	var height := image.get_height()
	if width >= TILE_PIXELS or height >= TILE_PIXELS:
		return image
	var factor: int = maxi(maxi(1, int(ceil(float(TILE_PIXELS) / width))), int(ceil(float(TILE_PIXELS) / height)))
	image.resize(width * factor, height * factor, Image.INTERPOLATE_NEAREST)
	return image
