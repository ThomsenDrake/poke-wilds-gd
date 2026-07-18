extends Node

# Asset-integrity audits dispatched from SmokeScenarios (the data half lives
# in qa_data_checks.gd behind run_data). run_texture drives every catalog
# battle sprite through the real battle loader (battle_surface_layout.gd
# pokemon_frame) and every overworld base/prop/tall-grass sheet referenced
# by the biome definitions through the real tile cache
# (tile_texture_cache.gd), failing on mangled, placeholder-bound, or
# unkeyed art. Failures are collected and reported via push_error; the
# pass event fires only when clean. Domain/data pieces are reached through
# the GameRuntime instance so this app-layer file keeps no direct
# domain/data script dependency.

const BattleSurfaceLayout := preload("res://scripts/ui/battle_surface_layout.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")
const DataChecks := preload("res://scripts/app/qa_data_checks.gd")

const MIN_SPRITE_PX := 16
const MAX_SPRITE_PX := 80
const MIN_INK_RATIO := 0.05
const SOLID_BORDER := 0.75
const NEAR_WHITE := 0.88
const NEAR_BLACK := 0.14

var _ctx: Dictionary = {}
var _failures: Array = []


func run_texture(ctx: Dictionary) -> void:
	_ctx = ctx
	_failures = []
	var layout = BattleSurfaceLayout.new()
	var species_checked := 0
	var frames_seen := 0
	for species_id in _sorted_keys(_catalog().species):
		var entry: Dictionary = _catalog().species[species_id]
		var front := str(entry.get("front_path", ""))
		var back := str(entry.get("back_path", ""))
		if front.is_empty() or back.is_empty():
			continue
		species_checked += 1
		frames_seen += _audit_sprite(layout, species_id, "front", front)
		frames_seen += _audit_sprite(layout, species_id, "back", back)
	_finish("texture_audit_passed", {
		"species_checked": species_checked,
		"frames_seen": frames_seen,
		"tiles_checked": _audit_tiles()
	})


func run_data(ctx: Dictionary) -> void:
	_ctx = ctx
	_failures = []
	var result: Dictionary = DataChecks.new().run_all(ctx)
	_failures = result.get("failures", [])
	_finish("data_audit_passed", result.get("payload", {}))


# Validates the frame the battle loader actually returns for one sprite:
# real texture (never the `?` placeholder), square after the strip crop,
# sane size, and visibly inked. Returns the animation frame count seen in
# the source (vertical strips count width x width cells).
func _audit_sprite(layout, species_id: String, side: String, path: String) -> int:
	var label := "%s %s (%s)" % [species_id, side, path]
	if not ResourceLoader.exists(path):
		_failures.append("%s: missing sprite, battle would show the placeholder" % label)
		return 0
	var raw = load(path)
	if raw is not Texture2D:
		_failures.append("%s: resource is not a texture" % label)
		return 0
	var frames := 1
	if raw.get_height() > raw.get_width() and raw.get_height() % raw.get_width() == 0:
		frames = raw.get_height() / raw.get_width()
	var frame: Texture2D = layout.pokemon_frame(path)
	if frame.get_width() != frame.get_height():
		_failures.append("%s: frame %dx%d not square (source %dx%d)" % [label, frame.get_width(), frame.get_height(), raw.get_width(), raw.get_height()])
	elif frame.get_width() < MIN_SPRITE_PX or frame.get_width() > MAX_SPRITE_PX:
		_failures.append("%s: frame %dpx outside %d..%d" % [label, frame.get_width(), MIN_SPRITE_PX, MAX_SPRITE_PX])
	elif _ink_ratio(frame) <= MIN_INK_RATIO:
		_failures.append("%s: frame has almost no visible pixels" % label)
	return frames


func _ink_ratio(texture: Texture2D) -> float:
	var image := texture.get_image()
	if image == null or image.is_empty():
		return 0.0
	var total := image.get_width() * image.get_height()
	var needed := int(total * MIN_INK_RATIO)
	var ink := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.5:
				ink += 1
				if ink > needed:
					return float(ink) / float(total)
	return float(ink) / float(total)


