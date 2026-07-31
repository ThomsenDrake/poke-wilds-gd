extends Node

# World chain scenario CHECKS, part 3 (Phase 7 audit R8; world-depth.md § World chaining
# §66 crossing deposit + fresh-faq.md § Teleport Beacons). Extracted at the app 220 wall —
# parts 1 (world_chain_checks.gd) + 2 (world_chain_persist_checks.gd) are FULL — wiring the
# cross-method DUALITY the audit folded together: (1) the crossing DEPOSIT position (spec §66:
# manhattan WORLD_RADIUS-2 on the half-ring OPPOSITE the travel direction, water-adjacent for
# a surf cross) which try_cross_edge returns but no case asserted; (2) a FLY cross through the
# PRODUCTION movement gate (player_avatar._try_start_step selects fly at a non-water edge) +
# the negative control that a surf-only party at a dry edge is REFUSED by that gate (the
# method-vs-terrain validation try_cross_edge itself never performs); (3) a SECOND cardinal
# (east) cross to pin adjacent_chain symmetry beyond the north/south loop; (4) use_fly's
# edge_suppressed sibling gate (the teleport_suppressed predicate refuses fly-to-beacon at the
# edge band, mirroring use_teleport). The scripted crosses ride part 1's cross() (a warp); the
# production cases drive _try_start_step. Domain access rides the runtime re-exports. miss-002.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldChainChecks := preload("res://scripts/app/world_chain_checks.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")
# Domain access rides the runtime re-exports (the app layer may not reach domain directly).
const WorldChain := WorldChainChecks.WorldChain

const NORTH := WorldChainChecks.NORTH
const EAST := Vector2i.RIGHT
const WEST := Vector2i.LEFT
const EDGE_NORTH := WorldChainChecks.EDGE_NORTH
const EDGE_EAST := Vector2i(95, 0) # manhattan 95 == WORLD_RADIUS - 1: at_edge
const EDGE_WEST := Vector2i(-95, 0)
const DEPOSIT_RING := WorldChain.WORLD_RADIUS - 2 # 94: the crossing deposit's manhattan ring (spec §66)

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _checks = null # the part-1 instance: cross() + the shared helpers


func setup(ctx: Dictionary, runner, failures: Array, checks: WorldChainChecks) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _checks = checks


# The crossing DEPOSIT (spec §66): a scripted surf north cross lands on the half-ring
# OPPOSITE the travel direction (north -> south, y >= 0) at manhattan WORLD_RADIUS - 2, and a
# surf deposit is water-adjacent. try_cross_edge returns the tile; this is the first witness
# of its POSITION (the existing first_cross case asserts the identity swap, not the geometry).
func run_deposit_case(runtime) -> bool:
	var start: int = _failures.size()
	var info: Dictionary = _checks.cross(runtime, EDGE_NORTH, NORTH, "surf", "deposit")
	var result: Dictionary = info["result"]
	if bool(result.get("ok", false)):
		var tile: Vector2i = result.get("tile", Vector2i.MAX)
		_ensure(WorldChain.distance(tile) == DEPOSIT_RING, "deposit: the surf crossing landed at manhattan %d, expected %d (spec §66)" % [WorldChain.distance(tile), DEPOSIT_RING])
		_ensure(tile.y >= 0, "deposit: a NORTH crossing deposited on the north half-ring %s (expected the OPPOSITE, south, half-ring)" % str(tile))
		_ensure(_water_adjacent(runtime, tile), "deposit: the surf crossing deposit %s is not water-adjacent (a surf cross seeks a water-adjacent tile)" % str(tile))
	_checks.cross(runtime, Vector2i(0, 95), Vector2i.DOWN, "surf", "deposit_return") # housekeeping: surf SOUTH from (0,-1)'s south edge -> back to origin (0,0), the avatar_return pattern (a NORTH re-cross round-trips to (0,-1) and leaks the active chain into the fly/cardinal cases)
	return _failures.size() == start


