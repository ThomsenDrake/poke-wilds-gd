extends RefCounted

const REQUEST_PATH := "res://.godot-smoke/scenario.json"


func consume_requested_scenario() -> String:
	if not FileAccess.file_exists(REQUEST_PATH):
		return ""
	var file = FileAccess.open(REQUEST_PATH, FileAccess.READ)
	if file == null:
		return ""
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	_cleanup_request_file()
	if parsed is Dictionary:
		return str(parsed.get("scenario", ""))
	return ""


func _cleanup_request_file() -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
