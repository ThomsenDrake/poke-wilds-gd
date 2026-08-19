extends RefCounted

const SAVE_PREFIX := "user://godot_port_save.json"


static func executable_path() -> String:
	return OS.get_executable_path()


static func install_path(os_name: String = OS.get_name(), exe_path: String = "") -> String:
	var exe := exe_path if not exe_path.is_empty() else executable_path()
	if os_name != "macOS":
		return exe
	var cursor := exe
	while not cursor.is_empty() and not cursor.ends_with(".app"):
		cursor = cursor.get_base_dir()
	return cursor if cursor.ends_with(".app") else exe


static func cleanup_old(target: String) -> void:
	var old_path := target + ".old"
	if FileAccess.file_exists(old_path) or DirAccess.dir_exists_absolute(old_path):
		_remove_path(old_path)


static func apply(os_name: String, artifact: String, target: String) -> Dictionary:
	artifact = _absolute(artifact)
	target = _absolute(target)
	if artifact.is_empty() or target.is_empty() or not FileAccess.file_exists(artifact):
		return {"ok": false, "error": "pending_missing"}
	if target.begins_with(SAVE_PREFIX) or target.contains("godot_port_save.json"):
		return {"ok": false, "error": "save_path_refused"}
	match os_name:
		"Windows":
			return _apply_windows(target, artifact)
		"Linux":
			return _apply_file(target, artifact, false, true)
		"macOS":
			return _apply_macos(target, artifact)
		_:
			return {"ok": false, "error": "unknown_os"}


static func launch_deferred(applied: Dictionary) -> bool:
	var helper := str(applied.get("helper", ""))
	if helper.is_empty():
		return false
	OS.create_process("cmd.exe", PackedStringArray(["/c", "start", "", helper]))
	return true


static func _apply_windows(target: String, artifact: String) -> Dictionary:
	var staged := target + ".new"
	_remove_path(staged)
	if DirAccess.copy_absolute(artifact, staged) != OK:
		return {"ok": false, "error": "write_failed"}
	var helper := target.get_base_dir().path_join("PokeWilds-update.cmd")
	var file := FileAccess.open(helper, FileAccess.WRITE)
	if file == null:
		_remove_path(staged)
		return {"ok": false, "error": "helper_failed"}
	file.store_string(_windows_helper_body(target, staged, OS.get_process_id()))
	file.close()
	return {"ok": true, "deferred": true, "helper": helper, "old_path": target + ".old"}


static func _windows_helper_body(target: String, staged: String, pid: int) -> String:
	var old_path := target + ".old"
	var lines := PackedStringArray([
		"@echo off",
		":wait",
		"timeout /t 1 /nobreak >nul",
		"tasklist /FI \"PID eq %s\" | find \"%s\" >nul" % [str(pid), str(pid)],
		"if not errorlevel 1 goto wait",
		"if exist \"%s\" del /f /q \"%s\"" % [old_path, old_path],
		"if exist \"%s\" move /y \"%s\" \"%s\"" % [target, target, old_path],
		"move /y \"%s\" \"%s\"" % [staged, target],
		"start \"\" \"%s\"" % target,
	])
	return "\r\n".join(lines) + "\r\n"


static func _apply_file(target: String, artifact: String, keep_old: bool, chmod_exec: bool) -> Dictionary:
	var old_path := target + ".old"
	_remove_path(old_path)
	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var renamed := DirAccess.rename_absolute(target, old_path)
		if renamed != OK:
			return {"ok": false, "error": "rename_failed"}
	var copied := DirAccess.copy_absolute(artifact, target)
	if copied != OK:
		if FileAccess.file_exists(old_path):
			DirAccess.rename_absolute(old_path, target)
		return {"ok": false, "error": "write_failed"}
	if chmod_exec:
		_chmod_executable(target)
	if not keep_old:
		_remove_path(old_path)
	return {"ok": true, "old_path": old_path if keep_old else ""}


static func _apply_macos(target: String, artifact: String) -> Dictionary:
	var staged := target + ".new"
	_remove_path(staged)
	var unzip := OS.execute("unzip", ["-o", artifact, "-d", staged], [], false, true)
	if unzip != 0:
		_remove_path(staged)
		return {"ok": false, "error": "unzip_failed"}
	var app := _find_app(staged)
	if app.is_empty():
		_remove_path(staged)
		return {"ok": false, "error": "app_missing"}
	var old_path := target + ".old"
	_remove_path(old_path)
	if DirAccess.dir_exists_absolute(target) or FileAccess.file_exists(target):
		if DirAccess.rename_absolute(target, old_path) != OK:
			_remove_path(staged)
			return {"ok": false, "error": "rename_failed"}
	if DirAccess.rename_absolute(app, target) != OK:
		if DirAccess.dir_exists_absolute(old_path):
			DirAccess.rename_absolute(old_path, target)
		_remove_path(staged)
		return {"ok": false, "error": "swap_failed"}
	_remove_path(staged)
	_remove_path(old_path)
	return {"ok": true, "old_path": ""}


static func _absolute(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


static func _chmod_executable(target: String) -> void:
	OS.execute("chmod", ["0755", target], [], false, true)


static func _find_app(root: String) -> String:
	var dir := DirAccess.open(root)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.ends_with(".app"):
			return root.path_join(name)
		name = dir.get_next()
	return ""


static func _remove_path(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_remove_dir(path)
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			_remove_path(path.path_join(name))
		name = dir.get_next()
	DirAccess.remove_absolute(path)
