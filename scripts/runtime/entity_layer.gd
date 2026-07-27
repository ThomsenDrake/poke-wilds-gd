extends Node2D

# Phase 6 overworld-mon RENDER layer (spec: docs/product-specs/overworld-pokemon.md — § Asset
# coverage / § Overworld shinies / § Determinism). A STATIC, self-wired child of Main composing
# roaming-mon / guardian / wild-egg sprites into the world's y-sort space — ZERO lines in main.gd
# (220/220) or world_view.gd (319/320): the world_view / CampMenu /root/GameRuntime convention.
# Logic position is owned by the step-driven overworld_mons_runtime; this node only presents it.
#
# WORLD_DRAW_ORDER EXTENSION (load-bearing). Every sprite reuses the feet-origin trick EXACTLY
# (world_view.gd:223-226): position = map_to_world(tile)+(0,16), offset = (0,-16) — the y-sort key
# (global Y) is the tile BOTTOM (the feet), the draw rect stays tile-aligned. _ready sets
# y_sort_enabled here so entity_sprite -> EntityLayer -> Main is fully y-sort-enabled (World joins
# via GroundLayer/PropLayer); ONE unsorted ancestor makes WorldDrawOrder.y_sort_key NAN and the
# audit_z_order entity scan goes red class-wide. EntityLayer sits AFTER Player in Main's child list,
# so the same-feet-Y tree-order tie draws the entity OVER the player (pinned; spike (c) proven).
# Sprites are z 0 (== player/props once player_avatar zeroes z=5); nest ring z=-1. BASELINE STABILITY
# (why 01-21 never shift): an empty y-sort Node2D at (0,0) renders nothing and moves no sibling's
# sort key — EntityLayer at Main child index 2 leaves the World(0)/Player(1) pair untouched, and
# sprites exist only while the runtime is active (opted-in), so every inert baseline is byte-identical.
#
# FAITHFUL NO-SHINY-VISUAL (:230): is_shiny is NEVER read; wild mon AND wild-egg sprites are
# identical shiny or not; the 579 overworld-shiny sheets never load; the pen-egg GOLD SPARKLE
# (world_view.gd:246-249) stays the sole Phase-5 divergence — wild eggs get NO sparkle. WILD EGGS
# render HERE as transient entities (re-used phione-egg art); pen eggs render on world_view's prop
# layer (persisted, sparkle) — distinct node tree + lifecycle, never conflated. ASSET COVERAGE
# (flagged, miss-002): tier 1 = the species' 96x16 six-frame sheet (catalog "overworld_path";
# 709/990); tier 2 = the source placeholder pokewilds/pokemon/overworld_not_found.png (96x16) for
# the 281 without, with a LOUD warn() once per species; tier 3 (scaled front sprite) REJECTED. The
# Alpha badge + nest ring are generated textures (no submodule art — DIVERGENCE #1).
#
# RUNTIME CONTRACT (build-runtime lane): reads live_entities_in(Rect2i) -> Array of dicts, each
# {"id": stable-across-roam (e.g. "mon_3,2"; needed for the lerp), "tile": Vector2i, "species_id":
# String, "render_kind": "mon"|"egg"|"guardian" (falls back to is_egg / the domain stationary
# class), "facing": Vector2i optional}. Holds NO RandomNumberGenerator, never reads the shared _rng
# — the determinism guarantee is untouched by construction.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd") # CLASS_* vocabulary only

const TILE_SIZE := 16
const HALF_WIDTH_TILES := 30 # mirror world_view's synced window (world_view.gd:22-23)
const HALF_HEIGHT_TILES := 20
const RuntimePath := "/root/GameRuntime"
const FRAME_SIZE := 16 # the 96x16 sheets are six 16x16 directional frames
const NOT_FOUND_PATH := "res://pokewilds/pokemon/overworld_not_found.png" # tier-2 faithful placeholder
const EGG_SHEET_PATH := "res://pokewilds/phione-egg.png" # re-used egg art (NO sparkle — faithful :230)
const LERP_SPEED := 192.0 # px/s: ~1 tile in 0.08s, so a settle() snaps mons onto logic tiles
const SNAP_EPSILON := 0.5 # px: resting sprites land EXACTLY on the feet target (byte-stable)
const KIND_MON := "mon"
const KIND_EGG := "egg"
const KIND_GUARDIAN := "guardian"
const FRAME_IDLE := {Vector2i.DOWN: 0, Vector2i.UP: 2, Vector2i.LEFT: 4} # right = side frame flipped

