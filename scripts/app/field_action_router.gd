extends RefCounted

# App-layer field-action routing extracted from main.gd (same rationale as
# input_router.gd, whose header says it was extracted so the scene script stays
# under its line budget). Owns the harvest-vs-build precedence for the overworld
# context Z and the party-screen FIELD MOVE — consuming the move_id the party
# screen sends (Phase 0 flagged main.gd ignoring it) — plus build-mode
# enter/exit bookkeeping. Main forwards its two callbacks here.
#
# Phase 2 camping slice (spec: docs/product-specs/camping-crafting-survival.md):
# the faced-tile Z gains camp-object precedence — a placed campfire opens the
# CampMenu (Craft / Extinguish-or-Light / Demolish) and a placed bed rests
# through camping_runtime.rest("bed"); anything else keeps the harvest-then-
# build flow below. Demolition STAYS reachable as a CampMenu entry, so the
# build loop's witness escape is never shadowed by the new precedence (the
# placement scenarios call try_demolish directly and stay green regardless).
# Also owns the campfire lit toggle the menu entry dispatches: it mutates the
# generator's live placement entry ("lit": false when extinguished, ABSENT
# when lit), traces campfire_lit, and saves — the placement map is canonical,
# exactly like occupancy. Phase 2 runtime handles (the crafting_runtime /
# camping_runtime members on GameRuntime) are duck-typed: until they land, a
# camp-object Z degrades to the Phase 1 harvest/demolish path.
#
# Phase 3 storage slice (spec: docs/product-specs/storage-and-party.md): the
# faced-tile Z gains a storage_box arm mirroring the campfire one — disable the
# avatar, open the StorageScreen on that box's tile, and on its `closed` signal
# re-enable the avatar + save (every box mutation persists). The closing X
# press feeds input_router's generalized latch via main.gd's bind_ui_consumers
# (it cannot re-fire the polls); the _overlay_open early-return (registry-
# mandated name, subsystems.toml) neutralizes the context poll while ANY overlay owns the screen.

const BUILD_MOVE := "build"
const CAMPFIRE_ID := "campfire"
const BED_ID := "bed"
const BOX_ID := "storage_box"
# The ONLY field moves with a live overworld effect from the party screen; the
# rest render as capability display (their overworld triggers are future phases —
# spec: menu-and-save.md FIELD MOVE classification).
const HARVEST_ACTIONS := ["cut", "dig", "smash"]

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _structure_layer: Node = null
var _camp_menu: Node = null
var _storage_screen: Node = null
var _show_message: Callable = Callable()


func setup(runtime: Node, world: Node, player: Node, structure_layer: Node, show_message: Callable, camp_menu: Node = null, storage_screen: Node = null) -> void:
	_runtime = runtime
	_world = world
	_player = player
	_structure_layer = structure_layer
	_show_message = show_message
	_camp_menu = camp_menu
	_storage_screen = storage_screen
	if _camp_menu != null and _camp_menu.has_signal("closed") and not _camp_menu.closed.is_connected(_on_camp_menu_closed):
		_camp_menu.closed.connect(_on_camp_menu_closed)
	if _storage_screen != null and _storage_screen.has_signal("closed") and not _storage_screen.closed.is_connected(_on_storage_screen_closed):
		_storage_screen.closed.connect(_on_storage_screen_closed)


# Overworld context Z: placed camp objects first (campfire -> CampMenu, bed ->
# rest); then harvest; when nothing is left here and the faced tile is walkable
# with a Build-capable party member, open build mode on it.
func on_context_action() -> void:
	if _overlay_open():
		return # an overlay owns Z/X while open; the Main poll still fires
	var faced: Vector2i = _player.facing_tile()
	if _route_camp_object(faced):
		return
	var result: Dictionary = _runtime.harvest_tile(faced)
	if str(result.get("move_id", "")) != "":
		_message(result)
	elif _world.is_tile_walkable(faced) and _runtime.party_has_field_move_ability(BUILD_MOVE):
		enter_build_mode({})
	else:
		_message(result)


# Party-screen FIELD MOVE: Build opens build mode constrained to the selected
# mon (which must itself be capable); cut/dig/smash harvest the faced tile under
# that mon's constraint (the pre-existing harvest behavior); every other move is
# capability display only — activating it explains there is nothing here that
# needs it instead of silently harvesting (overworld triggers: future phases).
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


# Camp-object precedence for the faced Z. Returns false (fall through to the
# harvest/build flow) when the tile carries no placed camp object, or when the
# Phase 2 surface the action needs has not landed yet.
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
	return false


# Any overlay the router opened owns Z/X/Enter while visible; main.gd's
# overworld_idle expression carries the same check for the poll itself.
func _overlay_open() -> bool:
	return (_camp_menu != null and _camp_menu.visible) or (_storage_screen != null and _storage_screen.visible)


func _open_camp_menu(tile: Vector2i) -> bool:
	if _camp_menu == null or not _camp_menu.has_method("open_menu"):
		return false
	_player.input_enabled = false
	_camp_menu.open_menu(tile, CAMPFIRE_ID, Callable(self, "_toggle_campfire").bind(tile))
	return true


# Mirrors _open_camp_menu: the app layer owns the avatar; the screen's
# `closed` signal owns the re-enable + save below.
func _open_storage_screen(tile: Vector2i) -> bool:
	if _storage_screen == null or not _storage_screen.has_method("open_screen"):
		return false
	_player.input_enabled = false
	_storage_screen.open_screen(tile)
	return true


# Bed rest: camping_runtime.rest("bed") owns the heal model, the time advance
# and the campsite anchor (plus its rested / campsite_established traces); the
# router only surfaces the confirmation and refreshes the presentation the
# step loop would have (the day/night tint follows the advanced clock).
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


# The camp menu's Extinguish/Light entry (spec: the toggle mutates the
# generator's live placement entry, traces campfire_lit, saves). Prefers a
# camping_runtime-owned toggle if one lands; otherwise flips the entry's
# additive "lit" field directly — a documented reach into runtime._world_gen
# (the house precedent reaches it from the app layer: visual_sweep_baselines'
# craft_state). Absent = lit, so re-lighting ERASES the field.
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
	return {"ok": true, "lit": now_lit,
		"message": "The fire catches again." if now_lit else "The fire dies down. Its light is gone."}


func _on_camp_menu_closed() -> void:
	_player.input_enabled = true
	if _runtime != null:
		_runtime.save_game()


# The closed-driven save captures every box mutation; the closing X press's
# polls die on input_router's latch (wired by main.gd's bind_ui_consumers).
func _on_storage_screen_closed() -> void:
	_player.input_enabled = true
	if _runtime != null:
		_runtime.save_game()


func _message(result: Dictionary) -> void:
	_show_message.call(str(result.get("message", "")), 1.6)
