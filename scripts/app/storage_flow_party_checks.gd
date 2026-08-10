extends Node

# Input-driven second-half groups of the storage_flow scenario (Phase 3; spec:
# storage-and-party.md): the confirm-gated release on BOTH branches through the
# real StorageScreen + MessageBox — opened through the REAL overworld Z seam
# (field_action_router's BOX_ID arm, avatar disabled; the set_battle poll-gate
# workaround is gone); the release-confirm mouse-bypass regression (storage_
# release_mouse_check.gd); the empty-box Cut; the overflow NO-ROUTING proof;
# the dynamic witness guard; the party-screen MOVE reorder (commit + cancel-
# restore + save persistence). Extracted from storage_flow_scenario.gd for the
# app line budget (the placement_flow rationale). Shares the scenario's failure
# list + oks map; the scenario owns the accumulated input: one-frame _press
# drives only _unhandled_input — a stray poll dies on the StorageScreen overlay
# gate + the latch (the cursor asserts prove it; input_gate's header).

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const StorageReleaseMouseCheck := preload("res://scripts/app/storage_release_mouse_check.gd")
const BattleScenarioFixtures := preload("res://scripts/app/battle_scenario_fixtures.gd")

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = []; var _oks: Dictionary = {}
var _tile_a := Vector2i.ZERO; var _tile_b := Vector2i.ZERO; var _tile_wall := Vector2i.ZERO; var _tile_c := Vector2i.ZERO
var _cut_index := 0


func run(ctx: Dictionary, runner, failures: Array, oks: Dictionary, tile_a: Vector2i, tile_b: Vector2i, tile_wall: Vector2i, cut_index: int, full_party: Array, stand: Vector2i) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _oks = oks
	_tile_a = tile_a; _tile_b = tile_b; _tile_wall = tile_wall; _cut_index = cut_index
	var groups := [[Callable(self, "_check_release"), "release_ok"], [Callable(self, "_check_empty_cut"), "refused_ok"],
		[Callable(self, "_check_overflow").bind(full_party), "overflow_ok"], [Callable(self, "_check_witness"), "witness_ok"],
		[Callable(self, "_check_reorder").bind(stand), "reorder_ok"], [Callable(self, "_check_release_mouse"), "release_mouse_ok"]]
	for group in groups:
		if not _failures.is_empty(): break
		var mark := _failures.size()
		await (group[0] as Callable).call()
		var key := str(group[1])
		_oks[key] = _oks.get(key, false) or _failures.size() == mark


# RELEASE on BOTH confirm branches: real injected keys through the real Z seam
# + StorageScreen + MessageBox (the 0.2 destructive-action contract).
func _check_release() -> void:
	var runtime = _runtime(); var abra: int = _idx("ABRA"); var mon: Dictionary = runtime.session.party[abra]
	_ensure(bool(runtime.storage_runtime.deposit(_tile_a, abra).get("ok", false)), "release: ABRA would not enter box A")
	var spot: Dictionary = _runner.stand_spot(_world(), _tile_a)
	if spot.is_empty(): _failures.append("release: box A has no walkable stand neighbor"); return
	_runner.teleport_player(_world(), _player(), runtime, spot["from_tile"]); _player().smoke_step(spot["direction"])
	_ensure(_player().facing_tile() == _tile_a, "release: the player does not face box A after the blocked step")
	await SmokeTap.tap(get_tree(), "action_a") # the real seam: the router's BOX_ID arm must open the screen
	_ensure(_screen().visible and not _player().input_enabled, "release: injection witness: Z did not open the screen + disable the avatar (the Z-route arm is unwired)")
	await _press("action_a") # browse -> actions (WITHDRAW / RELEASE / SUMMARY / CANCEL)
	await _press("move_down") # RELEASE
	var cursor: int = _runner.trace_log_line_count()
	await _press("action_a") # -> the MessageBox confirm
	if not _ensure(_message_box().is_confirming(), "release: injection witness: RELEASE did not open the confirm box"):
		return
	await _press("action_b") # cancel: the mon must survive
	_ensure(not _message_box().is_confirming() and _screen().visible, "release: cancel left the confirm up or closed the screen")
	_ensure(runtime.storage_runtime.box_snapshot(_tile_a).size() == 1 and not _runner.trace_log_has_since("mon_released", cursor), "release: cancel removed the mon anyway")
	await _press("action_a") # confirm again (the RELEASE row stays selected)
	await _press("action_a") # -> confirmed: the runtime release executes
	_ensure(runtime.storage_runtime.box_snapshot(_tile_a).is_empty(), "release: confirm left the mon in the box")
	_ensure(not _runner.trace_log_has_since("field_move_used", cursor), "release: a confirm/cancel press leaked into the context poll (the latch failed)")
	_ensure(_runner.trace_log_has_since("mon_released", cursor, {"source": "box", "tile": [_tile_a.x, _tile_a.y], "species_id": str(mon.get("species_id", "")),
		"name": str(mon.get("name", "")), "level": int(mon.get("level", 1))}), "release: no mon_released trace with the exact payload")
	await _press("action_b") # browse X: the real closed path must re-enable the avatar
	_ensure(not _screen().visible and _player().input_enabled, "release: X did not close the screen + re-enable the avatar")


