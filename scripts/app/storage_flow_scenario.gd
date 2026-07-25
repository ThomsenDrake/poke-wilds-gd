extends Node

# Storage Box + party-management scenario (Phase 3; spec: storage-and-party.md).
# Drives the full box loop through the real runtime + UI + input paths: stand
# beside a box and an overworld Z opens it through field_action_router's BOX_ID
# arm (avatar disabled, box_opened) — pre-wiring the scenario opened it directly
# and gated the polls with set_battle; deposit/withdraw with exact payloads
# (incl. the party-screen deposit_to_nearest); every storage_refused reason;
# the non-empty Cut refusal then the empty-box Cut; the confirm-gated release on
# BOTH branches via REAL keys; box INDEPENDENCE + v4 persistence; the overflow
# NO-ROUTING proof; the witness guard; the MOVE reorder. The second half lives
# in storage_flow_party_checks.gd (line budget). Seed-pinned, encounters zeroed,
# dispatcher save-guarded; storage_flow_failed + push_error on any non-pass
# (miss-002). Accumulated input is on: SmokeTap taps fire the polls that drive the Z seam; _press drives only _unhandled_input (a stray poll dies on overworld_idle's StorageScreen check + _overlay_open + latch).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const StorageFlowPartyChecks := preload("res://scripts/app/storage_flow_party_checks.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

