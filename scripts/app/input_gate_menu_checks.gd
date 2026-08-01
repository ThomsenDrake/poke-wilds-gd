extends Node

# Menu-leak regressions for the GENERALIZED input latch (input_router.gd's
# bind_ui_consumers; spec: the Input map in bootstrap-and-overworld.md).
# input_gate_scenario's parts A+B cover the camp menu (the original latch);
# the Phase 3 final review found that latch covered ONLY the camp menu, so any
# OTHER input-phase UI close/confirm leaked the press into Main._process's
# same-frame polls (the input phase runs BEFORE the polls):
# (C) START CLOSE — Z on the start menu's CLOSE entry closed the menu AND the
#     context poll re-fired on the faced tile (here the bare former campfire,
#     dig-harvestable): field_move_used + a dig yield superseding the "Saved."
#     toast. Pre-fix red: the toast/field_move_used/bag-delta witnesses.
# (E) INERT FIELD MOVE — the party screen's FIELD MOVE on an inert move (Surf)
#     showed the capability-display message AND the same-frame poll harvested
#     the faced cut-tile (a cut-capable mon rides along in the party): the tree
#     fell and the harvest toast superseded "nothing here that needs it",
#     defeating the capability-display classification. Pre-fix red: the
#     tree-standing/field_move_used/toast witnesses.
# (D) NEW GAME CONFIRM — the MessageBox confirm Z ran the reset AND the same-
#     frame poll harvested (or build-opened) the spawn-facing tile on the
#     BRAND-NEW world, superseding the "New game started." toast. Runs LAST:
#     it resets the world (harmless — process-isolated per --scenario launch;
#     the dispatcher's save guard restores the file).
# Every tap is a REAL input-phase event through SmokeTap (press and release in
# separate iterations — smoke _press can never fire a poll), each part carrying
# injection witnesses so degraded delivery fails red, never vacuous green.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = [] # shared with the parent scenario


func run(ctx: Dictionary, runner, failures: Array) -> void:
	_ctx = ctx; _runner = runner; _failures = failures
	await _part_c_start_close_does_not_refire()
	await _part_e_inert_field_move_leaves_the_tree()
	await _part_d_new_game_confirm_resets_only() # LAST: it resets the world


# Part C — Z on the start menu's CLOSE entry closes ONLY the menu (reuses part
# B's stance: the player still faces the bare, dig-harvestable campfire tile).
func _part_c_start_close_does_not_refire() -> void:
	var runtime = _runtime()
	var player = _player()
	var tile_before: Vector2i = player.tile_position
	await _tap("start") # the poll path opens the start menu
	if not _expect(_start_menu().visible and not player.input_enabled, "C: injection witness: Enter did not open the start menu"):
		return
	_flush_down(5) # POKEMON -> BAG -> SAVE -> OPTIONS -> NEW GAME -> CLOSE
	await get_tree().process_frame
	var entries: ItemList = _start_menu().get_node("MenuPanel/Margin/VBox/Entries")
	var selected: PackedInt32Array = entries.get_selected_items()
	var row_text := entries.get_item_text(int(selected[0])) if selected.size() > 0 else ""
	if not _expect(row_text == "CLOSE", "C: precondition witness: selected row '%s' is not CLOSE" % row_text):
		return
	var bag_before: Dictionary = runtime.session.bag.duplicate(true)
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: the input phase closes the menu; the poll must be swallowed
	_expect(not _start_menu().visible, "C: injection witness: Z-on-CLOSE did not close the start menu")
	_expect(_toast_text() == "Saved.", "C: the close toast '%s' was superseded by a re-fired harvest" % _toast_text())
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "C: a harvest re-fired on the faced tile on the closing frame")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "C: a structure was placed on the re-fired press")
	_expect(not _runner.trace_log_has_since("materials_consumed", cursor), "C: materials were consumed on the re-fired press")
	_expect(runtime.session.bag == bag_before, "C: the bag changed on the closing frame (a dig yield leaked)")
	_expect(not _structure_layer().is_active(), "C: build mode opened on the closing frame")
	_expect(player.tile_position == tile_before, "C: the player moved")
	_expect(player.input_enabled, "C: the avatar stayed disabled after the menu closed")


