extends RefCounted

const IDENTITY_PATH := "user://playtest_identity.json"
const TMP_SUFFIX := ".tmp"
const IDENTITY_KEYS := ["tester_id", "invite_token", "endpoint", "channel"]
const KIND_KEY := "identity_kind"
const KIND_FRIEND := "friend"
const KIND_COHORT := "cohort"
const SHARED_CHANNEL := "playtest"

static var _path_override := ""
static var _write_fail := false


static func path() -> String:
	return IDENTITY_PATH if _path_override.is_empty() else _path_override


static func set_path_for_smoke(value: String) -> void:
	if OS.has_feature("editor"):
		_path_override = value


static func set_write_fail_for_smoke(fail: bool) -> void:
	if OS.has_feature("editor"):
		_write_fail = fail


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
	var kind := str((parsed as Dictionary).get(KIND_KEY, "")).strip_edges()
	if kind == KIND_FRIEND or kind == KIND_COHORT:
		out[KIND_KEY] = kind
	return out


static func persist_from(embedded: Dictionary) -> bool:
	if str(embedded.get("invite_token", "")).strip_edges().is_empty():
		return true
	var stored := load_identity()
	if _is_friend_identity(stored) or _same_route(stored, embedded):
		return true
	var payload := {}
	for key in IDENTITY_KEYS:
		var text := str(embedded.get(key, "")).strip_edges()
		if text.is_empty():
			return false
		payload[key] = text
	payload[KIND_KEY] = _identity_kind(embedded)
	return _write(payload)


static func merge(embedded: Dictionary, persisted: Dictionary = {}) -> Dictionary:
	var out := embedded.duplicate(true)
	var stored := persisted if not persisted.is_empty() else load_identity()
	if stored.is_empty():
		return out
	var embed_token := str(embedded.get("invite_token", "")).strip_edges()
	var embed_endpoint := str(embedded.get("endpoint", "")).strip_edges()
	if embed_token.is_empty() and embed_endpoint.is_empty():
		return out
	if _is_friend_identity(stored) or embed_token.is_empty():
		for key in IDENTITY_KEYS:
			out[key] = stored[key]
	return out


static func _identity_kind(record: Dictionary) -> String:
	var kind := str(record.get(KIND_KEY, "")).strip_edges()
	if kind == KIND_FRIEND or kind == KIND_COHORT:
		return kind
	if str(record.get("channel", "")).strip_edges() != SHARED_CHANNEL:
		return KIND_FRIEND
	return KIND_COHORT


static func _is_friend_identity(stored: Dictionary) -> bool:
	return not stored.is_empty() and _identity_kind(stored) == KIND_FRIEND


static func _same_route(stored: Dictionary, embedded: Dictionary) -> bool:
	if stored.is_empty():
		return false
	for key in IDENTITY_KEYS:
		if str(stored.get(key, "")).strip_edges() != str(embedded.get(key, "")).strip_edges():
			return false
	return true


static func _write(payload: Dictionary) -> bool:
	if _write_fail:
		return false
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