const SEED := 2026072403
const PARTY_SPECIES := ["BULBASAUR", "CHARMANDER", "SQUIRTLE", "PIKACHU", "MACHOP", "ABRA"]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []; var _oks: Dictionary = {}
var _tile_a := Vector2i.ZERO; var _tile_b := Vector2i.ZERO; var _tile_wall := Vector2i.ZERO
var _cut_index := 0
func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true # SmokeTap taps must reach the polls; restore-on-every-exit below
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, PARTY_SPECIES)
	var full_party: Array = runtime.session.party.duplicate(true) # the 6 swapped mons, for the full-party capture
	_place_structures()
	var stand_before: Vector2i = _player().tile_position
	var checks := [[Callable(self, "_check_box_ok"), "box_ok"], [Callable(self, "_check_deposit_ok"), "deposit_ok"], [Callable(self, "_check_withdraw_ok"), "withdraw_ok"],
		[Callable(self, "_check_refusals"), "refused_ok"], [Callable(self, "_check_independence"), "independence_ok"], [Callable(self, "_check_save"), "save_ok"]]
	for check in checks:
		if not _failures.is_empty(): break
		var mark := _failures.size()
		await (check[0] as Callable).call()
		_oks[str(check[1])] = _failures.size() == mark
	if _failures.is_empty():
		var party_checks := StorageFlowPartyChecks.new()
		add_child(party_checks)
		await party_checks.run(_ctx, _runner, _failures, _oks, _tile_a, _tile_b, _tile_wall, _cut_index, full_party, stand_before)
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("storage_flow_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("storage_flow_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("StorageFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures))); runtime.warn("StorageFlowScenario", "Storage flow failed.", {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	Input.use_accumulated_input = false
	if _screen() != null and _screen().visible:
		_screen().close_screen()

func _place_structures() -> void: # boxes A + B plus one wall; preconditions keep the witness math from going vacuous
	var runtime = _runtime()
	for item_id in ["log", "dry_soil", "hard_stone", "poke_ball"]: runtime.session.remove_item(item_id, runtime.get_item_count(item_id))
	runtime.session.add_item("log", 8); runtime.session.add_item("dry_soil", 2); runtime.session.add_item("poke_ball", 5)
	var carriers := 0
	for i in range(runtime.session.party.size()):
		if runtime.field_move_capable("cut", runtime.session.party[i]): carriers += 1; _cut_index = i
	_ensure(carriers == 1, "precondition: the party must carry exactly one Cut mon (got %d)" % carriers)
	_ensure(runtime.party_has_field_move_ability("build"), "precondition: the party is not build-capable")
	# Boxes cost 2 Log in every biome (their demolish move is always Cut), but the
	# WALL must sit on the cut-cost shell — SAND/DESERT shells cost hard_stone ->
	# Smash — so the witness set the guard accumulates is exactly {cut}.
	var box_tiles := _find_open_tiles(_player().tile_position, 2)
	_tile_wall = Vector2i.ZERO
	for radius in range(1, 17): # separate scan: the wall needs no box-gap, only the cut-cost shell
		for tile in _runner.ring_around(_player().tile_position, radius):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if not (bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() and str(logic.get("structure_id", "")).is_empty()) \
				or ["DESERT", "SAND"].has(_world().get_tile_biome(tile)) or box_tiles.has(tile): continue
			_tile_wall = tile; break
		if _tile_wall != Vector2i.ZERO: break
	if box_tiles.size() < 2 or _tile_wall == Vector2i.ZERO: _failures.append("site: need two open box tiles plus a cut-shell wall tile within 16 rings"); return
	_tile_a = box_tiles[0]; _tile_b = box_tiles[1]
	_ensure(runtime.build_runtime.materials_for("wall", _world().get_tile_biome(_tile_wall)) == {"log": 1, "dry_soil": 1}, "precondition: the wall tile costs the stone shell")
	for entry in [["a", _tile_a, "storage_box"], ["b", _tile_b, "storage_box"], ["wall", _tile_wall, "wall"]]:
		var placed: Dictionary = runtime.build_runtime.try_place(entry[1], str(entry[2]), {})
		_ensure(bool(placed.get("ok", false)), "site: %s placement refused (%s)" % [str(entry[0]), str(placed.get("reason", ""))])

func _check_box_ok() -> void:
	var cursor := _runner.trace_log_line_count()
	var spot: Dictionary = _runner.stand_spot(_world(), _tile_a)
	if spot.is_empty(): _failures.append("box: box A has no walkable stand neighbor"); return
	_runner.teleport_player(_world(), _player(), _runtime(), spot["from_tile"]); _player().smoke_step(spot["direction"]) # blocked by the box, but faces it
	_ensure(_player().facing_tile() == _tile_a, "box: the player does not face box A after the blocked step")
	await SmokeTap.tap(get_tree(), "action_a") # the router's BOX_ID arm must open the screen
	_ensure(_screen().visible, "box: injection witness: the overworld Z did not open the storage screen (the Z-route arm is unwired)")
	_ensure(not _player().input_enabled, "box: the avatar is still enabled under the open screen (the router must own it)")
	_ensure(_runner.trace_log_has_since("box_opened", cursor, {"tile": [_tile_a.x, _tile_a.y], "count": 0}), "box: no box_opened trace with count 0")
	_screen().close_screen()
	_ensure(_player().input_enabled, "box: the avatar stayed disabled after close_screen (closed -> re-enable)")

func _check_deposit_ok() -> void:
	var runtime = _runtime()
	var mon: Dictionary = runtime.session.party[1]
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = runtime.storage_runtime.deposit(_tile_a, 1)
	_ensure(bool(result.get("ok", false)), "deposit: refused (%s)" % str(result.get("reason", "")))
	_ensure(runtime.session.party.size() == 5 and runtime.storage_runtime.box_snapshot(_tile_a).size() == 1, "deposit: party/box counts did not move")
	_ensure(_runner.trace_log_has_since("mon_deposited", cursor, {"tile": [_tile_a.x, _tile_a.y], "species_id": str(mon.get("species_id", "")),
		"name": str(mon.get("name", "")), "level": int(mon.get("level", 1)), "party_size": 5, "box_count": 1}), "deposit: no mon_deposited trace with the exact payload")
	# The party-screen path: stand beside box A and deposit through deposit_to_nearest.
	var spot: Dictionary = _runner.stand_spot(_world(), _tile_a)
	if spot.is_empty():
		_failures.append("deposit: box A has no walkable stand neighbor"); return
	_runner.teleport_player(_world(), _player(), runtime, spot["from_tile"])
	_ensure(bool(runtime.nearest_box_tile().get("found", false)) and runtime.nearest_box_tile().get("tile") == _tile_a, "deposit: nearest_box_tile is not box A beside the player")
	var mon2: Dictionary = runtime.session.party[1]
	cursor = _runner.trace_log_line_count()
	var nearest: Dictionary = runtime.deposit_to_nearest(1)
	_ensure(bool(nearest.get("ok", false)), "deposit-nearest: refused (%s)" % str(nearest.get("reason", "")))
	_ensure(_runner.trace_log_has_since("mon_deposited", cursor, {"tile": [_tile_a.x, _tile_a.y], "species_id": str(mon2.get("species_id", "")),
		"party_size": runtime.session.party.size(), "box_count": 2}), "deposit-nearest: no mon_deposited trace (box_count 2)")
func _check_withdraw_ok() -> void:
	var runtime = _runtime()
	var boxed: Array = runtime.storage_runtime.box_snapshot(_tile_a)
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = runtime.storage_runtime.withdraw(_tile_a, 0)
	_ensure(bool(result.get("ok", false)), "withdraw: refused (%s)" % str(result.get("reason", "")))
	_ensure(runtime.session.party.size() == 5 and runtime.storage_runtime.box_snapshot(_tile_a).size() == 1, "withdraw: party/box counts did not move")
	_ensure(str(runtime.session.party[4].get("species_id", "")) == str((boxed[0] as Dictionary).get("species_id", "")), "withdraw: the boxed mon did not rejoin the party")
	_ensure(_runner.trace_log_has_since("mon_withdrawn", cursor, {"tile": [_tile_a.x, _tile_a.y], "species_id": str((boxed[0] as Dictionary).get("species_id", "")),
		"name": str((boxed[0] as Dictionary).get("name", "")), "level": int((boxed[0] as Dictionary).get("level", 1)), "party_size": 5, "box_count": 1}), "withdraw: no mon_withdrawn trace with the exact payload")
func _check_refusals() -> void:
	var runtime = _runtime()
	var cursor := _runner.trace_log_line_count()
	_ensure(not bool(runtime.storage_runtime.withdraw(_tile_a, 99).get("ok", true)), "refuse: withdraw accepted a bad index")
	_ensure(_runner.trace_log_has_since("storage_refused", cursor, {"action": "withdraw", "tile": [_tile_a.x, _tile_a.y], "reason": "no_such_mon"}), "refuse: no storage_refused{no_such_mon}")
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(runtime.storage_runtime.deposit(_tile_wall, 0).get("ok", true)) and not bool(runtime.storage_runtime.open_box(_tile_wall).get("ok", true)), "refuse: a non-box tile accepted deposit/open")
	_ensure(_runner.trace_log_has_since("storage_refused", cursor, {"action": "deposit", "reason": "no_box"}), "refuse: no storage_refused{no_box}")
	var party: Array = runtime.session.party
	runtime.session.party = [(party[0] as Dictionary).duplicate(true)]
	cursor = _runner.trace_log_line_count()
	_ensure(str(runtime.storage_runtime.deposit(_tile_a, 0).get("reason", "")) == "last_party_member", "refuse: depositing the last party member was not refused")
	_ensure(_runner.trace_log_has_since("storage_refused", cursor, {"action": "deposit", "reason": "last_party_member"}), "refuse: no storage_refused{last_party_member}")
	runtime.session.party = party
	_ensure(bool(runtime.storage_runtime.deposit(_tile_b, _idx("PIKACHU")).get("ok", false)), "refuse-setup: PIKACHU would not enter box B")
	var with_five: Array = runtime.session.party
	var clone: Dictionary = (with_five[0] as Dictionary).duplicate(true)
	runtime.session.party = [clone.duplicate(true), clone.duplicate(true), clone.duplicate(true), clone.duplicate(true), clone.duplicate(true), clone.duplicate(true)]
	cursor = _runner.trace_log_line_count()
	_ensure(str(runtime.storage_runtime.withdraw(_tile_b, 0).get("reason", "")) == "party_full", "refuse: withdraw into a full party was not refused")
	_ensure(_runner.trace_log_has_since("storage_refused", cursor, {"action": "withdraw", "reason": "party_full"}), "refuse: no storage_refused{party_full}")
	runtime.session.party = with_five
	_ensure(bool(runtime.storage_runtime.withdraw(_tile_b, 0).get("ok", false)), "refuse-setup: PIKACHU would not come back from box B")
	cursor = _runner.trace_log_line_count()
	_ensure(str(runtime.storage_runtime.deposit(_tile_a, _cut_index).get("reason", "")) == "would_strand_demolition", "refuse: the last Cut carrier was depositable with a wall standing")
	_ensure(_runner.trace_log_has_since("storage_refused", cursor, {"action": "deposit", "reason": "would_strand_demolition", "species_id": "BULBASAUR"}), "refuse: no storage_refused{would_strand_demolition}")
	var bag_before: Dictionary = runtime.session.bag.duplicate(true)
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(runtime.build_runtime.try_demolish(_tile_a, {}).get("ok", true)) and runtime.storage_runtime.box_snapshot(_tile_a).size() == 1 and runtime.session.bag == bag_before, "refuse: a non-empty box was Cut")
	_ensure(_runner.trace_log_has_since("demolish_refused", cursor, {"structure_id": "storage_box", "tile": [_tile_a.x, _tile_a.y], "reason": "box_not_empty"}), "refuse: no demolish_refused{box_not_empty}")
