extends Node

# Optional closed-loop play scenario. Polls agent_command.json, applies
# SmokeTap / F / observe, writes agent_observation.json. Never emits play_agent_passed.

const AgentStepReader := preload("res://scripts/runtime/agent_step_reader.gd")
const LoopDrive := preload("res://scripts/app/play_agent_loop_drive.gd")
const UiTreeDumpWriter := preload("res://scripts/app/ui_tree_dump_writer.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const FILE_HELPER_PATH := "res://scripts/app/play_agent_loop_file.gd"
const PIN := 2026080701
const TURN_BUDGET := 96
const POLL_S := 0.05
const IDLE_S := 45.0
const WALL_S := 180.0
const LINGER_S := 0.55

var _ctx: Dictionary = {}
var _runner: SmokeScenarioRunner = SmokeScenarioRunner.new()
var _failures: Array = []
var _drive: Node
var _turns := 0
var _stuck_hits := 0
var _last_place := ""
var _booted := false
var _trace_from := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	process_mode = Node.PROCESS_MODE_ALWAYS
	if DisplayServer.get_name() == "headless":
		_runtime().emit_trace("play_agent_loop_started", "PlayAgentLoop", {"pin": PIN})
		_failures.append("play_agent_loop requires a windowed transport")
		_finish()
		return
	await get_tree().create_timer(0.2).timeout
	Engine.max_fps = 60
	Input.use_accumulated_input = true
	_player().input_enabled = false
	_runtime().seed_for_smoke(PIN)
	_drive = LoopDrive.new()
	add_child(_drive)
	_drive.setup(_ctx, _runner, _failures)
	_trace_from = _runner.trace_log_line_count()
	_runtime().emit_trace("play_agent_loop_started", "PlayAgentLoop", {"pin": PIN})
	var origin := Time.get_ticks_msec()
	var idle_at := origin
	var quit_seen := false
	while _turns < TURN_BUDGET and Time.get_ticks_msec() - origin < int(WALL_S * 1000.0):
		var consumed: Dictionary = AgentStepReader.consume_command()
		if consumed.is_empty():
			if Time.get_ticks_msec() - idle_at > int(IDLE_S * 1000.0) and _turns > 0:
				_failures.append("command idle timeout")
				break
			await get_tree().create_timer(POLL_S).timeout
			continue
		idle_at = Time.get_ticks_msec()
		await _apply(consumed)
		if str((consumed.get("command", {}) as Dictionary).get("action", "")) == "quit":
			quit_seen = true
			break
	if _turns >= TURN_BUDGET and not quit_seen:
		_failures.append("turn budget exhausted")
	_restore()
	_finish()


func _apply(consumed: Dictionary) -> void:
	var command: Dictionary = consumed.get("command", {})
	var command_id := str(command.get("id", ""))
	var action := str(command.get("action", ""))
	var payload: Dictionary = command.get("payload", {})
	var feedback = null
	if not bool(consumed.get("ok", false)):
		_failures.append(str(consumed.get("error", "invalid_command")))
		await _publish(command_id, action, payload, feedback)
		return
	match action:
		"boot_new_game":
			if not _booted:
				await _drive.boot_new_game()
				_booted = true
		"press":
			await _drive.apply_press(str(payload.get("input", "")))
		"hold":
			await _drive.apply_hold(str(payload.get("input", "")))
		"observe":
			pass
		"file_feedback":
			feedback = await _file(payload)
		"quit":
			pass
	if action != "boot_new_game" and action != "quit":
		await get_tree().create_timer(LINGER_S).timeout
	_runtime().emit_trace("play_agent_step_applied", "PlayAgentLoop", {"id": command_id, "action": action})
	await _publish(command_id, action, payload, feedback)


func _file(payload: Dictionary) -> Dictionary:
	if not ResourceLoader.exists(FILE_HELPER_PATH):
		_runtime().emit_trace("play_agent_file_skipped", "PlayAgentLoop", {"reason": "filing_helper_missing"})
		return {"status": "blocked", "reason": "filing_helper_missing", "issue_number": 0}
	var helper: Node = (load(FILE_HELPER_PATH) as Script).new()
	add_child(helper)
	var result: Dictionary = await helper.file_feedback(_ctx, payload)
	helper.queue_free()
	if str(result.get("status", "")) == "blocked":
		_runtime().emit_trace("play_agent_file_skipped", "PlayAgentLoop", {"reason": str(result.get("reason", ""))})
	return result


func _publish(command_id: String, action: String, payload: Dictionary, feedback) -> void:
	var ui_tree: Dictionary = _snapshot_ui()
	AgentStepReader.write_ui_tree(ui_tree)
	var stuck := _update_stuck(action, payload)
	var exceptions := _failures.duplicate()
	var observation := AgentStepReader.build_observation(command_id, _runtime(), _player(), ui_tree, exceptions, stuck, feedback, _trace_from, _world())
	if stuck or not exceptions.is_empty() or _tail_has_failed(observation.get("trace_tail", [])):
		_runtime().emit_trace("play_agent_anomaly_observed", "PlayAgentLoop", {"command_id": command_id, "stuck": stuck})
	AgentStepReader.write_observation(observation)
	_turns += 1


func _snapshot_ui() -> Dictionary:
	var ui := _runtime().get_node_or_null("/root/Main/UI")
	var root: Node = ui if ui != null else _runtime()
	return UiTreeDumpWriter.snapshot_screen("loop", root, {})


func _update_stuck(action: String, payload: Dictionary) -> bool:
	if not AgentStepReader.is_movement(action, payload):
		return _stuck_hits >= 8
	var place := "%s|%s" % [str(AgentStepReader.monitors_for(_runtime()).get("game/current_screen", "")), str(AgentStepReader.tile_payload(_player()))]
	if place == _last_place:
		_stuck_hits += 1
	else:
		_stuck_hits = 1
		_last_place = place
	return _stuck_hits >= 8


func _tail_has_failed(tail: Array) -> bool:
	for record in tail:
		if record is Dictionary and str(record.get("event", "")).ends_with("_failed"):
			return true
	return false


func _finish() -> void:
	if _failures.is_empty():
		_runtime().emit_trace("play_agent_loop_passed", "PlayAgentLoop", {"turns": _turns, "pin": PIN})
	else:
		_runtime().emit_trace("play_agent_loop_failed", "PlayAgentLoop", {"failures": _failures, "turns": _turns, "seed": PIN})
		push_error("PlayAgentLoop failed: %s" % "; ".join(PackedStringArray(_failures)))


func _restore() -> void:
	Input.use_accumulated_input = false
	if _player() != null:
		_player().input_enabled = true
	if _ctx.has("title_screen"):
		_title().hide_screen()
	if _ctx.has("creation_screen"):
		_creation().close_screen()


func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _world() -> Node: return _ctx.get("world") as Node
