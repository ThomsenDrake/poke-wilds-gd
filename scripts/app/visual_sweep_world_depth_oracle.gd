extends RefCounted

# Phase 7 R4 — the REGIONAL PIXEL ORACLE for the world_depth satellite (extracted at the
# app-220 wall; check_architecture.py SCRIPT_LIMITS). visual_region_diff.py ALREADY reads a
# sidecar's expected_regions.ink + canary_rect as RED-tier regions (tolerance ~0 for the canary),
# but the world_depth sidecars shipped with EMPTY regions: the only pixel gate on the landmark
# shots was the 0.5% GLOBAL drift, so a statue sprite failing to render (~0.3%) or a beacon
# way-stone dropping stayed GREEN. This oracle fills the gap: it projects the in-scenario TILES
# (already derived by the sweep off the frozen landmark/beacon/legendary seams) to SCREEN RECTS
# off the camera tile + the canonical window, and merges expected_regions.ink + canary_rect into
# the capture metadata so the committed sidecar carries them. NO scene reach: a pure tile->screen
# map (world_view TILE_SIZE 16 * Camera2D zoom 3 = 48 device px/tile; the camera parents the player
# and centers the canonical window on player.position, verified against 32_mansion.png). The
# regions are byte-stable because every gated sprite uses the feet-origin trick at an integer tile
# (entity_layer/world_view), so tolerance-0 self-equality holds on a deterministic re-capture.

const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")

const TILE_PX := 48 # TILE_SIZE(16) * Camera2D zoom(3); device pixels per tile at the canonical window
const SHOT_RUINS := "31_ruins_interior.png"
const SHOT_MANSION := "32_mansion.png"
const SHOT_BEACON := "33_beacon.png"
const SHOT_TOWER := "34_heart_tower.png"
const SHOT_CHAINED := "35_chained_world.png"
const SHOT_GUARDIAN := "36_legendary_guardian.png"

# Ruins inner chamber: the player stands at local (7,5); the two glowing statues that frame the
# chamber (landmarks.gd _R_SPECIAL) sit one row ABOVE at (6,4)/(8,4). Ink = the statues render;
# the canary spans the statue pair (strict — they are solid prop sprites at integer tiles).
const RUINS_INK_LOCALS := [Vector2i(6, 4), Vector2i(8, 4)]
const RUINS_CANARY_LOCALS := [Vector2i(6, 4), Vector2i(7, 4), Vector2i(8, 4)]
# Mansion solved room: the player at local (7,6); the statue row (MANSION_STATUE_LOCALS) is one row
# BELOW at y7, the open door pair (MANSION_DOOR_LOCALS) one row ABOVE at y5. Ink = statues + the two
# open doors (the seam-crafted solved overlay); canary = the statue row (the shot's whole purpose).
const MANSION_INK_LOCALS := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7), Vector2i(7, 5), Vector2i(4, 5)]
const MANSION_CANARY_LOCALS := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7)]
# Heart Tower base chamber: the player at interior local (4,4); the centered decor (4,2) + three wall
# mid-points (top + left + right; the bottom mid (4,7) is the ENTERABLE entry tile — walkable, NO
# prop, so it is NOT a solid sprite and is excluded) render the dedicated heart_tower tileset. Ink
# only (no canary — the decor sprite's alpha edge is not proven strict; the ink overlap gate is the
# proportionate red tier here). Every tile here is asserted solid+non-walkable by the shot.
const TOWER_PLAYER_LOCAL := Vector2i(4, 4)
const TOWER_INK_LOCALS := [Vector2i(4, 2), Vector2i(4, 0), Vector2i(0, 4), Vector2i(8, 4)]


# Pure tile->screen rect: top-left of `tile` in device pixels when the camera centers the canonical
# window on `player_tile` (the teleport snaps the player, so the camera is exact at capture).
static func tile_screen_rect(tile: Vector2i, player_tile: Vector2i) -> Array:
	var half := VisualSweepBaselines.CANONICAL_WINDOW_SIZE / 2
	var origin := half + (tile - player_tile) * TILE_PX
	return [origin.x, origin.y, TILE_PX, TILE_PX]


static func _rects(locals: Array, footprint_pos: Vector2i, player_tile: Vector2i) -> Array:
	var rects: Array = []
	for local in locals:
		rects.append(tile_screen_rect(footprint_pos + local, player_tile))
	return rects


