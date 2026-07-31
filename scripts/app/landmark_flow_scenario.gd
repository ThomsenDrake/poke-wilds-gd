extends Node

# Landmark flow scenario (Phase 7 Build 1; spec: docs/product-specs/world-depth.md
# § Smoke validation). Fixed seed 2026072907 (spec § Pinned constants), ORIGIN world:
# WALKS in through the Mansion entry into the open courtyard (landmark_entered
# {first_entry: true}), picks up the mansion_key at the courtyard journal table, turns
# it on the room door (key_item_used) and WALKS through it, toggles the three statues
# -> puzzle_state_changed {solved: true} on the third, and WALKS through the sewer door
# into the sewer region. Every traversal step is WITNESSED walkable under the resolver
# BEFORE the avatar moves — teleport is the headless STAGING transport only, never a
# region hop (a sealed door / walled-off region reds HERE, which a teleport could not
# catch). The encounter-scope pool proofs, the ruins outer/inner/underground asserts,
# the tower footprint+entry, footprint protection, and the seam round-trip ride
# world_depth_checks.gd (app-budget split). Every tile DERIVES from
# Landmarks.landmarks_in_world (never hardcoded). Joins the double-run lane: drives
# the shared encounter stream + world state. miss-002: symmetric markers; a red always
# names its cause — and a skipped case names its cascade.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const WorldDepthChecks := preload("res://scripts/app/world_depth_checks.gd")
const LandmarkGuardianChecks := preload("res://scripts/app/landmark_guardian_checks.gd") # R2: the guardian forced-battle +3 witness (extracted at the app 220 wall)
# Domain access rides the runtime's own preload (the app layer may not preload
# domain directly — check_architecture.gd's layer table).
const Landmarks := LandmarkRuntime.Landmarks

