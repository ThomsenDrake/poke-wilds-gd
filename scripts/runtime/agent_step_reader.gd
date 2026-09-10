extends RefCounted

# File-bridge I/O for play_agent_loop. Python publishes one command; the
# engine consumes+deletes it and publishes one observation. No sockets.

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const PerformanceMonitors := preload("res://scripts/runtime/performance_monitors.gd")

const COMMAND_PATH := "res://.godot-smoke/agent_command.json"
const OBSERVATION_PATH := "res://.godot-smoke/agent_observation.json"
const UI_TREE_PATH := "res://.godot-smoke/ui_tree/loop.json"
const TRACE_PATH := "user://logs/agent_trace.jsonl"
const ACTIONS := ["boot_new_game", "press", "hold", "observe", "file_feedback", "quit"]
const INPUTS := ["move_up", "move_down", "move_left", "move_right", "action_a", "action_b", "menu"]
const MOVE_INPUTS := ["move_up", "move_down", "move_left", "move_right"]
const MESSAGE_PREFIX := "[agent-play]"
const MESSAGE_MAX := 1000
const TRACE_TAIL := 40


static func consume_command() -> Dictionary:
	if not FileAccess.file_exists(COMMAND_PATH):
		return {}
	var parsed := _read_json(COMMAND_PATH)
	_remove(COMMAND_PATH)
	if parsed.is_empty():
		return {"ok": false, "error": "invalid_json", "command": {}}
	var checked := validate_command(parsed)
	checked["command"] = parsed
	return checked


static func validate_command(doc: Dictionary) -> Dictionary:
	if str(doc.get("id", "")).is_empty():
		return {"ok": false, "error": "missing_id"}
	var action := str(doc.get("action", ""))
	if action not in ACTIONS:
		return {"ok": false, "error": "unknown_action"}
	var payload = doc.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		return {"ok": false, "error": "invalid_payload"}
	if action == "press" or action == "hold":
		if str(payload.get("input", "")) not in INPUTS:
			return {"ok": false, "error": "unknown_input"}
	if action == "file_feedback":
		var message_check := validate_message(str(payload.get("message", "")))
		if not bool(message_check.get("ok", false)):
			return message_check
	return {"ok": true, "error": ""}


static func validate_message(message: String) -> Dictionary:
	if message.is_empty():
		return {"ok": false, "error": "empty_message"}
	if message.length() > MESSAGE_MAX:
		return {"ok": false, "error": "message_too_long"}
	if not message.begins_with(MESSAGE_PREFIX):
		return {"ok": false, "error": "missing_agent_play_prefix"}
	return {"ok": true, "error": ""}


static func write_observation(doc: Dictionary) -> bool:
	return _write_json_atomic(OBSERVATION_PATH, doc)


static func write_ui_tree(snapshot: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot-smoke/ui_tree"))
	return _write_json_atomic(UI_TREE_PATH, snapshot)


static func is_movement(action: String, payload: Dictionary) -> bool:
	return (action == "press" or action == "hold") and str(payload.get("input", "")) in MOVE_INPUTS


static func monitors_for(runtime: Node) -> Dictionary:
	return {
		"game/current_screen": PerformanceMonitors.screen_label_for(runtime),
		"game/party_size": Performance.get_custom_monitor(&"game/party_size"),
		"game/world_seed": Performance.get_custom_monitor(&"game/world_seed"),
	}


static func read_trace_tail(from_line: int = 0) -> Array:
	var lines := TraceLogger.read_log_lines_since(TRACE_PATH, from_line)
	var start := maxi(0, lines.size() - TRACE_TAIL)
	var out: Array = []
	for i in range(start, lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if parsed is Dictionary:
			out.append(parsed)
	return out


static func tile_payload(player: Node) -> Variant:
	if player == null or player.get("tile_position") == null:
		return null
	var tile: Vector2i = player.tile_position
	return [tile.x, tile.y]


static func build_observation(command_id: String, runtime: Node, player: Node, ui_tree: Dictionary, exceptions: Array, stuck: bool, feedback, from_line: int = 0) -> Dictionary:
	return {
		"command_id": command_id,
		"screen": PerformanceMonitors.screen_label_for(runtime),
		"monitors": monitors_for(runtime),
		"tile": tile_payload(player),
		"trace_tail": read_trace_tail(from_line),
		"ui_tree": ui_tree,
		"exceptions": exceptions.duplicate(),
		"stuck": stuck,
		"feedback": feedback,
	}


static func _read_json(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _write_json_atomic(path: String, value: Dictionary) -> bool:
	var tmp := path + ".tmp"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value))
	file.flush()
	file.close()
	_remove(path)
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) == OK


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
