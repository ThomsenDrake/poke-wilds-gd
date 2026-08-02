extends RefCounted

# App-layer routing for the Phase 4 field moves (spec: field-moves.md), extracted
# from field_action_router.gd (at its 220 ceiling) the same way input_router and
# field_action_router were split from main.gd. The eight moves' RULES live in
# runtime/field_move_runtime.gd; this helper owns the APP side the runtime cannot
# touch — repositioning the avatar after a teleport/fly warp, mirroring the ride
# mount flag onto player_avatar's speed mode, and surfacing player-facing wording.
# Teleport/fly route through _route_warp — capability refuses FIRST (the runtime traces),
# then >1 registered way-stone opens the way-stone SELECTOR ($UI/WayStoneSelector), a single
# way-stone warps directly, and zero way-stones keep the v4 last-way-stone warp. Way-stones
# are plain intra-world warp points on the seamless infinite plane (infinite-world slice
# retired the world-edge beacon concept).
# Driven from the party-screen FIELD MOVE seam and smoke_context["field_move"]. The
# capability check is the runtime's (whole-party via field_move_runtime._capable),
# so mon_index is not needed here — only the move id + the avatar's tile/facing.

const FIELD_MOVE_ACTIONS := ["flash", "teleport", "fly", "ride", "repel", "power", "attack", "charm"]

var _runtime: Node = null
var _world: Node = null
var _player: Node = null
var _show_message: Callable = Callable()
var _selector: Node = null # the $UI/WayStoneSelector scene node (lazy; null = absent scene)


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
	if move_id == "teleport" or move_id == "fly":
		_route_warp(fm, move_id, player_tile) # Build 3: the selector-then-warp policy
		return
	var result: Dictionary = _invoke(fm, move_id, player_tile)
	_show_message.call(_message_for(move_id, result), 1.8)
	if bool(result.get("ok", false)):
		_runtime.save_game()


# Teleport/Fly policy (infinite-world slice: way-stones are plain intra-world warp points;
# the world-edge beacon concept is retired). The picker opens ONLY when the warp itself
# would be allowed — capability refuses first so the runtime traces field_move_refused and
# the selector never opens on a refused move. >1 registered way-stone -> the SELECTOR
# (registration order, deterministic); exactly one -> a direct warp to it; zero -> the v4
# legacy last-way-stone path.
func _route_warp(fm: Variant, move_id: String, player_tile: Vector2i) -> void:
	var stones: Array = _way_stones(fm)
	if stones.size() > 1 and _runtime.party_has_field_move_ability(move_id) and _open_selector(move_id, stones):
		return
	var result: Dictionary
	if stones.size() == 1:
		result = fm.use_teleport(stones[0]) if move_id == "teleport" else fm.use_fly(stones[0])
	else:
		result = _invoke(fm, move_id, player_tile) # legacy last stone; a refused warp traces here
	if bool(result.get("ok", false)) and result.has("tile"):
		_warp(result["tile"])
	_show_message.call(_message_for(move_id, result), 1.8)
	if bool(result.get("ok", false)):
		_runtime.save_game()


# The registered way-stones in registration (step) order — the selector's list order
# (field_move_runtime.way_stone_tiles; intra-world warp points on the seamless plane).
func _way_stones(fm: Variant) -> Array:
	if fm == null or not (fm as Object).has_method("way_stone_tiles"):
		return []
	var tiles: Variant = (fm as Object).call("way_stone_tiles")
	return tiles if tiles is Array else []


# Opens the selector with registration-ordered rows; its resolve callable warps on Z,
# its argless closed re-enables the avatar. False when the scene node is absent (an
# older/headless host) — the caller falls back to the legacy last-stone warp.
func _open_selector(move_id: String, stones: Array) -> bool:
	var selector: Node = _selector_node()
	if selector == null or not selector.has_method("open_selector"):
		return false
	_player.input_enabled = false
	if selector.has_signal("closed") and not selector.closed.is_connected(_on_selector_closed):
		selector.closed.connect(_on_selector_closed)
	var title := "WAY STONES" if move_id == "teleport" else "FLY TO A WAY STONE"
	selector.open_selector(title, _rows(stones), Callable(self, "_resolve_warp").bind(move_id))
	return true