func _check_independence() -> void:
	var runtime = _runtime()
	_ensure(bool(runtime.storage_runtime.deposit(_tile_a, _idx("MACHOP")).get("ok", false)), "independence: MACHOP would not enter box A")
	_ensure(runtime.storage_runtime.box_snapshot(_tile_b).is_empty(), "independence: box B sees box A's mon BEFORE the save")
	_runner.save_and_reload(_world(), runtime)
	var a_after: Array = runtime.storage_runtime.box_snapshot(_tile_a)
	_ensure(a_after.size() == 2 and str((a_after[1] as Dictionary).get("species_id", "")) == "MACHOP", "independence: box A's contents did not survive the round-trip")
	_ensure(runtime.storage_runtime.box_snapshot(_tile_b).is_empty(), "independence: box B gained box A's mon AFTER the round-trip")
	_ensure(bool(runtime.storage_runtime.withdraw(_tile_a, 1).get("ok", false)) and bool(runtime.storage_runtime.withdraw(_tile_a, 0).get("ok", false)), "independence: box A would not give its mons back")
	_ensure(not runtime.placed_structures().get("%d,%d" % [_tile_a.x, _tile_a.y], {}).has("contents"), "independence: an emptied box kept its contents key (v3-shape drift)")
func _check_save() -> void:
	var runtime = _runtime()
	runtime.save_game()
	var payload: Dictionary = runtime.save_store.load_payload()
	var key := "%d,%d" % [_tile_a.x, _tile_a.y]
	for corrupt in ["garbage", [42]]:
		(payload["structures"] as Dictionary)[key]["contents"] = corrupt
		_ensure(runtime._apply_loaded_payload(payload), "save: a corrupt contents value refused to load")
		_ensure(runtime.storage_runtime.box_snapshot(_tile_a).is_empty(), "save: corrupt contents %s did not normalize to an empty box" % str(corrupt))
	_ensure(runtime._apply_loaded_payload(runtime.save_store.load_payload()), "save: the on-disk state did not re-apply")
	_world().rebuild(runtime.get_world_seed())

# Spread tiles (Chebyshev gap >= 3) so a stand spot beside one box is never
# adjacent to the other (nearest_box_tile's scan stays unambiguous).
func _find_open_tiles(center: Vector2i, count: int) -> Array:
	var tiles: Array = []
	for ring in range(1, 17):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if not (bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() and str(logic.get("structure_id", "")).is_empty()):
				continue
			var far_enough := true
			for taken in tiles:
				if maxi(abs(tile.x - (taken as Vector2i).x), abs(tile.y - (taken as Vector2i).y)) < 3:
					far_enough = false; break
			if far_enough:
				tiles.append(tile)
				if tiles.size() >= count:
					return tiles
	return tiles
func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok
func _idx(species_id: String) -> int:
	for i in range(_runtime().session.party.size()):
		if str((_runtime().session.party[i] as Dictionary).get("species_id", "")) == species_id:
			return i
	return -1

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
func _screen() -> Node: return _message_box().get_node_or_null("../StorageScreen")
