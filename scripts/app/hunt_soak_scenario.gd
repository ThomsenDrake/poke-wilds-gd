extends Node

# Unattended windowed hunt: shared climb-out, then held-key soak toward
# off-fixture tiles. Coded keeps are quarantine-tier. Not a verify_all lane.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const PlayAgentClimb := preload("res://scripts/app/play_agent_climb.gd")
const HuntNav := preload("res://scripts/app/hunt_nav.gd")
const HuntClipKeep := preload("res://scripts/app/hunt_clip_keep.gd")

const STEP_HOLD_FRAMES := 30
const DEFAULT_MINUTES := 15
const STUCK_STEPS := 8

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _nav := HuntNav.new()
var _keeps := HuntClipKeep.new()
var _visited: Dictionary = {}
var _stuck := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true
	_player().input_enabled = false
	_runtime().seed_for_smoke(PlayAgentClimb.PIN)
	await PlayAgentClimb.new().drive(self, _ctx, _runner, _failures)
	if not _failures.is_empty():
		_restore()
		return
	_keeps.begin_run(_runtime())
	var deadline: int = Time.get_ticks_msec() + _budget_ms()
	while Time.get_ticks_msec() < deadline:
		if not await _hunt_step():
			_stuck += 1
			if _stuck >= STUCK_STEPS:
				break
		else:
			_stuck = 0
	_keeps.finish(_runtime())
	_restore()


func _hunt_step() -> bool:
	var player := _player()
	var world := _world()
	var direction: Vector2i = _nav.pick_direction(world, player, _runtime(), _visited)
	if direction == Vector2i.ZERO:
		return false
	var action := _direction_action(direction)
	var from_tile: Vector2i = player.tile_position
	var warp_cursor: int = _runner.trace_log_line_count()
	if not SmokeTap.inject_press(action):
		return false
	var started := false
	for _i in range(STEP_HOLD_FRAMES):
		await get_tree().process_frame
		if player.is_moving():
			started = true
			break
	SmokeTap.inject_release(action)
	if not started:
		return false
	await player.tile_changed
	player.input_enabled = false
	var landed: Vector2i = player.tile_position
	var key := "%d,%d" % [landed.x, landed.y]
	_visited[key] = int(_visited.get(key, 0)) + 1
	_runtime().emit_trace("overworld_step", "HuntSoak", {"tile": [landed.x, landed.y], "from_tile": [from_tile.x, from_tile.y], "steps": 1})
	var place := {"tile": [landed.x, landed.y], "seed": _runtime().get_world_seed()}
	if _keeps.note_step(_runtime(), world, player) > 0:
		await _keeps.keep_coded(self, _runtime(), _viewport(), "spatial_overlap", place)
	if _warp_stamp_bad(warp_cursor, landed):
		await _keeps.keep_coded(self, _runtime(), _viewport(), "warp_stamp", place)
	await _keeps.maybe_cadence_still(self, _runtime(), _viewport(), place)
	return landed != from_tile


func _warp_stamp_bad(cursor: int, landed: Vector2i) -> bool:
	if not _runner.trace_log_has_since("dungeon_entered", cursor):
		return false
	return not _runner.trace_log_has_since("dungeon_entered", cursor, {"tile": [landed.x, landed.y]})


func _budget_ms() -> int:
	var minutes: int = DEFAULT_MINUTES
	var path := "res://.godot-smoke/hunt-request.json"
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary and parsed.has("minutes"):
				minutes = maxi(1, int(parsed["minutes"]))
	return minutes * 60 * 1000


func _restore() -> void:
	Input.use_accumulated_input = false
	_player().input_enabled = true
	_title().hide_screen()
	_creation().close_screen()


static func _direction_action(direction: Vector2i) -> String:
	match direction:
		Vector2i.UP: return "move_up"
		Vector2i.DOWN: return "move_down"
		Vector2i.LEFT: return "move_left"
		_: return "move_right"


func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _viewport() -> Viewport: return _ctx.get("viewport", get_viewport())