# Part E — an inert FIELD MOVE facing a cut-gated tree leaves the tree standing.
func _part_e_inert_field_move_leaves_the_tree() -> void:
	var runtime = _runtime()
	var player = _player()
	var cut_tile := _find_cut_tile(player.tile_position)
	if not _expect(cut_tile != Vector2i.ZERO, "E: site: no cut-gated tile with a walkable stand neighbor within 16 rings"):
		return
	var spot: Dictionary = _runner.stand_spot(_world(), cut_tile)
	_runner.teleport_player(_world(), player, runtime, spot["from_tile"])
	player.smoke_step(spot["direction"]) # blocked by the tree, but faces it
	if not _expect(player.facing_tile() == cut_tile, "E: site: the player does not face the cut tile after the blocked step"):
		return
	# An inert mon at row 0 (PIKACHU: Surf only — inert in this port) plus a
	# cut-capable rider (BULBASAUR) so a pre-fix poll harvest falls the tree loudly.
	_runner.swap_party(runtime, ["PIKACHU", "BULBASAUR", "MACHOP", "SANDSHREW"])
	await _tap("start")
	if not _expect(_start_menu().visible, "E: injection witness: Enter did not open the start menu"):
		return
	await _tap("action_a") # row 0 POKEMON -> the party screen
	var party_screen: Node = _start_menu().get_node("PartyScreen")
	if not _expect(party_screen.visible, "E: injection witness: Z did not open the party screen"):
		return
	await _tap("action_a") # the list -> row 0's action list
	var actions: Variant = party_screen.get("_actions")
	if not _expect(actions is Array and not (actions as Array).is_empty(), "E: precondition witness: the action list did not open"):
		return
	var field_row := -1
	for i in range((actions as Array).size()):
		if str(((actions as Array)[i] as Dictionary).get("id", "")) == "field_move":
			field_row = i
			break
	if not _expect(field_row >= 0, "E: precondition: the action list has no FIELD MOVE row"):
		return
	var move_id := str(((actions as Array)[field_row] as Dictionary).get("move_id", ""))
	if not _expect(not ["cut", "dig", "smash", "build"].has(move_id), "E: precondition: the FIELD MOVE row is %s, a harvest/build move, not an inert one" % move_id):
		return
	_flush_down(field_row)
	await get_tree().process_frame
	var list: ItemList = party_screen.get_node("Panel/Margin/HBox/SideColumn/ActionPanel/Margin/ActionList")
	var selected: PackedInt32Array = list.get_selected_items()
	var row_text := list.get_item_text(int(selected[0])) if selected.size() > 0 else ""
	if not _expect(row_text.begins_with("FIELD"), "E: precondition witness: selected row '%s' is not a FIELD row" % row_text):
		return
	var tile_before: Vector2i = player.tile_position
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: capability display + hide_menu; the poll must be swallowed
	_expect(not _start_menu().visible and not party_screen.visible, "E: injection witness: the FIELD MOVE did not close the menu")
	_expect(_world().tile_requires_field_move(cut_tile) == "cut", "E: the faced tree fell (the harvest poll re-fired on the closing frame)")
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "E: a harvest re-fired on the closing frame")
	_expect(_toast_text().contains("nothing here that needs it"), "E: the capability message '%s' was superseded by the re-fired harvest" % _toast_text())
	_expect(player.tile_position == tile_before, "E: the player moved")
	_expect(player.input_enabled, "E: the avatar stayed disabled after the menu closed")


# Part D — Z on the MessageBox NEW GAME confirm resets ONLY the game.
func _part_d_new_game_confirm_resets_only() -> void:
	var runtime = _runtime()
	var player = _player()
	await _tap("start")
	if not _expect(_start_menu().visible, "D: injection witness: Enter did not open the start menu"):
		return
	_flush_down(4) # POKEMON -> BAG -> SAVE -> OPTIONS -> NEW GAME
	await get_tree().process_frame
	var entries: ItemList = _start_menu().get_node("MenuPanel/Margin/VBox/Entries")
	var selected: PackedInt32Array = entries.get_selected_items()
	var row_text := entries.get_item_text(int(selected[0])) if selected.size() > 0 else ""
	if not _expect(row_text.contains("NEW GAME"), "D: precondition witness: selected row '%s' is not NEW GAME" % row_text):
		return
	await _tap("action_a") # -> the MessageBox confirm
	if not _expect(_message_box().is_confirming(), "D: injection witness: Z did not open the NEW GAME confirm"):
		return
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: the confirm runs the reset; the poll must be swallowed
	_expect(not _message_box().is_confirming(), "D: injection witness: the confirm did not close")
	_expect(not _start_menu().visible, "D: injection witness: the menu did not close on confirm")
	_expect(_runner.trace_log_has_since("session_created", cursor), "D: injection witness: the confirm never ran a new game")
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "D: a harvest re-fired on the spawn-facing tile of the BRAND-NEW world")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "D: a structure was placed on the re-fired press")
	_expect(not _structure_layer().is_active(), "D: build mode opened on the confirm frame")
	_expect(player.tile_position == runtime.get_player_tile(), "D: the player did not return to the new spawn")
	_expect(_toast_text() == "New game started.", "D: the reset toast '%s' was superseded by the re-fired poll" % _toast_text())


# --- helpers (the input_gate_scenario injection pattern, via SmokeTap) ---
func _tap(action: String) -> void:
	if not SmokeTap.inject_press(action):
		_failures.append("injection: no key event is bound to %s" % action)
		return
	await get_tree().process_frame
	SmokeTap.inject_release(action)
	await get_tree().process_frame


# Flushes `count` move_down presses in ONE input phase (count _move(+1) calls),
# exactly like input_gate part B's Demolish flush.
func _flush_down(count: int) -> void:
	for _i in range(count):
		SmokeTap.inject_press("move_down")
	SmokeTap.inject_release("move_down")


func _find_cut_tile(center: Vector2i) -> Vector2i: # first cut gate with a stand spot, ring by ring
	for ring in range(1, 17):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if str(logic.get("requires_field_move", "")) == "cut" and not _runner.stand_spot(_world(), tile).is_empty():
				return tile
	return Vector2i.ZERO


func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok


func _toast_text() -> String:
	var label: Variant = _message_box().get("_label")
	return str((label as Label).text) if label is Label else ""


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _message_box() -> Node: return _ctx["message_box"]
func _structure_layer() -> Node: return _ctx["structure_layer"]
