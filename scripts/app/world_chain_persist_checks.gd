extends Node

# World chain scenario CHECKS, part 2 (Phase 7 Build 3; world-depth.md § World
# chaining + § Save v5): PER-WORLD PERSISTENCE + the beacon deltas + the v5 round
# trip + the CONTROL. Split from world_chain_checks.gd (part 1 owns the crossing
# sequence + the determinism/chained-world proofs — cross/place_fence/seam ride THAT
# instance, passed at setup; both under the app 220 wall, the overworld_mons_checks
# two-part precedent). The outgoing world is NEITHER erased NOR reset (fresh-faq.md
# :184): its maps file into chained_worlds["<cx>,<cy>"] and the return restores them;
# beacons register PER-WORLD (a beacon list never spans worlds, :186) and edge
# suppression keeps Teleport from skipping the chain mechanic (:190). miss-002: every
# red NAMES its cause.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldChainChecks := preload("res://scripts/app/world_chain_checks.gd")
# Domain access rides the runtime re-exports (the app layer may not reach domain
# directly — check_architecture's layer table).
const WorldChain := WorldChainChecks.WorldChain
const Landmarks := WorldChainChecks.Landmarks

const ORIGIN := WorldChainChecks.ORIGIN
const CHAINED := WorldChainChecks.CHAINED
const NORTH := WorldChainChecks.NORTH
const SOUTH := Vector2i.DOWN
const EDGE_NORTH := WorldChainChecks.EDGE_NORTH
const EDGE_SOUTH := Vector2i(0, 95) # the symmetric return edge (manhattan 95: at_edge)
const STATUE_LOCALS := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7)] # Landmarks._M_STATUE_TILES (private; landmark_flow's mirror)
const CONTROL_SEED := 2026072914 # the control window re-pin (distinct from SEED; +1 leaves the stream known)
const CONTROL_DRAWS := 8

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _checks = null # the part-1 instance: the crossing sequence + the shared helpers
var _probe = null
var chained_fence := Vector2i.MAX # the chained edit that must survive return + re-cross + save
var chained_campsite := Vector2i.MAX
var beacon_tile := Vector2i.MAX
var chained_stood := false # the chained fence stood after return + re-cross (persist_ok fold)


func setup(ctx: Dictionary, runner, failures: Array, checks: WorldChainChecks) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _checks = checks
	_probe = checks._probe


func begin_run() -> void: # per double-run half: the script's cross-script memory resets
	chained_fence = Vector2i.MAX; chained_campsite = Vector2i.MAX; beacon_tile = Vector2i.MAX; chained_stood = false


# The chained world's OWN edits: a fence near the entry edge + the campsite anchor
# (both must persist across return + re-cross + the save round-trip — chained worlds
# persist INDEPENDENTLY, the exit criterion).
func run_chained_edit_case(runtime) -> bool:
	var start: int = _failures.size()
	chained_fence = _checks.place_fence(runtime, runtime.session.player_tile)
	_ensure(chained_fence != Vector2i.MAX, "chained_edit: no placeable fence tile near the entry edge")
	chained_campsite = runtime.session.player_tile; runtime.session.campsite_tile = chained_campsite # the entry anchor (persisted campsite_x/y)
	return _failures.size() == start


