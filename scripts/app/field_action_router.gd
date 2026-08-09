extends RefCounted

# App-layer field-action routing extracted from main.gd (scene-script line budget).
# Overworld context Z precedence: Phase 6 overworld ENTITIES (overworld_entity_actions:
# mon -> dialogue recruit, wild egg -> TAKE); then LANDMARK puzzle arms (Phase 7 landmark_actions: mansion statues/key/journals/loot + ruins decor); then placed camp objects (campfire ->
# CampMenu — demolition STAYS in the menu so the witness escape is never shadowed; bed ->
# rest; storage_box -> StorageScreen; fence -> Phase 5 pen action); then FISHING (Phase 5:
# faced water + a bagged rod -> fishing_runtime.try_fish; a hooked mon rides game_runtime's
# pending-encounter seam through main's normal battle path); then harvest; then build mode
# on a walkable faced tile with a Build-capable mon. The campfire lit toggle mutates the
# live placement entry ("lit": false when extinguished, ABSENT when lit — map is canonical).
# Party-screen FIELD MOVE: Build -> constrained build mode; cut/dig/smash -> constrained
# harvest; Phase 4 moves -> field_move_actions; else capability display (never a silent
# harvest). Any overlay the router opened owns Z/X while visible (closing press feeds
# input_router's generalized latch).

const FieldMoveActions := preload("res://scripts/app/field_move_actions.gd")
const OverworldEntityActions := preload("res://scripts/app/overworld_entity_actions.gd")

const BUILD_MOVE := "build"
const DIG_MOVE := "dig"
const CAMPFIRE_ID := "campfire"
const BED_ID := "bed"
const BOX_ID := "storage_box"
const HARVEST_ACTIONS := ["cut", "dig", "smash"] # harvest the faced tile; build + Phase 4 moves route elsewhere

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _structure_layer: Node = null
var _field_move_actions = FieldMoveActions.new()
var _entity_actions = OverworldEntityActions.new()
var _landmark_actions = preload("res://scripts/app/landmark_actions.gd").new()
var _camp_menu: Node = null
var _storage_screen: Node = null
var _show_message: Callable = Callable()


func setup(runtime: Node, world: Node, player: Node, structure_layer: Node, show_message: Callable, camp_menu: Node = null, storage_screen: Node = null) -> void:
	_runtime = runtime
	_world = world
	_player = player
	_structure_layer = structure_layer
	_show_message = show_message
	runtime.player_avatar = player # seed_for_smoke pins the avatar's trigger-draw rng through this wire
	_field_move_actions.setup(runtime, world, player, show_message)
	_entity_actions.setup(runtime, player, show_message)
	_landmark_actions.setup(runtime, show_message)
	_camp_menu = camp_menu
	_storage_screen = storage_screen
	if _camp_menu != null and _camp_menu.has_signal("closed") and not _camp_menu.closed.is_connected(_on_camp_menu_closed):
		_camp_menu.closed.connect(_on_camp_menu_closed)
	if _storage_screen != null and _storage_screen.has_signal("closed") and not _storage_screen.closed.is_connected(_on_storage_screen_closed):
		_storage_screen.closed.connect(_on_storage_screen_closed)


# Overworld context Z: entities, camp objects, then fishing (faced water), then harvest, then build mode (header precedence).
func on_context_action() -> void:
	if _overlay_open():
		return # an overlay owns Z/X while open; the Main poll still fires
	var faced: Vector2i = _player.facing_tile()
	if _entity_actions.route_entity(faced):
		return
	if _landmark_actions.route_landmark(faced):
		return
	if _route_camp_object(faced):
		return
	if _try_fish(faced):
		return
	var result: Dictionary = _runtime.harvest_tile(faced)
	var move_id := str(result.get("move_id", ""))
	if move_id != "":
		# QoL: Z on diggable ground with no Dig-capable mon stays silent — diggable
		# tiles are walkable and everywhere (beach spawn), so the refusal toast fired
		# on constantly-pressed Z (annoyance, not information). Success + cut/smash
		# refusals still speak; the party-menu FIELD MOVE path keeps its feedback.
		if bool(result.get("ok", false)) or move_id != DIG_MOVE:
			_message(result)
	elif _world.is_tile_walkable(faced) and _runtime.party_has_field_move_ability(BUILD_MOVE):
		enter_build_mode({})
	else:
		_message(result)


# Phase 5 fishing: faced water casts with the best bagged rod (try_fish owns rod pick +
# refusals + the tier-gated hook); a hook rides the pending-encounter seam through main's
# normal battle path. True for ANY water tile — Z on water is always a cast.
func _try_fish(tile: Vector2i) -> bool:
	if _world.get_tile_biome(tile) != "WATER":
		return false
	var fishing: Variant = _runtime.get("fishing_runtime") if _runtime != null else null
	if fishing == null or not fishing.has_method("try_fish"):
		return false
	var result: Variant = fishing.call("try_fish", tile)
	var response: Dictionary = result if result is Dictionary else {}
	if bool(response.get("ok", false)):
		_player.encounter_requested.emit(tile)
		return true
	if str(response.get("message", "")) != "":
		_show_message.call(str(response.get("message", "")), 1.6)
	return true


func on_field_move_requested(move_id: String, mon_index: int) -> void:
	var party: Array = _runtime.get_party_snapshot()
	var mon: Dictionary = party[mon_index] if mon_index >= 0 and mon_index < party.size() else {}
	if move_id == BUILD_MOVE:
		if mon.is_empty():
			return
		if not _runtime.field_move_capable(BUILD_MOVE, mon):
			_show_message.call("%s can't use that here." % str(mon.get("name", "That Pokemon")), 1.6)
			return
		enter_build_mode(mon)
		return
	if _field_move_actions.handles(move_id):
		_field_move_actions.route(move_id)
		return
	if not HARVEST_ACTIONS.has(move_id):
		_show_message.call("%s knows %s, but there's nothing here that needs it." % [str(mon.get("name", "That Pokemon")), _runtime.catalog.get_field_move_name(move_id)], 1.8)
		return
	_message(_runtime.harvest_tile(_player.facing_tile(), mon))


func enter_build_mode(mon_constraint: Dictionary) -> void:
	_player.input_enabled = false
	_structure_layer.start_build(_player.facing_tile(), mon_constraint)


# Build mode ended (X cancel or a successful placement): movement back, persist.
func on_build_finished() -> void:
	_player.input_enabled = true
	_runtime.save_game()


# Camp-object precedence for the faced Z; false (fall through) when no placed camp object.
func _route_camp_object(tile: Vector2i) -> bool:
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


# Any overlay the router opened owns Z/X while visible (main.gd's poll carries the same check).
func _overlay_open() -> bool:
	return (_camp_menu != null and _camp_menu.visible) or (_storage_screen != null and _storage_screen.visible)


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


func _on_camp_menu_closed() -> void:
	_player.input_enabled = true
	if _runtime != null: _runtime.save_game()


# The closed-driven save captures every box mutation; the closing press's polls die on input_router's latch.
func _on_storage_screen_closed() -> void:
	_player.input_enabled = true
	if _runtime != null: _runtime.save_game()


func _message(result: Dictionary) -> void:
	_show_message.call(str(result.get("message", "")), 1.6)
