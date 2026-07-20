extends Node

# Navigation-audit scenario dispatched from SmokeScenarios: proves traversal,
# battle-menu, and start-menu navigation contracts against the live scene.
# Traversal samples tiles in expanding rings and drives real smoke_steps
# (blocked tiles must reject with a reason, walkable tiles must accept); the
# gate contract is party-capability based: a cut gate rejects even a
# cut-capable party until the resolver clears the tile, and a surf gate opens
# passively for a surf-capable party but stays shut without one. The battle
# contract lives in nav_audit_battle.gd; the menu contract walks the
# entry list and both sub-screens. One nav_audit_passed trace on success;
# push_error with specifics otherwise. Save backup/restore is the
# dispatcher's job, so this file holds no save-guard logic.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const NavAuditBattle := preload("res://scripts/app/nav_audit_battle.gd")

const SCAN_RADIUS := 10
const GATED_SCAN_RADIUS := 20
const MAX_RING_TESTS := 8
const MIN_TRAVERSAL_CHECKS := 5

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _traversal_checked := 0
var _battle_options_checked := 0
var _menu_entries_checked := 0
var _block_reason := ""


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	_player().blocked.connect(_on_player_blocked)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	await _audit_traversal()
	var battle: Dictionary = NavAuditBattle.new().run(_ctx)
	_failures.append_array(battle.get("failures", []))
	_battle_options_checked = int(battle.get("options_checked", 0))
	await _audit_menu()
	_player().encounter_chance = saved_chance
	_player().blocked.disconnect(_on_player_blocked)
	if _failures.is_empty():
		_runtime().emit_trace("nav_audit_passed", "SmokeScenarios", {
			"traversal_checked": _traversal_checked,
			"battle_options_checked": _battle_options_checked,
			"menu_entries_checked": _menu_entries_checked
		})
	else:
		push_error("Nav audit failed: %s" % "; ".join(PackedStringArray(_failures)))


func _audit_traversal() -> void:
	var center: Vector2i = _player().tile_position
	await _audit_gated_tile(center)
	var blocked: Array = []
	var walkable: Array = []
	for radius in range(1, SCAN_RADIUS + 1):
		for tile in _runner.ring_around(center, radius):
			var spot := _runner.stand_spot(_world(), tile)
			if spot.is_empty():
				continue # landlocked tiles cannot be step-tested
			var entry := {"tile": tile, "from": spot["from_tile"], "dir": spot["direction"]}
			if _world().is_tile_walkable(tile):
				walkable.append(entry)
			elif _world().tile_requires_field_move(tile).is_empty():
				blocked.append(entry)
	for entry in _runner.even_samples(blocked, MAX_RING_TESTS):
		await _check_blocked_tile(entry)
	for entry in _runner.even_samples(walkable, MAX_RING_TESTS):
		await _check_walkable_tile(entry)
	if _traversal_checked < MIN_TRAVERSAL_CHECKS:
		_failures.append("traversal: only %d tiles testable within %d rings" % [_traversal_checked, SCAN_RADIUS])


# Proves both gate contracts with crafted parties (restored after): the cut
# gate rejects a cut-capable party until the resolver clears the tile, and
# the surf gate rejects a magikarp party but accepts a gyarados one. The surf
# pair is scanned under the non-surf party or water reads walkable and hides.
func _audit_gated_tile(center: Vector2i) -> void:
	var party_before: Array = _runner.swap_party(_runtime(), ["MAGIKARP"])
	var cut_pair := _runner.find_gated_pair(_world(), center, GATED_SCAN_RADIUS, "cut")
	var surf_pair := _runner.find_gated_pair(_world(), center, GATED_SCAN_RADIUS, "surf")
	if cut_pair.is_empty():
		_failures.append("traversal: no cut-gated tile within %d rings" % GATED_SCAN_RADIUS)
	else:
		_runner.swap_party(_runtime(), ["BULBASAUR"])
		var before := await _probe_gate_step(cut_pair)
		if bool(before["accepted"]) or str(before["reason"]).is_empty():
			_failures.append("traversal: cut gate at %s did not reject before clearing" % str(cut_pair["gated_tile"]))
		elif not bool(_runtime().harvest_tile(cut_pair["gated_tile"]).get("ok", false)):
			_failures.append("traversal: resolver refused to cut %s" % str(cut_pair["gated_tile"]))
		else:
			var after := await _probe_gate_step(cut_pair)
			if bool(after["accepted"]):
				_traversal_checked += 1
			else:
				_failures.append("traversal: cut gate at %s stayed blocked after clearing" % str(cut_pair["gated_tile"]))
	if surf_pair.is_empty():
		_failures.append("traversal: no surf-gated tile within %d rings" % GATED_SCAN_RADIUS)
	else:
		_runner.swap_party(_runtime(), ["MAGIKARP"])
		var shut := await _probe_gate_step(surf_pair)
		_runner.swap_party(_runtime(), ["GYARADOS"])
		var open := await _probe_gate_step(surf_pair)
		if bool(shut["accepted"]) or str(shut["reason"]).is_empty():
			_failures.append("traversal: surf gate at %s did not reject without a surf-capable party" % str(surf_pair["gated_tile"]))
		elif not bool(open["accepted"]):
			_failures.append("traversal: surf gate at %s stayed shut with a surf-capable party" % str(surf_pair["gated_tile"]))
		else:
			_traversal_checked += 1
	_runner.restore_party(_runtime(), party_before)


