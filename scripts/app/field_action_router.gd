extends RefCounted

# App-layer field-action routing extracted from main.gd (scene-script line budget).
# Overworld context Z precedence: Phase 6 overworld ENTITIES (overworld_entity_actions:
# mon -> dialogue recruit, wild egg -> TAKE); then LANDMARK puzzle arms (Phase 7 landmark_actions: mansion statues/key/journals/loot + ruins decor); then placed camp objects (campfire ->
# CampMenu — demolition STAYS in the menu so the witness escape is never shadowed; bed ->
# rest; storage_box -> StorageScreen; fence -> Phase 5 pen action); then FISHING (Phase 5:
# faced water + a bagged rod -> fishing_runtime.try_fish; a hooked mon rides game_runtime's
# pending-encounter seam through main's normal battle path); then harvest (Cut / Dig /
# Smash / demolish). Build mode is a dedicated C toggle, not a Z fallthrough. The campfire lit toggle mutates the
# live placement entry ("lit": false when extinguished, ABSENT when lit — map is canonical).
# Party-screen FIELD MOVE: Build -> constrained build mode; cut/dig/smash -> constrained
# harvest; Phase 4 moves -> field_move_actions; else capability display (never a silent
# harvest). Any overlay the routes opened owns Z/X while visible (closing press feeds
# input_router's generalized latch). The camp/storage placed-object routes AND the
# camp/storage overlay open+close lifecycle (overlay_open + the closed-signal
# re-enable/save) live in field_object_routes.gd (the 220-wall extraction; one
# delegation per precedence tier).

const FieldMoveActions := preload("res://scripts/app/field_move_actions.gd")
const OverworldEntityActions := preload("res://scripts/app/overworld_entity_actions.gd")
const FieldObjectRoutes := preload("res://scripts/app/field_object_routes.gd")

const BUILD_MOVE := "build"
const DIG_MOVE := "dig"
const HARVEST_ACTIONS := ["cut", "dig", "smash"] # harvest the faced tile; build + Phase 4 moves route elsewhere

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _structure_layer: Node = null
var _field_move_actions = FieldMoveActions.new()
var _entity_actions = OverworldEntityActions.new()
var _object_routes = FieldObjectRoutes.new()
var _landmark_actions = preload("res://scripts/app/landmark_actions.gd").new()
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
	_object_routes.setup(runtime, world, player, _entity_actions, show_message, camp_menu, storage_screen) # the routes own the camp/storage overlay open+close lifecycle


# Overworld context Z: entities, camp objects, then fishing (faced water), then harvest.
func on_context_action() -> void:
	if _object_routes.overlay_open():
		return # an overlay owns Z/X while open; the Main poll still fires
	var faced: Vector2i = _player.facing_tile()
	if _entity_actions.route_entity(faced):
		return
	if _landmark_actions.route_landmark(faced):
		return
	if _object_routes.route_camp_object(faced):
		return
	if _try_fish(faced):
		return
	var result: Dictionary = _runtime.harvest_tile(faced)
	var move_id := str(result.get("move_id", ""))
	# QoL: Z on diggable ground with no Dig-capable mon stays silent — diggable
	# tiles are walkable and everywhere (beach spawn), so the refusal toast fired
	# on constantly-pressed Z (annoyance, not information). Success + cut/smash
	# refusals + empty move_id ("nothing left here") still speak; the party-menu
	# FIELD MOVE path keeps its feedback. Build is C, never this Z fallthrough.
	if move_id == "" or bool(result.get("ok", false)) or move_id != DIG_MOVE:
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


# C toggles the tile-locked build overlay (Z stays harvest). Overlay-open
# no-ops so camp/storage keep C; active overlay exits; else enter on the faced tile.
func toggle_build_mode() -> void:
	if _object_routes.overlay_open():
		return
	if _structure_layer.is_active():
		_structure_layer.stop_build()
		return
	if not _runtime.party_has_field_move_ability(BUILD_MOVE):
		_show_message.call("No party Pokemon can BUILD.", 1.6)
		return
	enter_build_mode({})


func enter_build_mode(mon_constraint: Dictionary) -> void:
	_player.input_enabled = false
	_structure_layer.start_build(_player.facing_tile(), mon_constraint)


# Build mode ended (X cancel or a successful placement): movement back, persist.
func on_build_finished() -> void:
	_player.input_enabled = true
	_runtime.save_game()


func _message(result: Dictionary) -> void:
	_show_message.call(str(result.get("message", "")), 1.6)
