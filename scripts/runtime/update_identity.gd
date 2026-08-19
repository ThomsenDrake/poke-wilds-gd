extends RefCounted

const IDENTITY_PATH := "user://playtest_identity.json"
const TMP_SUFFIX := ".tmp"
const IDENTITY_KEYS := ["tester_id", "invite_token", "endpoint", "channel"]

static var _path_override := ""


static func path() -> String:
	return IDENTITY_PATH if _path_override.is_empty() else _path_override


static func set_path_for_smoke(value: String) -> void:
	if OS.has_feature("editor"):
		_path_override = value


static func load_identity() -> Dictionary:
	if not FileAccess.file_exists(path()):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path()))
	if not parsed is Dictionary:
		return {}
	var out := {}
	for key in IDENTITY_KEYS:
		var text := str((parsed as Dictionary).get(key, "")).strip_edges()
		if text.is_empty():
			return {}
		out[key] = text
	return out


static func persist_from(embedded: Dictionary) -> bool:
	if str(embedded.get("invite_token", "")).strip_edges().is_empty():
		return true
	if not load_identity().is_empty():
		return true
	var payload := {}
	for key in IDENTITY_KEYS:
		var text := str(embedded.get(key, "")).strip_edges()
		if text.is_empty():
			return false
		payload[key] = text
	return _write(payload)


static func merge(embedded: Dictionary, persisted: Dictionary = {}) -> Dictionary:
	var out := embedded.duplicate(true)
	var stored := persisted if not persisted.is_empty() else load_identity()
	if stored.is_empty():
		return out
	for key in IDENTITY_KEYS:
		out[key] = stored[key]
	return out


static func _write(payload: Dictionary) -> bool:
	var target := path()
	var temporary := target + TMP_SUFFIX
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload, "  ") + "\n")
	file.flush()
	file.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(target))
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return false
	return true