# Every base/prop/tall-grass sheet referenced by the biome definitions,
# pulled through the real cache with the same tile_data the world view
# builds, so keying and ground compositing run exactly as in-game.
func _audit_tiles() -> int:
	var cache = TileTextureCache.new()
	var checked := 0
	for biome in _sorted_keys(_biome_defs()):
		var def: Dictionary = _biome_defs()[biome]
		var tall_grass = def.get("tall_grass", null)
		var tall_path := str(tall_grass.get("path", "")) if tall_grass is Dictionary else ""
		checked += 1 + (1 if not tall_path.is_empty() else 0)
		_audit_tile(cache.base_texture({
			"base_texture": _raw_texture(str(def["base_path"]), def.get("base_region", null)),
			"base_path": str(def["base_path"]),
			"base_region": def.get("base_region", null),
			"ground_color": def.get("ground_color", null),
			"key_color": str(def.get("key_color", "")),
			"tall_grass_path": tall_path,
			"tall_grass_key_color": str(tall_grass.get("key_color", "")) if tall_grass is Dictionary else ""
		}), "%s base (%s)" % [biome, str(def["base_path"])])
		for prop in def.get("props", []):
			checked += 1
			_audit_tile(cache.prop_texture({
				"prop_texture": _raw_texture(str(prop["path"]), prop.get("region", null)),
				"prop_path": str(prop["path"]),
				"prop_region": prop.get("region", null),
				"prop_key_color": str(prop.get("key_color", ""))
			}), "%s prop (%s)" % [biome, str(prop["path"])])
	return checked


# Mirrors the world generator's raw load; region cuts ride AtlasTextures.
func _raw_texture(path: String, region: Variant) -> Texture2D:
	var texture = load(path) as Texture2D
	if texture == null or not (region is Rect2):
		return texture
	var frame := AtlasTexture.new()
	frame.atlas = texture
	frame.region = region
	return frame


# A solid near-white/near-black border across all four edges is the
# signature of a sheet whose background keying failed. Legit art keeps
# partial borders (ice2's pale ice, bush_savanna1's dark outline), so only
# a near-total border of one extreme counts as a violation.
func _audit_tile(texture: Texture2D, label: String) -> void:
	if texture == null or texture.get_width() <= 0 or texture.get_height() <= 0:
		_failures.append("%s: empty texture" % label)
		return
	var image := texture.get_image()
	if image == null or image.is_empty():
		_failures.append("%s: image unreadable" % label)
		return
	var w := image.get_width()
	var h := image.get_height()
	var pixels: Array = []
	for x in range(w):
		pixels.append(image.get_pixel(x, 0))
		pixels.append(image.get_pixel(x, h - 1))
	for y in range(1, h - 1):
		pixels.append(image.get_pixel(0, y))
		pixels.append(image.get_pixel(w - 1, y))
	var white := 0
	var black := 0
	for color in pixels:
		if color.a < 0.5:
			continue
		if color.r >= NEAR_WHITE and color.g >= NEAR_WHITE and color.b >= NEAR_WHITE:
			white += 1
		elif color.r <= NEAR_BLACK and color.g <= NEAR_BLACK and color.b <= NEAR_BLACK:
			black += 1
	if float(white) >= SOLID_BORDER * pixels.size():
		_failures.append("%s: solid opaque near-white border survived keying (%d/%d px)" % [label, white, pixels.size()])
	elif float(black) >= SOLID_BORDER * pixels.size():
		_failures.append("%s: solid opaque near-black border survived keying (%d/%d px)" % [label, black, pixels.size()])


func _finish(event_name: String, payload: Dictionary) -> void:
	if _failures.is_empty():
		_runtime().emit_trace(event_name, "SmokeScenarios", payload)
	else:
		push_error("%s failed:\n%s" % [event_name, "\n".join(PackedStringArray(_failures))])


func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys


func _biome_defs() -> Dictionary:
	return _runtime()._world_gen.BiomeDefs.new().definitions()


func _catalog():
	return _runtime().catalog


func _runtime() -> Node:
	return _ctx["runtime"]
