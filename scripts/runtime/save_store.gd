extends RefCounted

# JSON save transport. Payload shape and version migration live in
# session_state.gd; this store reads/writes the document and recovers
# non-destructively under every path:
# - writes are atomic: JSON goes to a same-directory .tmp, then a single
#   POSIX rename replaces the live file (a crash mid-write leaves the last
#   good save in place, with at worst a stale .tmp to sweep);
# - a corrupt/unparseable file is preserved as .corrupt.bak and recovered
#   with a warning-tier save_recovery trace, never swallowed silently;
# - a save NEWER than SessionState.SAVE_VERSION is refused and preserved as
#   .newer.bak BEFORE the empty payload reaches callers, so the per-step
#   autosave writes a fresh file to the now-empty live path and can never
#   clobber the unreadable/newer save (the refusal is non-destructive);
# - if that preserve rename FAILS, the file is still at the live path, so the
#   store arms live-path protection and refuses every subsequent write (traced,
#   never swallowed) rather than rename a fresh save over the un-preserved
#   newer/corrupt save -- the non-destructive guarantee holds even when
#   preservation itself fails (persistence resumes on the next launch once a
#   fresh store preserves the file successfully).

const SessionState := preload("res://scripts/runtime/session_state.gd")

const SAVE_PATH := "user://godot_port_save.json"
const TMP_SUFFIX := ".tmp"

var _trace = null
# Armed when a newer/corrupt save EXISTS but its preserve rename failed, so the
# file is still at SAVE_PATH: no write may rename over it (that would clobber
# the very save preservation could not protect). Stays armed for this store
# instance; the next launch starts from a fresh store and re-attempts preserve.
var _live_path_protected := false
var _protection_traced := false


func setup(trace_logger) -> void:
	_trace = trace_logger


func load_payload() -> Dictionary:
	_remove_leftover(SAVE_PATH + TMP_SUFFIX) # prior write died pre-rename; the live file is still the last good save
	if not FileAccess.file_exists(SAVE_PATH):
		_recovery("absent", "")
		return {}
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		_recovery("corrupt", _preserve(".corrupt.bak"))
		return {}
	var text = file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_recovery("corrupt", _preserve(".corrupt.bak"))
		return {}
	var version := int((parsed as Dictionary).get("version", 1))
	if version > SessionState.SAVE_VERSION:
		var preserved := _preserve(".newer.bak")
		_warn("Save uses a newer schema; preserved it and starting fresh.", {
			"found_version": version,
			"supported_version": SessionState.SAVE_VERSION,
			"preserved_path": preserved
		})
		return {}
	return parsed


func write_payload(payload: Dictionary) -> bool:
	if _live_path_protected:
		_refuse_write()
		return false
	var tmp_path := SAVE_PATH + TMP_SUFFIX
	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload))
	file.close()
	# Same-directory rename is atomic on POSIX, so readers only ever see the
	# previous complete save or the new one, never a torn write.
	var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(SAVE_PATH))
	if error != OK:
		_warn("Atomic save rename failed; the previous save is untouched.", {"error": error})
		_remove_leftover(tmp_path)
		return false
	return true


# Moves an unreadable/newer save off the live path so later writes cannot
# overwrite it; returns the preserved path, or "" when nothing was preserved.
func preserve_save(suffix: String) -> String:
	if not FileAccess.file_exists(SAVE_PATH):
		return ""
	var preserved := SAVE_PATH + suffix
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(SAVE_PATH), ProjectSettings.globalize_path(preserved)) != OK:
		return ""
	return preserved


# preserve_save that also arms live-path protection when the file EXISTS but the
# rename failed: the un-preserved save is still at SAVE_PATH, so no later write
# may rename over it. This keeps the failed-preserve path non-destructive too.
func _preserve(suffix: String) -> String:
	var preserved := preserve_save(suffix)
	if preserved == "" and FileAccess.file_exists(SAVE_PATH):
		_live_path_protected = true
	return preserved


# A newer/corrupt save could not be preserved off the live path; refuse the
# write rather than clobber it. Traced once (never swallowed): the in-memory
# game keeps running and persistence resumes on the next launch once a fresh
# store preserves the file successfully.
func _refuse_write() -> void:
	if _protection_traced:
		return
	_protection_traced = true
	_warn("Save write refused: a newer/corrupt save still occupies the live path and could not be preserved; not clobbering it.", {})


# A save that could not be used, traced instead of swallowed: corrupt is
# warning-tier (the file was kept at preserved_path), absent is event-tier.
func _recovery(reason: String, preserved_path: String) -> void:
	if _trace == null:
		return
	var payload := {"reason": reason, "preserved_path": preserved_path}
	if reason == "corrupt":
		_trace.warning("SaveStore", "Save could not be used; preserved it and starting fresh.", payload)
	else:
		_trace.emit_event("save_recovery", "SaveStore", payload)


func _warn(message: String, payload: Dictionary = {}) -> void:
	if _trace != null:
		_trace.warning("SaveStore", message, payload)
	else:
		push_warning("SaveStore: " + message)


func _remove_leftover(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
