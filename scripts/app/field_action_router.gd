extends RefCounted

# App-layer field-action routing extracted from main.gd (same rationale as
# input_router.gd, whose header says it was extracted so the scene script stays
# under its line budget). Owns the harvest-vs-build precedence for the overworld
# context Z and the party-screen FIELD MOVE — consuming the move_id the party
# screen sends (Phase 0 flagged main.gd ignoring it) — plus build-mode
# enter/exit bookkeeping. Main forwards its two callbacks here.

const BUILD_MOVE := "build"

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _structure_layer: Node = null
var _show_message: Callable = Callable()


func setup(runtime: Node, world: Node, player: Node, structure_layer: Node, show_message: Callable) -> void:
	_runtime = runtime
	_world = world
	_player = player
	_structure_layer = structure_layer
	_show_message = show_message


# Overworld context Z: harvest first; when nothing is left here and the faced
# tile is walkable with a Build-capable party member, open build mode on it.
func on_context_action() -> void:
	var result: Dictionary = _runtime.harvest_tile(_player.facing_tile())
	if str(result.get("move_id", "")) != "":
		_message(result)
	elif _world.is_tile_walkable(_player.facing_tile()) and _runtime.party_has_field_move_ability(BUILD_MOVE):
		enter_build_mode({})
	else:
		_message(result)


# Party-screen FIELD MOVE: Build opens build mode constrained to the selected
# mon (which must itself be capable); every other move harvests the faced tile
# under that mon's constraint (the pre-existing harvest behavior).
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
	_message(_runtime.harvest_tile(_player.facing_tile(), mon))


func enter_build_mode(mon_constraint: Dictionary) -> void:
	_player.input_enabled = false
	_structure_layer.start_build(_player.facing_tile(), mon_constraint)


# Build mode ended (X cancel or a successful placement): movement back, persist.
func on_build_finished() -> void:
	_player.input_enabled = true
	_runtime.save_game()


func _message(result: Dictionary) -> void:
	_show_message.call(str(result.get("message", "")), 1.6)
