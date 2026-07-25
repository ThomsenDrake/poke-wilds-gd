extends RefCounted

# App-layer routing for the Phase 4 field moves (spec: field-moves.md), extracted
# from field_action_router.gd (at its 220 ceiling) the same way input_router and
# field_action_router were split from main.gd. The eight moves' RULES live in
# runtime/field_move_runtime.gd; this helper owns the APP side the runtime cannot
# touch — repositioning the avatar after a teleport/fly warp, mirroring the ride
# mount flag onto player_avatar's speed mode, and surfacing player-facing wording.
# Driven from the party-screen FIELD MOVE seam and smoke_context["field_move"]. The
# capability check is the runtime's (whole-party via field_move_runtime._capable),
# so mon_index is not needed here — only the move id + the avatar's tile/facing.

const FIELD_MOVE_ACTIONS := ["flash", "teleport", "fly", "ride", "repel", "power", "attack", "charm"]

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _show_message: Callable = Callable()


func setup(runtime: Node, world: Node, player: Node, show_message: Callable) -> void:
	_runtime = runtime
	_world = world
	_player = player
	_show_message = show_message


func handles(move_id: String) -> bool:
	return FIELD_MOVE_ACTIONS.has(move_id)


# Runs one field move: invoke the runtime, apply any warp/mount to the avatar,
# surface wording, and persist on success (repel counter / player tile / etc.).
func route(move_id: String) -> void:
	var fm: Variant = _runtime.field_move_runtime
	var player_tile: Vector2i = _player.tile_position
	var result: Dictionary = _invoke(fm, move_id, player_tile)
	if bool(result.get("ok", false)) and result.has("tile") and (move_id == "teleport" or move_id == "fly"):
		_warp(result["tile"])
	_show_message.call(_message_for(move_id, result), 1.8)
	if bool(result.get("ok", false)):
		_runtime.save_game()


func _invoke(fm: Variant, move_id: String, player_tile: Vector2i) -> Dictionary:
	match move_id:
		"flash": return fm.use_flash(player_tile)
		"teleport": return fm.use_teleport()
		"fly":
			var dest: Vector2i = fm.last_way_stone()
			return fm.use_fly(dest) if dest != Vector2i.MAX else {"ok": false, "reason": "no_way_stone"}
		"ride":
			var result: Dictionary = fm.use_ride()
			if bool(result.get("ok", false)):
				_player.set_mounted(bool(result.get("riding", false)))
			return result
		"repel": return fm.activate_repel()
		"power": return fm.use_power(_player.facing_tile(), _player.facing_tile() - player_tile)
		"attack": return fm.use_attack("")
		"charm": return fm.use_charm("", 1)
	return {"ok": false, "reason": "unknown"}


# A warp sets the logical player tile (the runtime already traced teleport_used /
# fly_used) then moves the avatar + syncs the window; the deterministic world
# needs no rebuild for a position change.
func _warp(tile: Vector2i) -> void:
	_runtime.set_player_tile(tile)
	_player.set_tile_position(tile)
	if _world != null:
		_world.sync_visible(tile)


func _message_for(move_id: String, result: Dictionary) -> String:
	if bool(result.get("ok", false)):
		match move_id:
			"flash": return "Flash lit up the area!"
			"teleport": return "You teleported to the way stone."
			"fly": return "You flew to the way stone."
			"ride": return "You dismounted." if not bool(result.get("riding", true)) else "You mounted up. It's faster now!"
			"repel": return "Repel's effect settled in."
			"power": return "The boulder rolled aside!"
			"attack": return "Attack!"
			"charm": return "Charm!"
	match str(result.get("reason", "")):
		"not_capable": return "No party Pokemon can do that here."
		"no_way_stone": return "There is no way stone to travel to."
		"unvisited_way_stone": return "You can't fly somewhere you haven't been."
		"no_boulder": return "There is no boulder here to move."
		"blocked_destination": return "The boulder won't budge that way."
		"no_target": return "There is nothing here that needs it."
	return "That won't work here."