var _entity_nodes: Dictionary = {} # id -> {"sprite": Sprite2D, "tile": Vector2i, "kind": String}
var _nest_nodes: Dictionary = {} # nest cell (Vector2i) -> Sprite2D (the ground ring prop)
var _species_sheets: Dictionary = {} # species_id -> Texture2D (the 96x16 sheet; tier-2 included)
var _frame_cache: Dictionary = {} # "path#frame" -> AtlasTexture (one region per facing idle)
var _warned_missing: Dictionary = {} # species_id -> true (warn once per species, never spam)
var _egg_texture: Texture2D = null
var _nest_ring: Texture2D = null
var _alpha_badge: Texture2D = null
var _player: Node = null


func _ready() -> void:
	y_sort_enabled = true # join the shared sort space (see the WORLD_DRAW_ORDER note above)
	var parent := get_parent()
	if parent is CanvasItem: # defensive mirror of world_view._setup_canvas_order (:57-59)
		(parent as CanvasItem).y_sort_enabled = true
	_player = parent.get_node_or_null("Player") if parent != null else null


# Presentation only: reconcile the live set + chase logic tiles every frame (a same-tile removal never leaves a stale sprite; idempotent between steps).
func _process(delta: float) -> void:
	_sync_entities()
	_lerp_sprites(delta)


func _sync_entities() -> void:
	var entities := _live_entities()
	var active_ids: Dictionary = {}
	var active_nests: Dictionary = {}
	for entity in entities:
		var id := _entity_id(entity)
		active_ids[id] = true
		_ensure_entity_node(entity, id)
		# A nest ring renders iff the cell holds a guardian (guardians spawn only in nest cells); no 2nd query.
		if _entity_kind(entity) == KIND_GUARDIAN:
			var cell: Vector2i = OverworldMons.cell_for_tile(entity.get("tile", Vector2i.ZERO))
			active_nests[cell] = true
			_ensure_nest_node(cell)
	for id in _entity_nodes.keys():
		if not active_ids.has(id):
			(_entity_nodes[id]["sprite"] as Node).queue_free()
			_entity_nodes.erase(id)
	for cell in _nest_nodes.keys():
		if not active_nests.has(cell):
			(_nest_nodes[cell] as Node).queue_free()
			_nest_nodes.erase(cell)


func _ensure_entity_node(entity: Dictionary, id: String) -> void:
	var tile: Vector2i = entity.get("tile", Vector2i.ZERO)
	var kind := _entity_kind(entity)
	if kind == KIND_EGG:
		_ensure_sprite(id, tile, kind, _egg_frame(), false)
		return
	var facing: Vector2i = entity.get("facing", Vector2i.DOWN)
	var flip := facing == Vector2i.RIGHT
	var sheet := _species_sheet(str(entity.get("species_id", "")))
	var frame_index: int = FRAME_IDLE.get(Vector2i.LEFT if flip else facing, 0)
	var record := _ensure_sprite(id, tile, kind, _frame_texture(sheet, frame_index), flip)
	if kind == KIND_GUARDIAN:
		_attach_alpha_marker(record["sprite"])


# Create-or-update one sprite; the target tile updates every sync (the lerp chases it), offset set once.
func _ensure_sprite(id: String, tile: Vector2i, kind: String, texture: Texture2D, flip_h: bool) -> Dictionary:
	var record: Dictionary = _entity_nodes.get(id, {})
	var sprite: Sprite2D = record.get("sprite", null)
	if sprite == null:
		sprite = Sprite2D.new()
		sprite.centered = false
		sprite.name = "Entity_%s" % id
		sprite.offset = Vector2(0, -TILE_SIZE) # feet-origin trick (world_view.gd:223-226)
		sprite.position = _feet_position(tile) # spawn at rest (no lerp-jump on materialization)
		add_child(sprite)
		record = {"sprite": sprite, "tile": tile, "kind": kind}
		_entity_nodes[id] = record
	record["tile"] = tile
	if sprite.texture != texture:
		sprite.texture = texture
	sprite.flip_h = flip_h
	return record


