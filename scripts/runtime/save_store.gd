extends RefCounted

# JSON save transport. Payload shape and version migration live in
# session_state.gd; this store only reads/writes the document and reports
# corrupt input. A corrupt or unparseable file yields an empty payload plus
# a warning, so callers fall back to a new game.

const SAVE_PATH := "user://godot_port_save.json"

var _trace = null


func setup(trace_logger) -> void:
	_trace = trace_logger


func load_payload() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		_warn("Could not open save file; starting fresh.")
		return {}
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	_warn("Save file was corrupt or unparseable; starting fresh.")
	return {}


func write_payload(payload: Dictionary) -> bool:
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload))
	file.close()
	return true


func _warn(message: String) -> void:
	if _trace != null:
		_trace.warning("SaveStore", message, {})
	else:
		push_warning("SaveStore: " + message)