# Puzzle-state INDEPENDENCE: solving the chained world's Mansion (three statues ->
# puzzle_state_changed{solved}) leaves ORIGIN's Mansion locked — each world's state
# rides the frozen location-keyed seam (landmark_runtime never branches on chain).
func run_puzzle_independence_case(runtime) -> bool:
	var start: int = _failures.size()
	var mansion: Dictionary = _checks.landmark_in_active(runtime, Landmarks.MANSION_ID)
	if not _ensure(not mansion.is_empty(), "puzzle: no mansion footprint in the active world"):
		return false
	var fp_origin: Vector2i = (mansion["footprint"] as Rect2i).position
	var solved_cursor := -1
	for i in range(Landmarks.MANSION_STATUES):
		if i == Landmarks.MANSION_STATUES - 1:
			solved_cursor = _runner.trace_log_line_count()
		var result: Dictionary = runtime.landmark_runtime.interact_statue(fp_origin + STATUE_LOCALS[i])
		_ensure(bool(result.get("handled", false)), "puzzle: statue %d toggle in (0,-1) was not handled" % i)
		if i < Landmarks.MANSION_STATUES - 1 and bool(result.get("solved", false)):
			_failures.append("puzzle: statue %d solved the chained mansion EARLY" % i)
	_ensure(_runner.trace_log_has_since("puzzle_state_changed", solved_cursor, {"landmark_id": Landmarks.MANSION_ID, "state": "unlocked", "solved": true}), "puzzle: no puzzle_state_changed{unlocked,solved} on the chained world's third statue")
	_ensure(_checks.seam_unlocked(runtime, CHAINED), "puzzle: the seam reads the chained mansion LOCKED after the solve")
	_ensure(not _checks.seam_unlocked(runtime, ORIGIN), "puzzle: solving (0,-1)'s mansion SOLVED origin's (state independence broken)")
	return _failures.size() == start


# The beacon deltas (fresh-faq.md:178-192): an edge-band way-stone registers ->
# beacon_placed{chain, beacon_index} (registry-REQUIRED) + the selector seam lists it;
# use_teleport AT the edge refuses edge_suppressed; inland, the index-addressed
# selector warps to it (closes the last-registered-only divergence).
func run_beacon_case(runtime) -> bool:
	var start: int = _failures.size()
	beacon_tile = runtime.session.player_tile # the entry edge sits INSIDE the suppression band (manhattan 94 >= 88)
	var cursor: int = _runner.trace_log_line_count()
	var reg: Dictionary = runtime.field_move_runtime.register_way_stone(beacon_tile)
	if not _ensure(bool(reg.get("ok", false)), "beacon: the entry-edge way-stone refused to register (%s)" % str(reg.get("reason", ""))):
		return false
	var index: int = runtime.world_chain_runtime.beacon_tiles().find(beacon_tile) # the SELECTOR listing order the trace now carries (inland stones skipped)
	_ensure(_runner.trace_log_has_since("waystone_registered", cursor, {"tile": [beacon_tile.x, beacon_tile.y]}), "beacon: no waystone_registered for the edge stone")
	_ensure(_runner.trace_log_has_since("beacon_placed", cursor, {"tile": [beacon_tile.x, beacon_tile.y], "chain": "0,-1", "beacon_index": index}), "beacon: no beacon_placed{chain:0,-1, beacon_index:%d}" % index)
	_ensure(runtime.world_chain_runtime.beacon_tiles().has(beacon_tile), "beacon: the multi-beacon SELECTOR seam does not list the edge stone")
	var refused: Dictionary = runtime.field_move_runtime.use_teleport(beacon_tile) # the player still stands ON the edge band
	_ensure(str(refused.get("reason", "")) == "edge_suppressed", "beacon: use_teleport at the edge returned %s, expected edge_suppressed" % str(refused.get("reason", "")))
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"reason": "edge_suppressed"}), "beacon: no field_move_refused{edge_suppressed}")
	_runner.teleport_player(_world(), _player(), runtime, ORIGIN) # inland: the suppression band releases
	var warp: Dictionary = runtime.field_move_runtime.use_teleport(beacon_tile)
	_ensure(bool(warp.get("ok", false)) and warp.get("tile", Vector2i.MAX) == beacon_tile, "beacon: the selector teleport to the indexed stone failed (%s)" % str(warp.get("reason", "")))
	_runner.teleport_player(_world(), _player(), runtime, beacon_tile) # the app layer moves the avatar (use_teleport returns the destination)
	return _failures.size() == start