func _lerp_sprites(delta: float) -> void:
	var step := LERP_SPEED * delta
	for id in _entity_nodes:
		var record: Dictionary = _entity_nodes[id]
		var sprite: Sprite2D = record["sprite"]
		var target := _feet_position(record["tile"])
		# Snap on arrival: resting position == the feet target exactly, so post-settle() captures are byte-stable.
		if sprite.position.distance_to(target) <= SNAP_EPSILON:
			sprite.position = target
		else:
			sprite.position = sprite.position.move_toward(target, step)


func _ensure_nest_node(cell: Vector2i) -> void: # generated ring; DIVERGENCE #1 (no submodule art)
	if _nest_nodes.has(cell):
		return
	var sprite := Sprite2D.new()
	sprite.name = "Nest_%d_%d" % [cell.x, cell.y]
	sprite.centered = false
	sprite.texture = _nest_ring_texture()
	sprite.z_index = -1 # a ground feature: sorts under every z-0 entity (pen ground-eggs are z 0)
	sprite.position = map_to_world(OverworldMons.cell_center(cell))
	add_child(sprite)
	_nest_nodes[cell] = sprite


# A red diamond badge over the guardian's head — NOT a palette swap (a tint would read as a shiny, :230).
func _attach_alpha_marker(sprite: Sprite2D) -> void:
	if sprite.get_node_or_null("AlphaMarker") != null:
		return
	var marker := Sprite2D.new()
	marker.name = "AlphaMarker"
	marker.centered = false
	marker.texture = _alpha_badge_texture()
	marker.position = Vector2(4, -22) # above the mon's head (parent origin is the feet)
	sprite.add_child(marker)


func _species_sheet(species_id: String) -> Texture2D:
	if _species_sheets.has(species_id):
		return _species_sheets[species_id]
	var path := ""
	var catalog: Object = _runtime_field("catalog")
	if catalog != null and catalog.has_method("get_species"):
		path = str(catalog.call("get_species", species_id).get("overworld_path", ""))
	var sheet: Texture2D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		var loaded := load(path)
		sheet = loaded if loaded is Texture2D else null
	if sheet == null and ResourceLoader.exists(NOT_FOUND_PATH): # tier 2 (loud, once per species)
		var placeholder := load(NOT_FOUND_PATH)
		sheet = placeholder if placeholder is Texture2D else null
		if sheet != null and not _warned_missing.has(species_id):
			_warned_missing[species_id] = true
			_warn("Overworld sprite missing for %s; using the placeholder." % species_id, species_id)
	_species_sheets[species_id] = sheet
	return sheet


func _frame_texture(sheet: Texture2D, frame_index: int) -> Texture2D:
	if sheet == null:
		return null
	var key := "%s#%d" % [sheet.resource_path, frame_index]
	if _frame_cache.has(key):
		return _frame_cache[key]
	var frame := AtlasTexture.new()
	frame.atlas = sheet
	frame.region = Rect2(frame_index * FRAME_SIZE, 0, FRAME_SIZE, FRAME_SIZE)
	_frame_cache[key] = frame
	return frame


func _egg_frame() -> Texture2D:
	if _egg_texture == null and ResourceLoader.exists(EGG_SHEET_PATH):
		var sheet := load(EGG_SHEET_PATH)
		if sheet is Texture2D:
			_egg_texture = AtlasTexture.new()
			_egg_texture.atlas = sheet
			_egg_texture.region = Rect2(0, 0, FRAME_SIZE, FRAME_SIZE) # NO sparkle child (faithful :230)
	return _egg_texture