static func _bounding(locals: Array, footprint_pos: Vector2i, player_tile: Vector2i) -> Array:
	var rects := _rects(locals, footprint_pos, player_tile)
	var x0 := int(rects[0][0])
	var y0 := int(rects[0][1])
	var x1 := x0 + TILE_PX
	var y1 := y0 + TILE_PX
	for rect in rects:
		x0 = mini(x0, int(rect[0])); y0 = mini(y0, int(rect[1]))
		x1 = maxi(x1, int(rect[0]) + TILE_PX); y1 = maxi(y1, int(rect[1]) + TILE_PX)
	return [x0, y0, x1 - x0, y1 - y0]


# Static-region lookup for the origin-world landmark/beacon/tower shots (keyed by filename). The
# footprint/player tiles come from the sweep's _crafted (recorded at capture). Returns {} when the
# shot carries no static region (the chained/guardian shots build theirs dynamically instead).
static func static_region(shot: String, crafted: Dictionary, player_tile: Vector2i) -> Dictionary:
	match shot:
		SHOT_RUINS:
			var fp := _vec(crafted.get("ruins_footprint", []))
			return {"ink": _rects(RUINS_INK_LOCALS, fp, player_tile), "canary": _bounding(RUINS_CANARY_LOCALS, fp, player_tile)}
		SHOT_MANSION:
			var fp := _vec(crafted.get("mansion_footprint", []))
			return {"ink": _rects(MANSION_INK_LOCALS, fp, player_tile), "canary": _bounding(MANSION_CANARY_LOCALS, fp, player_tile)}
		SHOT_BEACON:
			var anchor := _vec(crafted.get("beacon_anchor", []))
			var tiles := crafted.get("beacon_tiles", []) as Array
			var ink: Array = []
			for tile in tiles:
				ink.append(tile_screen_rect(Vector2i(int(tile[0]), int(tile[1])), anchor))
			return {"ink": ink, "canary": []} # selector overlay geometry is not pinned -> ink-only (no false-strict canary)
		SHOT_TOWER:
			var fp := _vec(crafted.get("tower_footprint", []))
			return {"ink": _rects(TOWER_INK_LOCALS, fp, player_tile), "canary": []}
	return {}


# Dynamic region (chained-world landmark + legendary guardian): the sweep hands the already-derived
# WORLD tiles + the camera tile; we project them. canary_tile empty -> no canary. Rects OFF the
# canonical window are dropped: change clusters clip to the image, so an off-window rect can never
# catch one — a vacuous region claiming coverage (miss-002); the padded entity scan can emit them.
static func dynamic_region(world_ink_tiles: Array, canary_world_tile: Vector2i, player_tile: Vector2i, has_canary: bool) -> Dictionary:
	var ink: Array = []
	for tile in world_ink_tiles:
		var rect := tile_screen_rect(tile, player_tile)
		if _on_window(rect):
			ink.append(rect)
	var canary: Array = []
	if has_canary and canary_world_tile != Vector2i.MAX:
		var rect := tile_screen_rect(canary_world_tile, player_tile)
		if _on_window(rect):
			canary = rect
	return {"ink": ink, "canary": canary}


static func _on_window(rect: Array) -> bool:
	var window := VisualSweepBaselines.CANONICAL_WINDOW_SIZE
	return int(rect[0]) < window.x and int(rect[1]) < window.y and int(rect[0]) + TILE_PX > 0 and int(rect[1]) + TILE_PX > 0


# Merge the shot's regions into the capture metadata (RenderIntrospection.collect left them empty
# for the overworld shot kind). A blank region set is a no-op so an unwired shot never reds.
static func merge_into(metadata: Dictionary, region: Dictionary) -> void:
	var ink: Array = region.get("ink", []) as Array
	var canary: Array = region.get("canary", []) as Array
	if ink.is_empty() and canary.is_empty():
		return
	var expected: Dictionary = metadata.get("expected_regions", {}) as Dictionary
	if not expected.has("forbidden"):
		expected["forbidden"] = []
	if not expected.has("strings"):
		expected["strings"] = []
	expected["ink"] = ink
	metadata["expected_regions"] = expected
	if not canary.is_empty():
		metadata["canary_rect"] = canary


static func _vec(coord: Variant) -> Vector2i:
	var array := coord as Array
	if array.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(array[0]), int(array[1]))
