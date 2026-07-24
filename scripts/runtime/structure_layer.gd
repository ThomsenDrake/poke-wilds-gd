extends Node2D

# Build-mode layer (spec: docs/product-specs/building-and-placement.md). It
# COMPOSES world_view.gd and never extends it: placed structures render through
# world_view's existing prop pipeline (the runtime's generator applies
# placements at the get_tile_logic boundary), so occupancy agrees across
# logic/render/collision by construction. This layer only draws the transient
# GHOST preview, runs the build-mode input loop (movement keys cycle the
# selection, action_a/Z places, action_b/X exits — the input_router action set;
# the original's C/V cycle maps to our movement keys), and answers occupancy
# queries. Main parents it as a y-sort-enabled sibling of World/Player so the
# ghost joins the existing y-sort chain (world_view._setup_canvas_order) and
# sorts against the player's feet like every prop.

const Structures := preload("res://scripts/domain/structures.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")

const TILE_SIZE := 16
const DEFAULT_STRUCTURE := "wall"
const HINT_SECONDS := 1.6
const GHOST_VALID := Color(1.0, 1.0, 1.0, 0.65)
const GHOST_INVALID := Color(1.0, 0.0, 1.0, 0.65)
# Lit light-source glow (Phase 2; spec: camping-crafting-survival.md) — the
# DOCUMENTED FALLBACK for light_layer's world_view composition: one static
# generated gradient per lit campfire/torch in the visible window, night-only,
# NO per-frame animation — byte-stable baselines.
const GLOW_SIZE := 48
const GLOW_COLOR := Color(1.0, 0.82, 0.5, 0.5)

# Emitted when build mode ends (cancel or a successful placement); Main's field
# router restores player input and saves.
signal build_finished()

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _show_hint: Callable = Callable()
var _texture_cache = TileTextureCache.new()
var _ghost: Sprite2D = null
var _active := false
var _selected_id := DEFAULT_STRUCTURE
var _target_tile := Vector2i.ZERO
var _mon_constraint: Dictionary = {}
var _glow_nodes: Dictionary = {}
var _glow_texture: Texture2D = null
var _last_glow_minutes := -1


func _ready() -> void:
	y_sort_enabled = true
	_ghost = Sprite2D.new()
	_ghost.centered = false
	_ghost.z_index = 0
	_ghost.hide()
	add_child(_ghost)


func setup(runtime: Node, world_view: Node, player_avatar: Node, show_hint: Callable) -> void:
	_runtime = runtime
	_world = world_view
	_player = player_avatar
	_show_hint = show_hint
	_glow_texture = _make_glow_texture()
	if runtime != null and not runtime.world_overridden.is_connected(_on_world_overridden):
		runtime.world_overridden.connect(_on_world_overridden)
	if player_avatar != null and player_avatar.has_signal("tile_changed") and not player_avatar.tile_changed.is_connected(_on_player_moved):
		player_avatar.tile_changed.connect(_on_player_moved)


func is_active() -> bool:
	return _active


# Occupancy query: a bare walkable tile the party can afford. Drives the ghost
# tint; the placement itself is gated again inside build_runtime.try_place.
func can_place(tile: Vector2i, structure_id: String) -> bool:
	if _runtime == null or _world == null or not Structures.is_valid(structure_id):
		return false
	var logic: Dictionary = _world.get_tile_logic(tile)
	return Structures.can_place_on(logic) and _runtime.build_runtime.can_afford(structure_id, str(logic.get("biome", "")))


# True when the tile already carries a placed structure (placement map view).
func is_occupied(tile: Vector2i) -> bool:
	if _world == null:
		return false
	return str(_world.get_tile_logic(tile).get("override_kind", "")) == "placed"


# Enters build mode targeting one tile (Main passes the faced tile). The target
# stays fixed while the mode is open — movement keys cycle the selection, they
# never move the player (Main disables avatar input for the mode's lifetime).
func start_build(target_tile: Vector2i, mon_constraint: Dictionary = {}) -> void:
	if _runtime == null or _world == null or _active:
		return
	_target_tile = target_tile
	_mon_constraint = mon_constraint
	_selected_id = DEFAULT_STRUCTURE
	_active = true
	_runtime.build_runtime.enter_build_mode(target_tile, _selected_id)
	_refresh_ghost()
	_emit_cost_hint()