func _nest_ring_texture() -> Texture2D:
	if _nest_ring != null:
		return _nest_ring
	var image := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	# A woven ground ring (generated; DIVERGENCE #1), hollow-centered, distinct from the pen egg.
	var light := Color(0.55, 0.40, 0.22)
	var dark := Color(0.40, 0.28, 0.15)
	for x in range(TILE_SIZE):
		for y in range(TILE_SIZE):
			var dx := float(x) - 7.5
			var dy := float(y) - 7.5
			var dist := sqrt(dx * dx + dy * dy)
			if dist <= 7.0 and dist >= 4.0:
				image.set_pixel(x, y, light if (x + y) % 2 == 0 else dark)
	_nest_ring = ImageTexture.create_from_image(image)
	return _nest_ring


func _alpha_badge_texture() -> Texture2D:
	if _alpha_badge != null:
		return _alpha_badge
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for x in range(8):
		for y in range(8):
			var diamond := absi(x - 3) + absi(y - 3)
			if diamond <= 2:
				image.set_pixel(x, y, Color(0.86, 0.16, 0.16))
			elif diamond == 3:
				image.set_pixel(x, y, Color.WHITE) # 1px outline so the badge reads on any mon
	_alpha_badge = ImageTexture.create_from_image(image)
	return _alpha_badge


# The live entity sprite whose LOGIC tile is `tile` (null when none; a mon/guardian is preferred
# over an egg sharing the tile). The world_spatial_audit entity lane reads this (the
# world_view.get_prop_sprite:138 precedent) to prove the feet-origin z-order contract — an
# off-convention entity fails red there exactly.
func get_entity_sprite(tile: Vector2i) -> Sprite2D:
	var fallback: Sprite2D = null
	for id in _entity_nodes:
		var record: Dictionary = _entity_nodes[id]
		if record["tile"] != tile:
			continue
		if record["kind"] != KIND_EGG:
			return record["sprite"]
		fallback = record["sprite"]
	return fallback


func map_to_world(map_pos: Vector2i) -> Vector2:
	return Vector2(map_pos.x * TILE_SIZE, map_pos.y * TILE_SIZE)


func _feet_position(tile: Vector2i) -> Vector2:
	return map_to_world(tile) + Vector2(0, TILE_SIZE)


func _entity_id(entity: Dictionary) -> String:
	var id := str(entity.get("id", ""))
	if not id.is_empty():
		return id
	var tile: Vector2i = entity.get("tile", Vector2i.ZERO) # degraded: runtime should supply a stable id
	return "%s_%d_%d" % [_entity_kind(entity), tile.x, tile.y]


func _entity_kind(entity: Dictionary) -> String:
	if bool(entity.get("is_egg", false)):
		return KIND_EGG
	var kind := str(entity.get("render_kind", ""))
	if kind == KIND_EGG or kind == KIND_MON or kind == KIND_GUARDIAN:
		return kind
	if str(entity.get("entity_class", "")) == OverworldMons.CLASS_STATIONARY:
		return KIND_GUARDIAN
	return KIND_MON


func _live_entities() -> Array:
	var mons: Object = _runtime_field("overworld_mons_runtime")
	if mons == null or not mons.has_method("live_entities_in"):
		return [] # inert / not wired yet => render nothing (the baseline-protection guarantee)
	var center := _player_tile()
	var rect := Rect2i(center.x - HALF_WIDTH_TILES - 1, center.y - HALF_HEIGHT_TILES - 1,
		(HALF_WIDTH_TILES + 1) * 2 + 1, (HALF_HEIGHT_TILES + 1) * 2 + 1)
	var result: Variant = mons.call("live_entities_in", rect)
	return result if result is Array else []


func _player_tile() -> Vector2i:
	return _player.tile_position if _player != null and "tile_position" in _player else Vector2i.ZERO


func _runtime_field(field: String) -> Object: # Object not Node: sub-runtimes + catalog are RefCounted
	var runtime := get_node_or_null(RuntimePath)
	var value: Variant = runtime.get(field) if runtime != null and field in runtime else null
	return value if value is Object else null


func _warn(message: String, species_id: String) -> void:
	var runtime := get_node_or_null(RuntimePath)
	if runtime != null and runtime.has_method("warn"):
		runtime.warn("EntityLayer", message, {"species_id": species_id})
	else:
		push_warning(message)
