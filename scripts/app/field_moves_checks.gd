extends Node

# Phase 4 field-move checks, group A — flash / teleport+way stone / ride / fly
# (spec: docs/product-specs/field-moves.md). Companion to field_moves_flow_scenario
# (the night_cycle -> night_cycle_checks split for the app budget); group B (repel /
# power / charm+attack) lives in field_moves_ground_checks.gd. Drives the
# field_move_runtime callers through the public runtime seam (the grounding's
# preferred deterministic path — no input stack) and applies node-level effects
# (avatar warp/mount) through the runner seams. Each move asserts a HAPPY path AND
# a refusal. Seed-pinned + encounters zeroed by the orchestrator; failures accumulate
# in the shared _failures array (first-failure latch upstream).
#
# FLASH note: a Flash-capable mon is a PASSIVE whole-map light (night_system's
# _party_has_flash), so has_light_at is true wherever the all-moves party stands — a
# light DELTA is impossible with a flash mon present. The proof is a party CONTRAST
# (a non-flash mon is dark + ghost-prone; the flash party is lit + ghost-free, the
# night_cycle._check_flash pattern) PLUS the active caller's flash_lit trace + the
# night_system.active_flash_lit() seam. The passive light IS the faithful effect.

const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const WAYSTONE_ID := "way_stone" # structures.gd literal (app cannot preload domain)
const NIGHT_MINUTES := 1380
const DAY_MINUTES := 600
const DRAWS := 24
const FAR_OFFSET := Vector2i(14, 14)

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _seed := 0
var _way_stone := Vector2i.ZERO # registered by the teleport check, reused by fly


func setup(ctx: Dictionary, runner, failures: Array, seed: int) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_seed = seed


func way_stone() -> Vector2i:
	return _way_stone


# --- FLASH: dark witness -> flash party lit + ghost-free + active flash_lit ----

func check_flash() -> void:
	var runtime = _runtime()
	runtime.session.time_of_day_minutes = NIGHT_MINUTES
	runtime._world_gen.clear_placements() # crafted dark: no campfire/torch anywhere
	var dark_tile: Vector2i = runtime.session.player_tile + FAR_OFFSET
	_runner.teleport_player(_world(), _player(), runtime, dark_tile)
	_runner.swap_party(runtime, ["MACHOP"], FieldMovesParty.PARTY_LEVEL) # non-flash control
	_ensure(not runtime.night_system.has_light_at(dark_tile), "flash: the non-flash control party is already lit")
	var dark_ghosts := _count_ghosts(true)
	_runner.swap_party(runtime, FieldMovesParty.FIELD_MOVES_PARTY, FieldMovesParty.PARTY_LEVEL)
	_ensure(runtime.night_system.has_light_at(dark_tile), "flash: the flash party did not light the dark tile")
	_ensure(_count_ghosts(false) == 0, "flash: a ghost spawned under the flash party's light")
	_ensure(dark_ghosts > 0, "flash: the dark control spawned no ghost (no contrast)")
	runtime.field_move_runtime.clear_flash()
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = runtime.field_move_runtime.use_flash(dark_tile)
	_ensure(bool(result.get("ok", false)), "flash: use_flash refused for the flash party")
	_ensure(runtime.night_system.active_flash_lit(), "flash: the active Flash seam did not light")
	_ensure(_runner.trace_log_has_since("flash_lit", cursor, {"tile": [dark_tile.x, dark_tile.y]}), "flash: no flash_lit trace")
	_runner.swap_party(runtime, ["MACHOP"], FieldMovesParty.PARTY_LEVEL)
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(runtime.field_move_runtime.use_flash(dark_tile).get("ok", true)), "flash: a non-flash party used Flash")
	_ensure(not _runner.trace_log_has_since("flash_lit", cursor), "flash: flash_lit traced for a non-flash party")
	runtime.field_move_runtime.clear_flash()
	# ACTIVE-FLASH RADIUS CONTRACT (field-moves.md: "true at Manhattan 4, false at 5"):
	# under the non-Flash MACHOP party (the GLOBAL passive read is false) with placements
	# cleared, has_light_at is decided by the active branch ALONE. Arm the seam directly
	# (use_flash refuses this party) and probe the campfire-equal edge — the only window
	# where the active branch decides anything, so its radius is proven, not assumed.
	runtime.night_system.set_active_flash(true)
	_ensure(runtime.night_system.has_light_at(dark_tile), "flash: active Flash did not light the player's tile")
	_ensure(runtime.night_system.has_light_at(dark_tile + Vector2i(4, 0)), "flash: active Flash radius shorter than a campfire (dark at Manhattan 4)")
	_ensure(runtime.night_system.has_light_at(dark_tile + Vector2i(2, 2)), "flash: active Flash radius shorter than a campfire (dark at Manhattan 4 diagonal)")
	_ensure(not runtime.night_system.has_light_at(dark_tile + Vector2i(5, 0)), "flash: active Flash radius exceeds a campfire (lit at Manhattan 5)")
	_ensure(not runtime.night_system.has_light_at(dark_tile + Vector2i(3, 3)), "flash: active Flash radius exceeds a campfire (lit at Manhattan 6 diagonal)")
	runtime.night_system.set_active_flash(false)
	_ensure(not runtime.night_system.has_light_at(dark_tile), "flash: active Flash light lingered once cleared (passive read is off for MACHOP)")
	_runner.swap_party(runtime, FieldMovesParty.FIELD_MOVES_PARTY, FieldMovesParty.PARTY_LEVEL)
	runtime.session.time_of_day_minutes = DAY_MINUTES


