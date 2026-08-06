extends RefCounted

# PartyScreen action-menu behavior (extracted from party_screen.gd at the 220
# ui wall, restyle slice wave 2; the screen keeps thin delegates —
# input_gate_menu_checks reads `_actions`, layout_audit calls
# `_activate_action()`). Pure behavior over the screen's members: builds the
# _actions entries on open, then dispatches on the entry id (SWAP LEAD / MOVE /
# SUMMARY / FIELD MOVE / DEPOSIT / RETRIEVE / CANCEL).

const PartyActions := preload("res://scripts/ui/party_actions.gd")
const PartyRows := preload("res://scripts/ui/party_rows.gd")


# Builds the action entries for the selected mon and opens the action state.
static func open_actions(screen: Control) -> void:
	if screen._party.is_empty():
		return
	var held: Variant = screen._call_context("get_campsite_pokemon")
	var player_tile: Variant = screen._call_context("get_player_tile")
	var box: Variant = screen._call_context("box_tile_near", [player_tile]) if player_tile is Vector2i else {}
	var pen: Variant = screen._call_context("pen_tile_near", [player_tile]) if player_tile is Vector2i else {} # Phase 5: DEPOSIT falls back to a pen
	var has_box: bool = (box is Dictionary and bool((box as Dictionary).get("found", false))) or (pen is Dictionary and bool((pen as Dictionary).get("found", false)))
	screen._actions = PartyActions.build_action_entries(screen._party[screen._selected],
		PartyActions.eligible_field_moves(screen._party[screen._selected], screen._context.get("get_species", Callable())),
		screen._context.get("get_field_move_name", Callable()), held if held is Array else [],
		screen._party.size(), has_box)
	screen._action_selected = 0
	screen._show_panel("action")


static func activate(screen: Control) -> void:
	if screen._action_selected < 0 or screen._action_selected >= screen._actions.size():
		return
	var action: Dictionary = screen._actions[screen._action_selected]
	match str(action.get("id", "")):
		"swap":
			screen._call_context("set_party_lead", [screen._selected])
			screen._rebuild()
			screen._show_panel("list")
		"move":
			screen._move_order = range(screen._party.size()) # party == display order at entry
			screen._show_panel("move")
		"summary":
			screen._summary_text.text = PartyRows.summary_text(screen._party[screen._selected],
				screen._context.get("get_species", Callable()), screen._context.get("experience_for_level", Callable()))
			screen._show_panel("summary")
		"field_move":
			screen.close_screen()
			screen.field_move_requested.emit(str(action.get("move_id", "")))
		"deposit":
			var result: Variant = screen._call_context("deposit_to_nearest", [screen._selected])
			if result is Dictionary and bool((result as Dictionary).get("ok", false)):
				screen._rebuild()
				screen._show_panel("list")
			else: # refusals (last member, witness guard, no box) flash the Hint
				screen._hint.text = str((result as Dictionary).get("message", "That can't be done.")) if result is Dictionary else "That can't be done."
		"retrieve":
			screen._call_context("retrieve_campsite_mon", [0])
			screen._rebuild()
			screen._show_panel("list")
		_:
			screen._show_panel("list")
