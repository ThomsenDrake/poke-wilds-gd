extends RefCounted

# Shiny rendering (Phase 5; spec: docs/product-specs/pokemon-systems.md). FAITHFUL
# GSC MODEL: a shiny renders as the species' alternate battle PALETTE ("shiny
# colors" — the asset dump ships front.pal + shiny.pal siblings in 636/990 species
# folders, each two `RGB r, g, b` lines = the sprite's two custom colors on the GBC
# 0-31 scale; front.png is exactly black outline + white highlight + those two
# colors) plus a sparkle icon (pokewilds/shiny.png / shiny_inverse.png, committed as
# "+shiny icon for status screen"). Species WITHOUT a shiny.pal keep normal art +
# the sparkle badge only (documented fallback — the flag stays real for odds/breeding).
# OVERWORLD: the original draws shinies identically until battle or the status screen
# (wiki-overworld-encounters.md:230); the port's overworld hook is overworld-shiny.png
# (catalog "shiny_overworld_path", 579/990 folders — a full six-frame recolor sheet
# the Phase 6 overworld-mon entities + a future ride mount will swap in), and ground
# EGGS sparkle in the pen. The recolor is exact-match per palette color: unmatched
# pixels (outline/highlight/alpha) pass through, so anti-aliased art never smears.

const SHINY_ICON_PATH := "res://pokewilds/shiny_inverse.png"
const EGG_SHEET_PATH := "res://pokewilds/phione-egg.png" # 16x16 in-pen egg frames
const EGG_FRAME_SIZE := 16

var _frame_cache := {}
var _pal_cache := {}
var _sparkles := {} # slot key -> sparkle TextureRect (one per battle sprite)


# Sets the sprite's texture to the shiny-recolor of `path` when the mon is shiny
# (else the caller's normal frame), and keeps a standing gold sparkle badge on shiny
# mons. `slot` keys the sparkle child so enemy/player sprites never share one.
func apply_sprite(sprite: TextureRect, mon: Dictionary, path: String, normal_frame: Callable, slot: String) -> void:
	var is_shiny := bool(mon.get("is_shiny", false))
	if is_shiny:
		var shiny_texture := shiny_frame(path)
		sprite.texture = shiny_texture if shiny_texture != null else normal_frame.call(path)
	else:
		sprite.texture = normal_frame.call(path)
	_sync_sparkle(sprite, is_shiny, slot)


# The first frame of the sprite strip, palette-swapped to shiny colors (null when
# the sprite or its palettes are missing — callers fall back to normal art).
func shiny_frame(sprite_path: String) -> Texture2D:
	if sprite_path.is_empty() or not ResourceLoader.exists(sprite_path):
		return null
	var cached = _frame_cache.get(sprite_path)
	if cached != null or _frame_cache.has(sprite_path):
		return cached
	var texture = load(sprite_path)
	if texture == null or texture is not Texture2D:
		_frame_cache[sprite_path] = null
		return null
	var image: Image = (texture as Texture2D).get_image()
	var recolored := _recolor(image, sprite_path)
	var frame_texture := ImageTexture.create_from_image(recolored)
	var result: Texture2D = frame_texture
	# Vertical animation strips crop to the first square frame (battle_surface_layout's policy).
	if recolored.get_height() > recolored.get_width():
		var first := AtlasTexture.new()
		first.atlas = frame_texture
		first.region = Rect2(0, 0, recolored.get_width(), recolored.get_width())
		result = first
	_frame_cache[sprite_path] = result
	return result


# The standing shiny badge texture (white sparkle on transparent).
static func shiny_icon() -> Texture2D:
	return load(SHINY_ICON_PATH)


# The gold in-pen/party egg frame (first 16x16 cell of the egg sheet).
static func egg_frame() -> Texture2D:
	var texture = load(EGG_SHEET_PATH)
	if texture == null or texture is not Texture2D:
		return null
	var frame := AtlasTexture.new()
	frame.atlas = texture
	frame.region = Rect2(0, 0, EGG_FRAME_SIZE, EGG_FRAME_SIZE)
	return frame


func _recolor(image: Image, sprite_path: String) -> Image:
	var directory := sprite_path.get_base_dir()
	var from_colors := _palette(directory + "/front.pal")
	var to_colors := _palette(directory + "/shiny.pal")
	var recolored := image.duplicate() # never mutate the imported resource's image
	recolored.convert(Image.FORMAT_RGBA8)
	if from_colors.is_empty() or to_colors.is_empty():
		return recolored # no palettes: sparkle badge only (documented fallback)
	var pair_count := mini(from_colors.size(), to_colors.size())
	for y in range(recolored.get_height()):
		for x in range(recolored.get_width()):
			var pixel: Color = recolored.get_pixel(x, y)
			if pixel.a < 0.5:
				continue
			for i in range(pair_count):
				if _colors_close(pixel, from_colors[i]):
					recolored.set_pixel(x, y, to_colors[i])
					break
	return recolored


# Parses a .pal file's `RGB r, g, b` lines (GBC 0-31 scale -> 0-255).
func _palette(path: String) -> Array:
	if _pal_cache.has(path):
		return _pal_cache[path]
	var colors: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		for raw_line in file.get_as_text().split("\n"):
			var line := raw_line.strip_edges()
			if not line.begins_with("RGB "):
				continue
			var parts := line.substr(4).split(",")
			if parts.size() == 3:
				colors.append(Color8(_gbc_channel(parts[0]), _gbc_channel(parts[1]), _gbc_channel(parts[2])))
		file.close()
	_pal_cache[path] = colors
	return colors


# Exact-match within 1/255 tolerance: PNG round-trip can nudge a channel by one.
func _colors_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= 0.004 and absf(a.g - b.g) <= 0.004 and absf(a.b - b.b) <= 0.004


func _gbc_channel(token: String) -> int:
	return clampi(int(token.strip_edges()) * 255 / 31, 0, 255)


func _sync_sparkle(sprite: TextureRect, is_shiny: bool, slot: String) -> void:
	var sparkle: TextureRect = _sparkles.get(slot, null)
	if sparkle == null:
		sparkle = TextureRect.new()
		sparkle.texture = shiny_icon()
		sparkle.stretch_mode = TextureRect.STRETCH_KEEP
		sparkle.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sparkle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sparkle.position = Vector2(2, 2)
		sparkle.size = Vector2(8, 8)
		sparkle.modulate = Color(1.0, 0.85, 0.2) # gold, like the GSC sparkle
		sprite.add_child(sparkle)
		_sparkles[slot] = sparkle
	sparkle.visible = is_shiny