# --- TELEPORT + WAY STONE: register -> warp to it -> it survives the save -------

func check_teleport_waystone() -> void:
	var runtime = _runtime()
	_way_stone = _find_open_tile(runtime.session.player_tile)
	if _way_stone == Vector2i.ZERO:
		_failures.append("teleport: no open tile for a way stone within scan"); return
	var cursor: int = _runner.trace_log_line_count()
	var reg: Dictionary = runtime.field_move_runtime.register_way_stone(_way_stone)
	_ensure(bool(reg.get("ok", false)), "teleport: register_way_stone refused (%s)" % str(reg.get("reason", "")))
	_ensure(_runner.trace_log_has_since("waystone_registered", cursor, {"tile": [_way_stone.x, _way_stone.y]}), "teleport: no waystone_registered trace")
	_ensure(str(_world().get_tile_logic(_way_stone).get("structure_id", "")) == WAYSTONE_ID, "teleport: the registered tile is not a way stone")
	_runner.teleport_player(_world(), _player(), runtime, runtime.session.player_tile + FAR_OFFSET)
	_ensure(_player().tile_position != _way_stone, "teleport: the player already stands on the way stone")
	cursor = _runner.trace_log_line_count()
	var warp: Dictionary = runtime.field_move_runtime.use_teleport()
	_ensure(bool(warp.get("ok", false)) and warp.get("tile") == _way_stone, "teleport: use_teleport did not target the way stone")
	_ensure(_runner.trace_log_has_since("teleport_used", cursor, {"tile": [_way_stone.x, _way_stone.y]}), "teleport: no teleport_used trace")
	_runner.teleport_player(_world(), _player(), runtime, Vector2i(warp.get("tile", _way_stone)))
	_runner.resync_player_tile(_world(), _player(), runtime)
	_ensure(_player().tile_position == _way_stone and runtime.get_player_tile() == _way_stone, "teleport: the player did not land on the way stone")
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(runtime.field_move_runtime.use_teleport(runtime.session.player_tile + Vector2i(7, 7)).get("ok", true)), "teleport: an unregistered tile accepted a teleport")
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "teleport", "reason": "no_way_stone"}), "teleport: no no_way_stone refusal trace")
	_runner.save_and_reload(_world(), runtime) # the way stone rides the structures save key
	_ensure(str(_world().get_tile_logic(_way_stone).get("structure_id", "")) == WAYSTONE_ID, "teleport: the way stone did not survive the save")


# --- RIDE: mount -> faster step mode + mount_summoned -> dismount --------------