# The RETURN crossing: surf south (0,-1) -> (0,0), newly_generated FALSE (the outgoing
# world was archived). Origin's fence stands, origin's campsite anchor is restored,
# BOTH puzzle states read independently off the seam.
func run_return_persist_case(runtime) -> bool:
	var start: int = _failures.size()
	var info: Dictionary = _checks.cross(runtime, EDGE_SOUTH, SOUTH, "surf", "return_cross")
	var result: Dictionary = info["result"]
	if bool(result.get("ok", false)):
		_ensure(str(result.get("chain", "")) == "0,0", "return: entered chain %s, expected 0,0" % str(result.get("chain", "")))
		_ensure(not bool(result.get("newly_generated", false)), "return: origin came back newly_generated (archived, not reset — :184)")
		_ensure(_runner.trace_log_has_since("world_chained", info["cursor"], {"chain": "0,0", "newly_generated": false}), "return: no world_chained{0,0, newly_generated:false}")
	_ensure(_placed(runtime, _checks.origin_fence), "return: origin's fence %s did not survive the crossing + return" % str(_checks.origin_fence))
	_ensure(not _placed(runtime, chained_fence), "return: the chained fence LEAKED into origin's placements")
	_ensure(runtime.session.campsite_tile == _checks.origin_campsite, "return: origin's campsite anchor %s was not restored (%s)" % [str(_checks.origin_campsite), str(runtime.session.campsite_tile)])
	_ensure(_checks.seam_unlocked(runtime, CHAINED), "return: the chained mansion's solved state did not persist under chained_worlds[0,-1]")
	_ensure(not _checks.seam_unlocked(runtime, ORIGIN), "return: origin's mansion is no longer LOCKED after the round trip")
	return _failures.size() == start


# Re-cross + the v5 ROUND TRIP: north again (the chained fence still standing — no
# reset), then save -> reload mid-chain: the active world is (0,-1), origin's fence
# rides chained_worlds["0,0"].structures, the chained fence rides the active v4-seat
# structures key, both puzzle states survive, the beacon stays an active way-stone.
func run_save_case(runtime) -> bool:
	var start: int = _failures.size()
	var info: Dictionary = _checks.cross(runtime, EDGE_NORTH, NORTH, "surf", "re_cross")
	var result: Dictionary = info["result"]
	if bool(result.get("ok", false)):
		_ensure(str(result.get("chain", "")) == "0,-1", "save: the re-cross entered %s, expected 0,-1" % str(result.get("chain", "")))
		_ensure(not bool(result.get("newly_generated", false)), "save: the chained world re-derived FRESHLY on the re-cross (persisted edits lost)")
	chained_stood = _placed(runtime, chained_fence)
	_ensure(chained_stood, "save: the chained fence %s did not survive return + re-cross" % str(chained_fence))
	_ensure(runtime.session.campsite_tile == chained_campsite, "save: the chained campsite anchor was not restored on the re-cross")
	var payload: Dictionary = _runner.save_and_reload(_world(), runtime)
	if not _ensure(not payload.is_empty(), "save: the mid-chain save failed to reload"):
		return false
	_ensure(str(runtime.session.active_chain) == "0,-1" and runtime.get_world_seed() == WorldChain.world_seed_for(int(runtime.session.root_seed), CHAINED), "save: the reload lost the active chain/seed (%s, %d)" % [str(runtime.session.active_chain), runtime.get_world_seed()])
	var chained_worlds: Variant = payload.get("chained_worlds", {})
	var origin_entry: Variant = (chained_worlds as Dictionary).get("0,0", {}) if chained_worlds is Dictionary else {}
	_ensure(_key((origin_entry as Dictionary).get("structures", {}) if origin_entry is Dictionary else {}, _checks.origin_fence), "save: origin's fence did not ride chained_worlds[\"0,0\"].structures")
	_ensure(_placed(runtime, chained_fence), "save: the chained fence did not ride the active world's structures key")
	_ensure(_checks.seam_unlocked(runtime, CHAINED) and not _checks.seam_unlocked(runtime, ORIGIN), "save: the per-world puzzle states did not survive the round trip")
	_ensure(runtime.field_move_runtime.is_way_stone(beacon_tile), "save: the chained beacon is no longer a way-stone of the ACTIVE world")
	return _failures.size() == start


