extends RefCounted

# Camp/storage placed-object Z routing extracted from field_action_router.gd at
# the 220 app wall (the field_move_actions.gd / overworld_entity_actions.gd
# extraction precedent — one delegation per precedence tier). Faced placed
# objects: campfire -> CampMenu (demolition STAYS in the menu so the witness
# escape is never shadowed), bed -> rest, storage_box -> StorageScreen, fence ->
# the entity actions' Phase 5 pen action. The campfire lit toggle mutates the
# live placement entry ("lit": false when extinguished, ABSENT when lit — the
# map is canonical). This module owns the FULL camp/storage overlay lifecycle:
# the open side below, overlay_open() (the router's context poll early-returns
# on it — an open overlay owns Z/X while visible), and the screens' `closed`
# signal wirings + handlers (re-enable the avatar + save).

const CAMPFIRE_ID := "campfire"
const BED_ID := "bed"
const BOX_ID := "storage_box"

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _entity_actions: RefCounted = null
var _camp_menu: Node = null
var _storage_screen: Node = null
var _show_message: Callable = Callable()


func setup(runtime: Node, world: Node, player: Node, entity_actions: RefCounted, show_message: Callable, camp_menu: Node = null, storage_screen: Node = null) -> void:
	_runtime = runtime
	_world = world
	_player = player
	_entity_actions = entity_actions
	_show_message = show_message
	_camp_menu = camp_menu
	_storage_screen = storage_screen
	if _camp_menu != null and _camp_menu.has_signal("closed") and not _camp_menu.closed.is_connected(_on_camp_menu_closed):
		_camp_menu.closed.connect(_on_camp_menu_closed)
	if _storage_screen != null and _storage_screen.has_signal("closed") and not _storage_screen.closed.is_connected(_on_storage_screen_closed):
		_storage_screen.closed.connect(_on_storage_screen_closed)


# Any overlay these routes open owns Z/X while visible (main.gd's poll carries the same check).
func overlay_open() -> bool:
	return (_camp_menu != null and _camp_menu.visible) or (_storage_screen != null and _storage_screen.visible)


func _on_camp_menu_closed() -> void:
	_player.input_enabled = true
	if _runtime != null: _runtime.save_game()


# The closed-driven save captures every box mutation; the closing press's polls die on input_router's latch.
func _on_storage_screen_closed() -> void:
	_player.input_enabled = true
	if _runtime != null: _runtime.save_game()


# Camp-object precedence for the faced Z; false (fall through) when no placed camp object.
func route_camp_object(tile: Vector2i) -> bool:
	var logic: Dictionary = _world.get_tile_logic(tile)
	if str(logic.get("override_kind", "")) != "placed":
		return false
	match str(logic.get("structure_id", "")):
		CAMPFIRE_ID:
			return _open_camp_menu(tile)
		BED_ID:
			return _rest_at_bed()
		BOX_ID:
			return _open_storage_screen(tile)
		"fence":
			return _entity_actions.pen_action(tile)
	return false


func _open_camp_menu(tile: Vector2i) -> bool:
	if _camp_menu == null or not _camp_menu.has_method("open_menu"):
		return false
	_player.input_enabled = false
	_camp_menu.open_menu(tile, CAMPFIRE_ID, Callable(self, "_toggle_campfire").bind(tile))
	return true


# Mirrors _open_camp_menu: the app layer owns the avatar; the screen's `closed` signal owns the re-enable + save.
func _open_storage_screen(tile: Vector2i) -> bool:
	if _storage_screen == null or not _storage_screen.has_method("open_screen"):
		return false
	_player.input_enabled = false
	_storage_screen.open_screen(tile)
	return true


# Bed rest: camping_runtime.rest("bed") owns heal + time + campsite anchor; the router surfaces the confirmation.
func _rest_at_bed() -> bool:
	var camping: Variant = _runtime.get("camping_runtime") if _runtime != null else null
	if camping == null or not camping.has_method("rest"):
		return false
	var result: Variant = camping.call("rest", BED_ID)
	var response: Dictionary = result if result is Dictionary else {}
	var text := str(response.get("message", ""))
	_show_message.call(text if not text.is_empty() else "You rested for a while.", 2.2)
	_world.set_time_of_day(_runtime.get_time_of_day_minutes())
	_runtime.save_game()
	return true


# The camp menu's Extinguish/Light entry: prefers a camping_runtime toggle, else flips the
# placement's additive "lit" field (documented reach into runtime._world_gen; absent = lit).
func _toggle_campfire(tile: Vector2i) -> Dictionary:
	var camping: Variant = _runtime.get("camping_runtime") if _runtime != null else null
	if camping != null and camping.has_method("toggle_campfire"):
		var delegated: Variant = camping.call("toggle_campfire", tile)
		return delegated if delegated is Dictionary else {}
	if _runtime == null:
		return {"ok": false, "lit": true, "message": ""}
	var world_gen: Variant = _runtime.get("_world_gen")
	var placements: Variant = (world_gen as Object).get("_placements") if world_gen != null else null
	if not (placements is Dictionary) or not (placements as Dictionary).has(tile):
		return {"ok": false, "lit": true, "message": "There is no campfire there."}
	var entry: Dictionary = (placements as Dictionary)[tile]
	if str(entry.get("structure_id", "")) != CAMPFIRE_ID:
		return {"ok": false, "lit": true, "message": ""}
	var now_lit: bool = entry.get("lit", true) == false # flip: extinguished -> lit
	if now_lit:
		entry.erase("lit")
	else:
		entry["lit"] = false
	_runtime.emit_trace("campfire_lit", "App.FieldActionRouter", {"tile": [tile.x, tile.y], "lit": now_lit})
	_runtime.emit_signal("world_overridden", tile) # the light layer + glow refresh read the map
	_runtime.save_game()
	return {"ok": true, "lit": now_lit, "message": "The fire catches again." if now_lit else "The fire dies down. Its light is gone."}