const SEED := 2026072907
const ORIGIN := Vector2i.ZERO # Build 1: the origin world (any-world asserts ride world_chain)
const DAY_MINUTES := 600 # DAY pools for the scope asserts (nocturnal ghosts never perturb them)
const STATUE_LOCALS := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7)] # Landmarks._M_STATUE_TILES (private; the spec's locals)
const ROOM_DOOR_LOCAL := Vector2i(7, 5) # landmark_runtime.ROOM_DOOR_LOCAL (private const)
const SEWER_DOOR_LOCAL := Vector2i(4, 5) # landmark_runtime.SEWER_DOOR_LOCAL (private const)
const ENTRY_LOCAL := Vector2i(6, 0) # Landmarks._M_SPECIAL entry (private): the north opening into the open courtyard

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _mansion_origin := Vector2i.ZERO # footprint.position: the world-space local origin


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the root_seed draw too (the save_stability precedent; the double-run lane reds without it)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the breed_flow precedent)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	# The runtime's session-scoped first_entry/loot memory survives new_game (no reset
	# hook yet — a Build-3 candidate); the scenario IS a new session, so clearing keeps
	# the first-entry witnesses deterministic under any double-run group ordering.
	runtime.landmark_runtime._visited.clear(); runtime.landmark_runtime._loot_taken.clear()
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # the scope draws are explicit generate_wild_encounter calls, never step triggers
	_oks["mansion_ok"] = _walk_the_mansion(runtime)
	if _failures.is_empty():
		_oks["loot_ok"] = _loot_case(runtime) # R9: the courtyard loot shelf grant + one-shot (interact_loot's _loot_taken)
	if _failures.is_empty():
		_oks["puzzle_ok"] = _solve_the_statues(runtime)
	else:
		_failures.append("skipped: puzzle (cascaded from an earlier mansion red)")
	if _failures.is_empty():
		var checks := WorldDepthChecks.new(); add_child(checks); checks.setup(_ctx, _runner, _failures, _mansion_origin)
		_oks["mansion_pool_ok"] = checks.run_mansion_pool_case(runtime)
		_oks["ruins_ok"] = checks.run_ruins_case(runtime)
		_oks["guardian_ok"] = LandmarkGuardianChecks.run_guardian_battle_case(runtime, _runner, _failures, _ctx) # R2: the guardian's defining +3 (the entity persists from run_ruins_case)
		_oks["tower_ok"] = checks.run_tower_case(runtime)
		_oks["save_ok"] = checks.run_save_roundtrip_case(runtime)
	else:
		_failures.append("skipped: mansion_pool/ruins/tower/save (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("landmark_flow_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("landmark_flow_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("LandmarkFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("LandmarkFlowScenario", "Landmark flow failed.", {})
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES


# Entry + key + door: a WITNESSED walk from OUTSIDE the footprint through the entry into
# the open courtyard (the landmark_entered first-entry witness — never a courtyard
# teleport), the mansion_key pickup at the courtyard journal table, its turn on the room
# door (key_item_used), and the door overlay's walkability read through the resolver.
func _walk_the_mansion(runtime) -> bool:
	var start: int = _failures.size()
	var mansion := _landmark(runtime, Landmarks.MANSION_ID)
	if mansion.is_empty():
		_failures.append("mansion: landmarks_in_world(seed, (0,0)) derives no pkmn_mansion footprint")
		return false
	_mansion_origin = (mansion["footprint"] as Rect2i).position
	_runner.teleport_player(_world(), _player(), runtime, _mansion_origin + ENTRY_LOCAL + Vector2i(0, -1)) # STAGING only: one tile OUTSIDE the footprint, north of the entry
	var cursor: int = _runner.trace_log_line_count()
	if not _walk(runtime, [_mansion_origin + ENTRY_LOCAL, _mansion_origin + ENTRY_LOCAL + Vector2i(0, 1)], "mansion entry"):
		return false
	_ensure(_runner.trace_log_has_since("landmark_entered", cursor, {"landmark_id": Landmarks.MANSION_ID, "region": "courtyard", "first_entry": true}), "mansion: no landmark_entered{pkmn_mansion,courtyard,first_entry}")
	var key_result: Dictionary = runtime.landmark_runtime.interact_journal(_mansion_origin + Landmarks.MANSION_KEY_TABLE_TILE)
	_ensure(bool(key_result.get("handled", false)) and runtime.session.get_item_count(Landmarks.MANSION_KEY_ID) == 1, "mansion: the key-table pickup did not bag mansion_key (%s)" % str(key_result.get("message", "")))
	_ensure(not bool(runtime._world_gen.get_tile_logic(_mansion_origin + ROOM_DOOR_LOCAL).get("walkable", false)), "mansion: the room door is open BEFORE key use (gating bypassed)")
	var door_cursor: int = _runner.trace_log_line_count()
	var door_result: Dictionary = runtime.landmark_runtime.use_key_at(_mansion_origin + ROOM_DOOR_LOCAL)
	_ensure(bool(door_result.get("handled", false)), "mansion: the room door key arm was not handled")
	_ensure(_runner.trace_log_has_since("key_item_used", door_cursor, {"item_id": Landmarks.MANSION_KEY_ID, "landmark_id": Landmarks.MANSION_ID}), "mansion: no key_item_used{mansion_key} on the room door")
	_ensure(runtime.session.get_item_count(Landmarks.MANSION_KEY_ID) == 0, "mansion: the room door did not consume mansion_key")
	var door_logic: Dictionary = runtime._world_gen.get_tile_logic(_mansion_origin + ROOM_DOOR_LOCAL)
	_ensure(bool(door_logic.get("walkable", false)) and str(door_logic.get("block_reason", "")) == "", "mansion: the room door overlay stays sealed after key use")
	return _failures.size() == start


# The three statues: a WITNESSED walk through the opened room door (a teleport could hop
# a sealed wall — each step asserts resolver walkability FIRST), toggles 0/1 click
# without solving; the third opens the basement (puzzle_state_changed {state: unlocked,
# solved: true}), the sewer door overlay flips walkable, and the crossing into the sewer
# region is a witnessed walk through the door that traces its own first entry.
func _solve_the_statues(runtime) -> bool:
	var start: int = _failures.size()
	var room_cursor: int = _runner.trace_log_line_count()
	if not _walk(runtime, [_mansion_origin + ROOM_DOOR_LOCAL, _mansion_origin + ROOM_DOOR_LOCAL + Vector2i(0, 1)], "room door crossing"):
		return false
	_ensure(_runner.trace_log_has_since("landmark_entered", room_cursor, {"landmark_id": Landmarks.MANSION_ID, "region": "room"}), "mansion: no landmark_entered{room}")
	_ensure(not bool(runtime._world_gen.get_tile_logic(_mansion_origin + SEWER_DOOR_LOCAL).get("walkable", false)), "mansion: the sewer door is open BEFORE the solve (puzzle gate bypassed)")
	var solved_cursor := -1
	for i in range(Landmarks.MANSION_STATUES):
		if i == Landmarks.MANSION_STATUES - 1:
			solved_cursor = _runner.trace_log_line_count()
		var result: Dictionary = runtime.landmark_runtime.interact_statue(_mansion_origin + STATUE_LOCALS[i])
		_ensure(bool(result.get("handled", false)), "mansion: statue %d toggle was not handled" % i)
		if i < Landmarks.MANSION_STATUES - 1 and bool(result.get("solved", false)):
			_failures.append("mansion: statue %d solved the puzzle early" % i)
	_ensure(_runner.trace_log_has_since("puzzle_state_changed", solved_cursor, {"landmark_id": Landmarks.MANSION_ID, "state": "unlocked", "solved": true}), "mansion: no puzzle_state_changed{unlocked,solved} on the third statue")
	var sewer_door_logic: Dictionary = runtime._world_gen.get_tile_logic(_mansion_origin + SEWER_DOOR_LOCAL)
	_ensure(bool(sewer_door_logic.get("walkable", false)), "mansion: the sewer door overlay stays sealed after the solve")
	var sewer_cursor: int = _runner.trace_log_line_count()
	if not _walk(runtime, [_mansion_origin + SEWER_DOOR_LOCAL, _mansion_origin + SEWER_DOOR_LOCAL + Vector2i(0, 1)], "sewer crossing"):
		return false
	_ensure(_runner.trace_log_has_since("landmark_entered", sewer_cursor, {"landmark_id": Landmarks.MANSION_ID, "region": "sewer", "first_entry": true}), "mansion: no landmark_entered{sewer,first_entry} after the crossing")
	return _failures.size() == start


# The courtyard loot shelf (R9; FLAGGED #11): Z on the DERIVED MANSION_LOOT_TILE grants exactly
# one MANSION_LOOT_BALL_ID, and a second Z is a one-shot no-op (interact_loot's session-scoped
# _loot_taken, cleared at scenario start). No scenario triggered interact_loot before this, so a
# regression dropping the grant OR the one-shot passed green.
func _loot_case(runtime) -> bool:
	var start: int = _failures.size()
	var loot_tile: Vector2i = _mansion_origin + Landmarks.MANSION_LOOT_TILE
	var before: int = runtime.session.get_item_count(Landmarks.MANSION_LOOT_BALL_ID)
	var first: Dictionary = runtime.landmark_runtime.interact_loot(loot_tile)
	_ensure(bool(first.get("handled", false)), "loot: Z on the mansion loot shelf %s was not handled" % str(loot_tile))
	_ensure(runtime.session.get_item_count(Landmarks.MANSION_LOOT_BALL_ID) == before + 1, "loot: the bag did not gain exactly one %s (%d -> %d)" % [Landmarks.MANSION_LOOT_BALL_ID, before, runtime.session.get_item_count(Landmarks.MANSION_LOOT_BALL_ID)])
	var second: Dictionary = runtime.landmark_runtime.interact_loot(loot_tile)
	_ensure(bool(second.get("handled", false)) and runtime.session.get_item_count(Landmarks.MANSION_LOOT_BALL_ID) == before + 1, "loot: a second Z was not a one-shot no-op (count %d, expected %d)" % [runtime.session.get_item_count(Landmarks.MANSION_LOOT_BALL_ID), before + 1])
	return _failures.size() == start


# Witnessed traversal: each step asserts RESOLVER walkability BEFORE the avatar moves, so
# a sealed door / walled-off region reds HERE with the blocking tile + its reason — the
# region-teleport this replaced could never catch that class. Teleport is the headless
# transport; the witness is the walkability read the real movement gate rides.
func _walk(runtime, path: Array, label: String) -> bool:
	for tile in path:
		var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
		if not _ensure(bool(logic.get("walkable", false)), "%s: path tile %s is sealed (%s)" % [label, str(tile), str(logic.get("block_reason", ""))]):
			return false
		_runner.teleport_player(_world(), _player(), runtime, tile)
		runtime.note_player_step()
	return true


# The footprint of one landmark, derived off the live seed (NEVER hardcoded tiles).
func _landmark(runtime, landmark_id: String) -> Dictionary:
	for landmark in Landmarks.landmarks_in_world(runtime.get_world_seed(), ORIGIN):
		if str(landmark["landmark_id"]) == landmark_id:
			return landmark
	return {}


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