# The FLY cross through the PRODUCTION movement gate: at a non-water edge the all-moves party's
# pressed step selects fly (_edge_cross_method: surf needs water, else fly) -> world_edge_crossed
# {method:fly} + world_chained. NEGATIVE CONTROL: a surf-ONLY party at the same dry edge is
# REFUSED by the gate (no water for surf, no fly -> the step leaves the disc -> traversal_blocked
# {world_edge}, NO world_edge_crossed{method:surf}) — the method-vs-terrain validation
# try_cross_edge itself never performs.
func run_fly_cross_case(runtime) -> bool:
	var start: int = _failures.size()
	var edge: Dictionary = _dry_edge(runtime)
	if not _ensure(not edge.is_empty(), "fly: no dry walkable cardinal edge tile within the scan (the production fly cross needs a non-water edge)"):
		return false
	var stand: Vector2i = edge["stand"]; var direction: Vector2i = edge["direction"]
	var party_before: Array = FieldMovesParty.swap_in(runtime) # surf + fly (the gate picks fly at a dry edge)
	_runner.teleport_player(_world(), _player(), runtime, stand)
	var cursor: int = _runner.trace_log_line_count()
	_player()._try_start_step(direction) # the REAL movement gate: dry edge -> fly
	_ensure(_runner.trace_log_has_since("world_edge_crossed", cursor, {"method": "fly"}), "fly: no world_edge_crossed{method:fly} from a pressed step at the dry edge %s" % str(stand))
	_ensure(_runner.trace_log_has_since("world_chained", cursor, {"method": "fly"}), "fly: no world_chained{method:fly} via the production movement path")
	FieldMovesParty.restore(runtime, party_before)
	_checks.cross(runtime, edge["return_edge"], edge["return_dir"], "fly", "fly_return") # housekeeping: scripted return to origin
	# NEGATIVE CONTROL: surf-only party at the same dry edge -> the gate refuses the cross.
	var surf_party: Array = _runner.swap_party(runtime, ["RHYPERIOR"], FieldMovesParty.PARTY_LEVEL) # surf, NO fly
	_runner.teleport_player(_world(), _player(), runtime, stand)
	var cursor2: int = _runner.trace_log_line_count()
	_player()._try_start_step(direction) # surf needs water; the dry edge has none and there is no fly -> no cross
	_ensure(not _runner.trace_log_has_since("world_edge_crossed", cursor2, {"method": "surf"}), "fly: a surf-only party crossed with method:surf at the DRY edge %s (the movement gate skipped method-vs-terrain)" % str(stand))
	_ensure(_runner.trace_log_has_since("traversal_blocked", cursor2, {"reason": "world_edge"}), "fly: the surf-only party at the dry edge was not refused by the movement gate (no traversal_blocked{world_edge})")
	_runner.restore_party(runtime, surf_party)
	return _failures.size() == start


# A SECOND cardinal direction (east) to pin adjacent_chain symmetry: a scripted east cross
# enters (1,0) (adjacent_chain((0,0), EAST)), complementing the north/south loop.
func run_cardinal_cross_case(runtime) -> bool:
	var start: int = _failures.size()
	var info: Dictionary = _checks.cross(runtime, EDGE_EAST, EAST, "fly", "cardinal_east")
	var result: Dictionary = info["result"]
	if bool(result.get("ok", false)):
		_ensure(str(result.get("chain", "")) == "1,0", "cardinal: an EAST cross entered chain %s, expected 1,0 (adjacent_chain symmetry)" % str(result.get("chain", "")))
		_ensure(_runner.trace_log_has_since("world_edge_crossed", info["cursor"], {"chain": "0,0", "direction": [1, 0], "method": "fly"}), "cardinal: no world_edge_crossed{0,0, east, fly}")
		_ensure(_runner.trace_log_has_since("world_chained", info["cursor"], {"chain": "1,0", "method": "fly"}), "cardinal: no world_chained{1,0, fly}")
	_checks.cross(runtime, EDGE_WEST, WEST, "fly", "cardinal_return") # housekeeping: west from (1,0)'s west edge -> back to (0,0)
	return _failures.size() == start


# use_fly's edge_suppressed sibling gate: fly-to-beacon is a teleport-class warp, so the
# teleport_suppressed predicate refuses it at the edge band (mirrors use_teleport's gate in
# part 2's run_beacon_case). Standing ON the edge band, use_fly refuses edge_suppressed +
# field_move_refused{edge_suppressed} — BEFORE any target validity check.
func run_fly_suppression_case(runtime) -> bool:
	var start: int = _failures.size()
	var party_before: Array = FieldMovesParty.swap_in(runtime) # fly-capable
	_runner.teleport_player(_world(), _player(), runtime, EDGE_NORTH) # manhattan 95 >= 88: inside the suppression band
	var cursor: int = _runner.trace_log_line_count()
	var refused: Dictionary = runtime.field_move_runtime.use_fly(EDGE_NORTH)
	_ensure(str(refused.get("reason", "")) == "edge_suppressed", "fly_suppress: use_fly at the edge returned %s, expected edge_suppressed" % str(refused.get("reason", "")))
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"reason": "edge_suppressed"}), "fly_suppress: no field_move_refused{edge_suppressed} for use_fly at the edge band")
	FieldMovesParty.restore(runtime, party_before)
	_runner.teleport_player(_world(), _player(), runtime, WorldChainChecks.ORIGIN)
	return _failures.size() == start


# --- helpers ------------------------------------------------------------------------
# A dry walkable cardinal edge tile (stand at manhattan 95, the outward neighbor non-water):
# the production fly cross's precondition (surf needs water; a dry edge selects fly). Returns
# {stand, direction, return_edge, return_dir} for the first hit ({} when none — loud upstream).
func _dry_edge(runtime) -> Dictionary:
	var candidates := [
		{"stand": EDGE_EAST, "direction": EAST, "return_edge": EDGE_WEST, "return_dir": WEST},
		{"stand": EDGE_WEST, "direction": WEST, "return_edge": EDGE_EAST, "return_dir": EAST},
		{"stand": Vector2i(0, 95), "direction": Vector2i.DOWN, "return_edge": EDGE_NORTH, "return_dir": NORTH},
	]
	for edge in candidates:
		var stand: Vector2i = edge["stand"]; var next: Vector2i = stand + edge["direction"]
		if bool(_world().get_tile_logic(stand).get("walkable", false)) and _world().get_tile_biome(stand) != "WATER" and _world().get_tile_biome(next) != "WATER":
			return edge
	return {}


func _water_adjacent(runtime, tile: Vector2i) -> bool:
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if _world().get_tile_biome(tile + direction) == "WATER":
			return true
	return false


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