# The CROSS-WORLD BAN: back in origin, the chained beacon is NOT a way-stone of the
# active world (the registry reads the ACTIVE world's placements — a beacon list never
# spans worlds by construction, fresh-faq.md:186). Inland, so edge suppression cannot
# mask the cross-world refusal.
func run_crossworld_case(runtime) -> bool:
	var start: int = _failures.size()
	var info: Dictionary = _checks.cross(runtime, EDGE_SOUTH, SOUTH, "surf", "final_return")
	var result: Dictionary = info["result"]
	_ensure(bool(result.get("ok", false)) and str(result.get("chain", "")) == "0,0", "crossworld: the final return to origin failed (%s)" % str(result.get("reason", "")))
	if bool(result.get("ok", false)): # R7: the post-reload return must restore the ARCHIVED origin (run_save_case reloaded mid-chain), never a fresh re-derive
		_ensure(not bool(result.get("newly_generated", true)), "crossworld: origin re-derived FRESH after save+reload (the chained_worlds archive was lost on apply — :184)")
		_ensure(_checks.origin_fence != Vector2i.MAX and str((runtime._world_gen.placements_for_save() as Dictionary).get("%d,%d" % [_checks.origin_fence.x, _checks.origin_fence.y], {}).get("structure_id", "")) == "fence", "crossworld: the origin fence %s did not stand with structure_id 'fence' after the post-reload return" % str(_checks.origin_fence))
	_runner.teleport_player(_world(), _player(), runtime, ORIGIN)
	var cursor: int = _runner.trace_log_line_count()
	var refused: Dictionary = runtime.field_move_runtime.use_teleport(beacon_tile)
	_ensure(str(refused.get("reason", "")) == "no_way_stone", "crossworld: teleport to the chained beacon returned %s, expected no_way_stone" % str(refused.get("reason", "")))
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"reason": "no_way_stone"}), "crossworld: no field_move_refused{no_way_stone}")
	return _failures.size() == start


# CONTROL (spec :113(2)): N generate_wild_encounter draws with landmark scope INERT
# (a tile OUTSIDE every footprint — the token is "") re-pin the identical sequence:
# the token scope provably narrows ONLY inside footprints (the shared _rng is untouched
# by the chaining swap — no reseed, no new consumption pattern).
func run_control_case(runtime) -> bool:
	var start: int = _failures.size()
	var tile := _inert_tile(runtime)
	if not _ensure(tile != Vector2i.MAX, "control: no clean non-footprint encounter tile near origin"):
		return false
	var biome := str(runtime._world_gen.get_tile_logic(tile).get("biome", ""))
	runtime.seed_for_smoke(CONTROL_SEED)
	var draws_a: Array = _probe.draw_sequence(runtime, tile, biome, CONTROL_DRAWS)
	runtime.seed_for_smoke(CONTROL_SEED)
	var draws_b: Array = _probe.draw_sequence(runtime, tile, biome, CONTROL_DRAWS)
	runtime.seed_for_smoke(CONTROL_SEED + 1) # leave the stream on a known pin (the overworld_mons precedent)
	_ensure(draws_a == draws_b and not draws_a.is_empty(), "control: the inert-scope wild draws diverge across the re-pin (the swap perturbed the open stream)")
	return _failures.size() == start


# --- helpers ------------------------------------------------------------------------
func _inert_tile(runtime) -> Vector2i:
	for radius in range(0, 8):
		for tile in _runner.ring_around(ORIGIN, radius):
			var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and bool(logic.get("encounter", false)) and str(logic.get("encounter_token", "")) == "" and str(logic.get("landmark_id", "")) == "" and str(logic.get("requires_field_move", "")) == "":
				return tile
	return Vector2i.MAX


func _placed(runtime, tile: Vector2i) -> bool:
	return tile != Vector2i.MAX and _key(runtime._world_gen.placements_for_save(), tile)


func _key(structures: Variant, tile: Vector2i) -> bool:
	return structures is Dictionary and (structures as Dictionary).has("%d,%d" % [tile.x, tile.y])


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