# Exits build mode (cancel or post-placement); the ghost hides and Main's
# router restores movement + saves.
func stop_build() -> void:
	if not _active:
		return
	_active = false
	_mon_constraint = {}
	_ghost.hide()
	build_finished.emit()


func _process(_delta: float) -> void:
	_glow_time_check()
	if not _active:
		return
	# Input-driven only (no wall-clock gates) so scenarios can drive the mode.
	if Input.is_action_just_pressed("action_b"):
		stop_build()
		return
	if Input.is_action_just_pressed("action_a"):
		_confirm()
		return
	var cycle := _cycle_direction()
	if cycle != 0:
		_select(posmod(_selected_index() + cycle, Structures.IDS.size()))


# Public so scenarios/tests can drive the selection without synthesized input.
func select_structure(structure_id: String) -> void:
	if _active and Structures.is_valid(structure_id):
		_selected_id = structure_id
		_refresh_ghost()
		_emit_cost_hint()


func _confirm() -> void:
	var result: Dictionary = _runtime.build_runtime.try_place(_target_tile, _selected_id, _mon_constraint)
	if bool(result.get("ok", false)):
		stop_build()
		return
	# Refused: show the reason and keep the mode open; the ghost re-tints.
	if _show_hint.is_valid():
		_show_hint.call(str(result.get("message", "")), HINT_SECONDS)
	_refresh_ghost()


func _cycle_direction() -> int:
	if Input.is_action_just_pressed("move_left") or Input.is_action_just_pressed("move_up"):
		return -1
	if Input.is_action_just_pressed("move_right") or Input.is_action_just_pressed("move_down"):
		return 1
	return 0


func _selected_index() -> int:
	return maxi(Structures.IDS.find(_selected_id), 0)


func _select(index: int) -> void:
	_selected_id = str(Structures.IDS[index])
	_refresh_ghost()
	_emit_cost_hint()


func _refresh_ghost() -> void:
	if not _active or _world == null or _ghost == null:
		return
	var biome := str(_world.get_tile_logic(_target_tile).get("biome", ""))
	var gate := _ghost_is_gate()
	var texture := _ghost_texture(Structures.sprite_path_for(_selected_id, biome, gate), Structures.sprite_region_for(_selected_id, biome, gate))
	_ghost.texture = texture
	if texture != null:
		# world_view's exact prop origin: tile bottom, offset up by the sprite
		# height, so the ghost sorts against the player's feet like a placed prop.
		_ghost.position = _world.map_to_world(_target_tile) + Vector2(0, TILE_SIZE)
		_ghost.offset = Vector2(0, -texture.get_height())
	_ghost.modulate = GHOST_VALID if can_place(_target_tile, _selected_id) else GHOST_INVALID
	_ghost.show()


# The same keyed/upscaled pipeline the placed structure renders through, so the
# ghost previews exactly what world_view will draw (never a raw opaque PNG).
func _ghost_texture(path: String, region: Variant) -> Texture2D:
	if path.is_empty():
		return null
	var raw: Texture2D = load(path)
	if raw == null:
		return null
	return _texture_cache.prop_texture({"prop_texture": raw, "prop_path": path, "prop_region": region, "prop_key_color": ""})


# A door beside a fence renders as a gate (structures.door_is_gate); the ghost
# mirrors the same neighbor check the placement stamp will use.
func _ghost_is_gate() -> bool:
	if _selected_id != "door" or _world == null:
		return false
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if str(_world.get_tile_logic(_target_tile + direction).get("structure_id", "")) == "fence":
			return true
	return false


# HUD hint: have/need per material, flagged when unaffordable.
func _emit_cost_hint() -> void:
	if not _active or _world == null or not _show_hint.is_valid():
		return
	var biome := str(_world.get_tile_logic(_target_tile).get("biome", ""))
	var cost: Dictionary = Structures.cost_for(_selected_id, biome)
	var parts: Array = []
	var affordable := true
	for item_id in cost.keys():
		var have := int(_runtime.get_item_count(str(item_id)))
		var need := int(cost[item_id])
		if have < need:
			affordable = false
		parts.append("%d/%d %s" % [have, need, str(item_id).replace("_", " ")])
	var hint := "%s: %s" % [_selected_id.replace("_", " ").capitalize(), ", ".join(parts)]
	_show_hint.call(hint if affordable else hint + " (missing materials)", HINT_SECONDS)