# The empty-box Cut: the full 2 Log refund, the tile open ground again.
func _check_empty_cut() -> void:
	var runtime = _runtime()
	var log_before: int = runtime.get_item_count("log")
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = runtime.build_runtime.try_demolish(_tile_a, {})
	_ensure(bool(result.get("ok", false)) and runtime.get_item_count("log") == log_before + 2, "empty-cut: refused, or the refund is not exactly 2 Log")
	_ensure(_runner.trace_log_has_since("structure_demolished", cursor, {"structure_id": "storage_box", "tile": [_tile_a.x, _tile_a.y]}), "empty-cut: no structure_demolished trace")
	_ensure(_world().is_tile_walkable(_tile_a) and str(_world().get_tile_logic(_tile_a).get("structure_id", "")).is_empty(), "empty-cut: the tile is not open ground again")


# Overflow NO-ROUTING: a full-party capture goes to the campsite hold, never a box.
func _check_overflow(full_party: Array) -> void:
	var runtime = _runtime()
	_runner.resync_player_tile(_world(), _player(), runtime)
	runtime.session.campsite_pokemon.clear(); runtime.session.party = full_party.duplicate(true) # fixture reset: assert THIS capture in an EMPTY hold
	var target: Dictionary = BattleScenarioFixtures.guaranteed_capture_mon(runtime)
	if target.is_empty():
		_failures.append("overflow: no catalog species meets the guaranteed-capture catch rate"); return
	var placements_before: Dictionary = runtime.placed_structures().duplicate(true)
	var cursor: int = _runner.trace_log_line_count()
	runtime.start_wild_battle(target)
	var caught: Dictionary = runtime.use_pokeball()
	_ensure(str(caught.get("outcome", "")) == "caught_box_full", "overflow: full-party capture outcome was '%s'" % str(caught.get("outcome", "")))
	_ensure(runtime.session.campsite_count() == 1 and str(runtime.session.get_campsite_pokemon()[0].get("species_id", "")) == str(target.get("species_id", "")), "overflow: the capture did not land in the campsite hold")
	_ensure(_runner.trace_log_has_since("mon_relocated", cursor, {"species_id": str(target.get("species_id", ""))}), "overflow: no mon_relocated trace")
	_ensure(runtime.placed_structures() == placements_before, "overflow: a box gained the capture (boxes must never be an overflow sink)")
	runtime.session.party.remove_at(runtime.session.party.size() - 1)
	var retrieved: Dictionary = runtime.retrieve_campsite_mon(0)
	_ensure(str(retrieved.get("species_id", "")) == str(target.get("species_id", "")) and runtime.session.campsite_count() == 0, "overflow: the held mon was not retrievable")


# Witness guard: dormant once nothing stands; a non-stranding deposit proceeds
# while a stranding one (the last Cut carrier, with a box up) stays refused.
func _check_witness() -> void:
	var runtime = _runtime()
	_ensure(bool(runtime.build_runtime.try_demolish(_tile_wall, {}).get("ok", false)), "witness: the wall would not demolish")
	_ensure(bool(runtime.build_runtime.try_demolish(_tile_b, {}).get("ok", false)), "witness: the empty box B would not demolish")
	_ensure(runtime.storage_runtime.required_witness_moves().is_empty(), "witness: the guard is not dormant with nothing standing")
	_tile_c = _tile_a
	_ensure(bool(runtime.build_runtime.try_place(_tile_c, "storage_box", {}).get("ok", false)), "witness: box C would not place on the open ground")
	var cursor: int = _runner.trace_log_line_count()
	_ensure(bool(runtime.storage_runtime.deposit(_tile_c, _idx("CHARMANDER")).get("ok", false)), "witness: a non-stranding deposit was refused with the guard satisfied")
	_ensure(_runner.trace_log_has_since("mon_deposited", cursor, {"tile": [_tile_c.x, _tile_c.y], "species_id": "CHARMANDER"}), "witness: no mon_deposited trace for the non-stranding deposit")
	_ensure(str(runtime.storage_runtime.deposit(_tile_c, _idx("BULBASAUR")).get("reason", "")) == "would_strand_demolition", "witness: the last Cut carrier was depositable with a box standing")
	_ensure(bool(runtime.storage_runtime.withdraw(_tile_c, 0).get("ok", false)), "witness: CHARMANDER would not come back from box C")


