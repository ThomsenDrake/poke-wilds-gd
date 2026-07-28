extends RefCounted

# Readback-image palette scanning for the semantic sidecar (extracted from
# render_introspection.gd for the app line budget). SnapshotCapture.capture()
# converts the collector's palette_regions spec into the sidecar "palettes" by
# scanning the just-read pixels here: distinct "#rrggbb" colors inside each rect,
# sorted, alpha dropped (Image.get_used_colors() absent in Godot 4.6.1 — manual
# scan; the caller caps at canary + hud).

static func palette_colors(image: Image, rect: Rect2i) -> Array:
	if image == null or image.is_empty():
		return []
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return []
	var region := image.get_region(clipped)
	region.convert(Image.FORMAT_RGBA8)
	var data := region.get_data()
	var seen := {}
	for offset in range(0, data.size(), 4):
		seen["#%02x%02x%02x" % [data[offset], data[offset + 1], data[offset + 2]]] = true
	var colors: Array = seen.keys()
	colors.sort()
	return colors

# Sidecar "palettes": canary colors plus the sorted union of hud rect colors.
static func palettes_from_image(image: Image, regions: Dictionary) -> Dictionary:
	var hud_seen := {}
	for rect in regions.get("hud", []):
		for color in palette_colors(image, _as_recti(rect)):
			hud_seen[color] = true
	var hud: Array = hud_seen.keys()
	hud.sort()
	return {"canary": palette_colors(image, _as_recti(regions.get("canary", []))), "hud": hud}

static func _as_recti(int_rect: Array) -> Rect2i:
	return Rect2i() if int_rect.size() < 4 else \
		Rect2i(int(int_rect[0]), int(int_rect[1]), int(int_rect[2]), int(int_rect[3]))