# A placed/mutated tile is no longer placeable; re-tint when it is the target.
# Overrides also add/remove/extinguish lights, so glows re-resolve here too.
func _on_world_overridden(tile: Vector2i) -> void:
	if _active and tile == _target_tile:
		_refresh_ghost()
	_refresh_light_glows()


# --- Lit light-source glow (documented light_layer fallback) --------------------

# Re-resolve glows when the clock minute changes (one step can flip night<->day).
func _glow_time_check() -> void:
	var minutes := int(_runtime.get_time_of_day_minutes()) if _runtime != null else -1
	if minutes != _last_glow_minutes:
		_last_glow_minutes = minutes
		_refresh_light_glows()


func _on_player_moved(_tile_position: Vector2i) -> void:
	_refresh_light_glows() # the visible window moved with the player


# One static additive glow per lit light source in the synced window, night
# only; defers entirely when the dedicated light layer is composed (the spec's
# primary compositor) so the glow is never drawn twice.
func _refresh_light_glows() -> void:
	if _runtime == null or _world == null or _player == null:
		return
	var night := not _light_layer_present() and DayPhase.is_night(int(_runtime.get_time_of_day_minutes()))
	var lit_tiles: Dictionary = _lit_light_tiles() if night else {}
	_sync_glow_nodes(lit_tiles)


func _sync_glow_nodes(lit_tiles: Dictionary) -> void:
	for tile in _glow_nodes.keys():
		if not lit_tiles.has(tile):
			(_glow_nodes[tile] as Sprite2D).queue_free()
			_glow_nodes.erase(tile)
	for tile in lit_tiles.keys():
		if _glow_nodes.has(tile):
			continue
		var glow := Sprite2D.new()
		glow.texture = _glow_texture
		glow.centered = true
		glow.z_index = 1 # above ground + props; additive, so player overlap reads as light
		var blend := CanvasItemMaterial.new()
		blend.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		glow.material = blend
		glow.position = _world.map_to_world(tile) + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		add_child(glow)
		_glow_nodes[tile] = glow


# Lit light sources inside the synced window, read off the public
# placed_structures accessor + the structures.gd classification, so this layer
# and the night system never disagree about what emits light.
func _lit_light_tiles() -> Dictionary:
	var merged: Dictionary = _runtime.placed_structures()
	var center: Vector2i = _player.tile_position
	var half_w := int(_world.half_width_tiles)
	var half_h := int(_world.half_height_tiles)
	var lit: Dictionary = {}
	for key in merged.keys():
		var entry: Variant = merged[key]
		if not (entry is Dictionary):
			continue
		if not Structures.is_light_source(str((entry as Dictionary).get("structure_id", ""))):
			continue
		if not Structures.placement_is_lit(entry as Dictionary):
			continue
		var parts := str(key).split(",")
		if parts.size() != 2:
			continue
		var tile := Vector2i(int(parts[0]), int(parts[1]))
		if absi(tile.x - center.x) <= half_w and absi(tile.y - center.y) <= half_h:
			lit[tile] = true
	return lit


# True when the dedicated light layer has been composed (the spec's primary).
func _light_layer_present() -> bool:
	return (_runtime != null and _runtime.get("light_layer") != null) or (_world != null and _world.get_node_or_null("LightLayer") != null)


# Static warm radial gradient (bright center -> transparent rim), generated
# once — no per-frame animation, so the sweep baselines are byte-stable.
func _make_glow_texture() -> Texture2D:
	var image := Image.create(GLOW_SIZE, GLOW_SIZE, false, Image.FORMAT_RGBA8)
	var radius := GLOW_SIZE / 2.0
	var center := Vector2(radius, radius)
	for y in range(GLOW_SIZE):
		for x in range(GLOW_SIZE):
			var strength := clampf(1.0 - Vector2(x + 0.5, y + 0.5).distance_to(center) / radius, 0.0, 1.0)
			image.set_pixel(x, y, Color(GLOW_COLOR.r, GLOW_COLOR.g, GLOW_COLOR.b, GLOW_COLOR.a * strength * strength))
	return ImageTexture.create_from_image(image)