func check_ride() -> void:
	var runtime = _runtime()
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = runtime.field_move_runtime.use_ride()
	_ensure(bool(result.get("ok", false)) and bool(result.get("riding", false)), "ride: use_ride did not mount")
	_ensure(_runner.trace_log_has_since("mount_summoned", cursor, {"species_id": "RHYPERIOR"}), "ride: no mount_summoned trace for RHYPERIOR")
	_player().set_mounted(bool(result.get("riding", false)))
	_ensure(_player().is_mounted(), "ride: the avatar is not mounted after set_mounted")
	var dir: Vector2i = _runner.find_walkable_step_direction(_world(), _player().tile_position)
	if dir != Vector2i.ZERO and _player().smoke_step(dir): # a mounted step uses the faster gait (read the duration, never a clock)
		_ensure(is_equal_approx(_player()._move_duration, _player().mount_step_seconds), "ride: a mounted step did not use the mount gait")
		_ensure(_player().mount_step_seconds < _player().run_step_seconds, "ride: the mount gait is not faster than run")
		await _player().tile_changed
	cursor = _runner.trace_log_line_count()
	var off: Dictionary = runtime.field_move_runtime.use_ride()
	_ensure(bool(off.get("ok", false)) and not bool(off.get("riding", true)), "ride: the second use_ride did not dismount")
	_player().set_mounted(false)
	_ensure(not _player().is_mounted(), "ride: the avatar stayed mounted after dismount")
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP"], FieldMovesParty.PARTY_LEVEL)
	_ensure(not bool(runtime.field_move_runtime.use_ride().get("ok", true)), "ride: a non-ride party mounted")
	_runner.restore_party(runtime, party_before)


# --- FLY: aerial travel to a VISITED way stone; refuse an unvisited tile --------

func check_fly() -> void:
	var runtime = _runtime()
	if _way_stone == Vector2i.ZERO:
		_failures.append("fly: no visited way stone (the teleport check did not register one)"); return
	_runner.teleport_player(_world(), _player(), runtime, runtime.session.player_tile + FAR_OFFSET)
	_ensure(_player().tile_position != _way_stone, "fly: the player already stands on the way stone")
	var cursor: int = _runner.trace_log_line_count()
	var flight: Dictionary = runtime.field_move_runtime.use_fly(_way_stone)
	_ensure(bool(flight.get("ok", false)) and flight.get("tile") == _way_stone, "fly: use_fly did not reach the visited way stone")
	_ensure(_runner.trace_log_has_since("fly_used", cursor, {"tile": [_way_stone.x, _way_stone.y]}), "fly: no fly_used trace")
	_runner.teleport_player(_world(), _player(), runtime, Vector2i(flight.get("tile", _way_stone)))
	_runner.resync_player_tile(_world(), _player(), runtime)
	_ensure(_player().tile_position == _way_stone, "fly: the player did not land on the way stone")
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(runtime.field_move_runtime.use_fly(_way_stone + Vector2i(5, 5)).get("ok", true)), "fly: an unvisited tile accepted a flight")
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "fly", "reason": "unvisited_way_stone"}), "fly: no unvisited_way_stone refusal trace")


# --- shared helpers -----------------------------------------------------------

func _count_ghosts(expect_hazard: bool) -> int:
	var runtime = _runtime()
	var cursor: int = _runner.trace_log_line_count()
	var biome = _world().get_tile_biome(runtime.session.player_tile)
	for _i in range(DRAWS):
		runtime.generate_wild_encounter(runtime.session.player_tile, biome)
	var hazards := count_since("night_hazard_spawned", cursor)
	if expect_hazard and hazards == 0:
		_failures.append("flash: %d dark draws spawned no shadow Ghost" % DRAWS)
	elif not expect_hazard and hazards != 0:
		_failures.append("flash: %d lit draws spawned a Ghost" % hazards)
	return hazards


func count_since(event_name: String, from_line: int) -> int:
	var file = FileAccess.open(_runner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return 0
	var lines := file.get_as_text().split("\n", false)
	file.close()
	var count := 0
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if parsed is Dictionary and str((parsed as Dictionary).get("event", "")) == event_name:
			count += 1
	return count


func _find_open_tile(center: Vector2i) -> Vector2i:
	for ring in range(2, 30):
		for tile in _runner.ring_around(center, ring):
			if _open(tile):
				return tile
	return Vector2i.ZERO


func _open(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
