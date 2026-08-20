extends RefCounted

const SessionState := preload("res://scripts/runtime/session_state.gd")
const SAVE_PATH := "user://godot_port_save.json"


static func schema_version() -> int:
	return SessionState.SAVE_VERSION


static func disk_version() -> int:
	if not FileAccess.file_exists(SAVE_PATH):
		return 0
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	return int((parsed as Dictionary).get("version", 1)) if parsed is Dictionary else 0


static func can_persist(latest: Dictionary) -> bool:
	var floor := int(latest.get("min_save_version", 0))
	if schema_version() < floor:
		return false
	var disk := disk_version()
	if disk <= 0 or disk >= floor:
		return true
	var runtime := _runtime()
	return runtime != null and bool(runtime.has_loaded_save())


static func persist_migrated(latest: Dictionary) -> bool:
	if not can_persist(latest):
		return false
	var floor := int(latest.get("min_save_version", 0))
	var disk := disk_version()
	if disk <= 0 or disk >= floor:
		return true
	_runtime().save_game()
	return disk_version() >= floor


static func _runtime() -> Node:
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		return (tree as SceneTree).root.get_node_or_null("/root/GameRuntime")
	return null