# Drives one step from the pair's stand tile toward the gated tile and reports
# {"accepted", "reason"}; reason is the block text when the step is rejected.
func _probe_gate_step(pair: Dictionary) -> Dictionary:
	_runner.teleport_player(_world(), _player(), _runtime(), pair["from_tile"])
	await _settle_movement()
	_block_reason = ""
	var accepted := false
	if _player().smoke_step(-pair["direction"]):
		await _player().tile_changed
		accepted = _player().tile_position == pair["gated_tile"]
	return {"accepted": accepted, "reason": _block_reason}


func _check_blocked_tile(entry: Dictionary) -> void:
	var tile: Vector2i = entry["tile"]
	_runner.teleport_player(_world(), _player(), _runtime(), entry["from"])
	await _settle_movement()
	_block_reason = ""
	if _player().smoke_step(entry["dir"]):
		_failures.append("traversal: blocked tile %s accepted a step" % str(tile))
		await _player().tile_changed
	elif _player().tile_position != entry["from"]:
		_failures.append("traversal: rejected step still moved the player at %s" % str(tile))
	elif _block_reason.is_empty():
		_failures.append("traversal: blocked tile %s gave no block reason" % str(tile))
	else:
		_traversal_checked += 1


func _check_walkable_tile(entry: Dictionary) -> void:
	var tile: Vector2i = entry["tile"]
	_runner.teleport_player(_world(), _player(), _runtime(), entry["from"])
	await _settle_movement()
	_block_reason = ""
	if not _player().smoke_step(entry["dir"]):
		_failures.append("traversal: walkable tile %s rejected a step (%s)" % [str(tile), _block_reason])
		return
	await _player().tile_changed
	if _player().tile_position != tile:
		_failures.append("traversal: step toward %s landed on %s" % [str(tile), str(_player().tile_position)])
	else:
		_traversal_checked += 1


# A failed probe can leave the player mid-walk; never step again until it ends.
func _settle_movement() -> void:
	if _player()._moving:
		await _player().tile_changed


func _audit_menu() -> void:
	_call("toggle_menu")
	await get_tree().process_frame
	var menu := _start_menu()
	if not menu.visible:
		_failures.append("menu: toggle did not open the start menu")
		return
	for index in range(menu.ENTRIES.size()):
		if menu._selected_entry() != index:
			_failures.append("menu: d-pad reached entry %d, expected %d (%s)" % [menu._selected_entry(), index, menu.ENTRIES[index]])
		else:
			_menu_entries_checked += 1
		if index < menu.ENTRIES.size() - 1:
			menu._move_selection(1)
	await _audit_sub_screen(menu, "PartyScreen", menu.ENTRY_POKEMON)
	await _audit_sub_screen(menu, "BagScreen", menu.ENTRY_BAG)
	_call("toggle_menu")
	await get_tree().process_frame
	if menu.visible:
		_failures.append("menu: toggle did not close the start menu")


func _audit_sub_screen(menu: Node, node_name: String, entry: int) -> void:
	var screen := menu.get_node_or_null(node_name)
	if screen == null:
		_failures.append("menu: %s node is missing" % node_name)
		return
	menu._activate_entry(entry)
	await get_tree().process_frame
	if not screen.visible:
		_failures.append("menu: %s did not open from its entry" % node_name)
		return
	screen._back()
	await get_tree().process_frame
	if screen.visible or menu._submenu_open():
		_failures.append("menu: cancel from %s did not return to the entry list" % node_name)
	else:
		_menu_entries_checked += 1


func _on_player_blocked(reason: String, _tile: Vector2i) -> void:
	_block_reason = reason


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