func _rows(stones: Array) -> Array:
	var rows: Array = []
	for i in range(stones.size()):
		var tile: Vector2i = stones[i]
		rows.append({"label": "Way Stone %d — (%d, %d)" % [i + 1, tile.x, tile.y], "tile": tile})
	return rows


# The selector's Z-choice (bound move_id appended): the index-addressed runtime warp —
# the chosen tile IS a registered way-stone — then the avatar move, wording, and save.
func _resolve_warp(tile: Variant, move_id: String) -> void:
	var fm: Variant = _runtime.field_move_runtime
	var dest: Vector2i = tile if tile is Vector2i else Vector2i.ZERO
	var result: Dictionary = fm.use_teleport(dest) if move_id == "teleport" else fm.use_fly(dest)
	if bool(result.get("ok", false)) and result.has("tile"):
		_warp(result["tile"])
		_runtime.save_game()
	_show_message.call(_message_for(move_id, result), 1.8)


# The camp-menu/storage closed precedent: the avatar re-enables; a warp's save already
# rode _resolve_warp and a cancel changed nothing, so no save here.
func _on_selector_closed() -> void:
	_player.input_enabled = true


func _selector_node() -> Node:
	if _selector != null:
		return _selector
	var scene: Node = _runtime.get_tree().current_scene
	_selector = scene.get_node_or_null("UI/WayStoneSelector") if scene != null else null
	return _selector


func _invoke(fm: Variant, move_id: String, player_tile: Vector2i) -> Dictionary:
	match move_id:
		"flash": return fm.use_flash(player_tile)
		"teleport": return fm.use_teleport() # Build 3: _route_warp owns the SELECTOR policy; this arm is the zero-beacon legacy last-stone fallback
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
		"attack":
			# Phase 6: resolve the real target off the faced tile (the overworld entity
			# runtime registers field_move_runtime's hooks; an egg is the :248 shiny-check
			# + clear inside attack_entity, a mon is a forced battle, provoked:false :280).
			var faced_attack: Vector2i = _player.facing_tile()
			var entities: Variant = _runtime.get("overworld_mons_runtime")
			entities.call("note_faced_tile", faced_attack)
			var attack_target: Dictionary = entities.call("entity_at", faced_attack)
			if attack_target.is_empty():
				return fm.use_attack("")
			var attack_result: Dictionary = fm.use_attack(str(attack_target.get("species_id", "")))
			if str(attack_target.get("kind", "")) == "egg" and bool(attack_result.get("ok", false)):
				attack_result["egg_verdict"] = "shiny" if bool(attack_target.get("is_shiny", false)) else "plain"
			return attack_result
		"charm":
			var faced_charm: Vector2i = _player.facing_tile()
			var charm_entities: Variant = _runtime.get("overworld_mons_runtime")
			charm_entities.call("note_faced_tile", faced_charm)
			var charm_target: Dictionary = charm_entities.call("entity_at", faced_charm)
			return fm.use_charm(str(charm_target.get("species_id", "")), int(charm_target.get("level", 1))) if not charm_target.is_empty() else fm.use_charm("", 1)
	return {"ok": false, "reason": "unknown"}


# A warp sets the logical player tile (the runtime already traced teleport_used /
# fly_used) then moves the avatar + syncs the window; the deterministic world
# needs no rebuild for a position change.
func _warp(tile: Vector2i) -> void:
	_runtime.set_player_tile(tile)
	_player.set_tile_position(tile)
	_runtime.get("overworld_mons_runtime").call("note_warp", tile) # Phase 6: a warp ends every chase (:278 counter-play)
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
			"attack":
				match str(result.get("egg_verdict", "")): # Attack-on-egg shiny verdict (:248)
					"shiny": return "The egg gleams oddly... It's SHINY!"
					"plain": return "The egg breaks apart. It was not shiny."
				return "Attack!"
			"charm": return "Charm!"
	match str(result.get("reason", "")):
		"not_capable": return "No party Pokemon can do that here."
		"no_way_stone": return "There is no way stone to travel to."
		"unvisited_way_stone": return "You can't fly somewhere you haven't been."
		"no_boulder": return "There is no boulder here to move."
		"blocked_destination": return "The boulder won't budge that way."
		"no_target": return "There is nothing here that needs it."
	return "That won't work here."