# Party-screen MOVE: commit changes the order; cancel restores the pre-MOVE order.
func _check_reorder(stand: Vector2i) -> void:
	var runtime = _runtime()
	# The POSITIVE gate branch: adjacent to box C, DEPOSIT must be listed (the
	# {found, tile} result wired through the party-screen context callables).
	var c_spot: Dictionary = _runner.stand_spot(_world(), _tile_c)
	if not c_spot.is_empty():
		_runner.teleport_player(_world(), _player(), runtime, c_spot["from_tile"])
		_call("toggle_menu"); _start_menu()._activate_entry(0)
		await _press("action_a"); _ensure(_deposit_listed(), "reorder: DEPOSIT missing beside box C (the party-screen gate is unwired)")
		await _press("action_b"); await _press("action_b"); _call("toggle_menu")
	_runner.teleport_player(_world(), _player(), runtime, stand)
	var order0: Array = _order()
	_call("toggle_menu"); _start_menu()._activate_entry(0)
	await _press("action_a") # action list; MOVE stays row 1 whether or not DEPOSIT is listed
	var box_adjacent: bool = abs(stand.x - _tile_c.x) + abs(stand.y - _tile_c.y) == 1
	_ensure(_deposit_listed() == box_adjacent, "reorder: DEPOSIT listed (%s) does not match box-C adjacency (%s)" % [_deposit_listed(), box_adjacent])
	for action in ["move_down", "action_a", "move_down", "action_a"]:
		await _press(action) # MOVE -> one live step -> commit
	_ensure(_order() == [order0[1], order0[0]] + order0.slice(2), "reorder: MOVE did not commit the swapped order")
	var committed: Array = _order()
	for action in ["action_a", "move_down", "action_a", "move_down", "action_b"]:
		await _press(action) # MOVE again -> one step -> cancel
	_ensure(_order() == committed, "reorder: cancel did not restore the pre-MOVE order")
	_runner.save_and_reload(_world(), runtime)
	_ensure(_order() == committed, "reorder: the committed order did not survive the save round-trip")
	await _press("action_b") # close the party screen back to the menu panel
	_call("toggle_menu")


# The S2 release-confirm mouse-bypass group (the deposits + the real seam + the synthesized click live in the extraction for this file's line budget).
func _check_release_mouse() -> void:
	var check := StorageReleaseMouseCheck.new()
	add_child(check)
	await check.run(_ctx, _runner, _failures, _tile_c)


# One-frame press+release: drives _unhandled_input; can never fire a Main poll
# (the house injection rule; input_gate's header).
func _press(action: String) -> void:
	SmokeTap.inject_press(action)
	SmokeTap.inject_release(action)
	await get_tree().create_timer(0.08).timeout


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _idx(species_id: String) -> int:
	for i in range(_runtime().session.party.size()):
		if str((_runtime().session.party[i] as Dictionary).get("species_id", "")) == species_id:
			return i
	return -1


func _order() -> Array:
	var ids: Array = []
	for mon in _runtime().session.party:
		ids.append(str((mon as Dictionary).get("species_id", "")))
	return ids


# The party-screen DEPOSIT gate reads storage_runtime.box_tile_near's {found,
# tile} (the found flag, never a tile sentinel); this reads the gate's verdict
# back out of the live action list — the regression guard for that wiring.
func _deposit_listed() -> bool:
	var screen: Variant = _start_menu().get("_party_screen")
	var actions: Variant = (screen as Node).get("_actions") if screen is Node else []
	if not actions is Array:
		return false
	for action in actions:
		if action is Dictionary and str((action as Dictionary).get("label", "")) == "DEPOSIT":
			return true
	return false


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _message_box() -> Node: return _ctx["message_box"]
func _screen() -> Node: return _message_box().get_node_or_null("../StorageScreen")
