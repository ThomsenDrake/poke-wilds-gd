extends RefCounted

# Party-screen action list builder (extracted from party_screen.gd for the ui
# line budget; party_rows.gd sibling). Pure data: entries are {id, label,
# move_id?} dicts the screen renders into its ItemList and dispatches on id.
# Phase 3 adds MOVE (arbitrary reorder) and DEPOSIT (to an adjacent storage
# box) to the SWAP LEAD / SUMMARY / FIELD MOVE / RETRIEVE set. FIELD MOVE
# entries are capability DISPLAY (species flag==1); non-harvest moves surface
# an explanatory message at the app layer — overworld triggers are future
# phases (spec: menu-and-save.md, storage-and-party.md).

const ACTION_SWAP := "swap"
const ACTION_MOVE := "move"
const ACTION_SUMMARY := "summary"
const ACTION_FIELD_MOVE := "field_move"
const ACTION_DEPOSIT := "deposit"
const ACTION_RETRIEVE := "retrieve"
const ACTION_CANCEL := "cancel"


# The action entries for the selected mon. `held` is the campsite hold snapshot;
# `has_box` whether a storage box sits adjacent to the player (the runtime's
# {found, tile} result — the found flag gates DEPOSIT, never a tile sentinel,
# so a box at world tile (0,0) offers DEPOSIT like any other).
static func build_action_entries(mon: Dictionary, eligible_moves: Array, move_name: Callable,
		held: Array, party_size: int, has_box: bool) -> Array:
	var entries: Array = [{"id": ACTION_SWAP, "label": "SWAP LEAD"}]
	if party_size > 1:
		entries.append({"id": ACTION_MOVE, "label": "MOVE"})
	entries.append({"id": ACTION_SUMMARY, "label": "SUMMARY"})
	for move_id in eligible_moves:
		var label := str(move_name.call(move_id)) if move_name.is_valid() else str(move_id).capitalize()
		entries.append({"id": ACTION_FIELD_MOVE, "label": "FIELD: %s" % label, "move_id": str(move_id)})
	if has_box:
		entries.append({"id": ACTION_DEPOSIT, "label": "DEPOSIT"})
	if not held.is_empty() and party_size < 6:
		var oldest: Dictionary = held[0] if held[0] is Dictionary else {}
		entries.append({"id": ACTION_RETRIEVE, "label": "RETRIEVE: %s" % str(oldest.get("name", "?"))})
	entries.append({"id": ACTION_CANCEL, "label": "CANCEL"})
	return entries


# The target slot for one live reorder step (wraps), or -1 when the party is
# too small to reorder.
static func move_target_index(from_index: int, direction: int, party_size: int) -> int:
	if party_size < 2:
		return -1
	return wrapi(from_index + direction, 0, party_size)


# Inverts [original index per current slot] into the reorder argument that
# restores the original order (session_state.set_party_order's shape).
static func inverse_permutation(current_by_slot: Array) -> Array:
	var order: Array = []
	order.resize(current_by_slot.size())
	for slot in range(current_by_slot.size()):
		order[int(current_by_slot[slot])] = slot
	return order
