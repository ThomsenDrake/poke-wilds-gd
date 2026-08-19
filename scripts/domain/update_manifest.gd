extends RefCounted

const SCHEMA_VERSION := 1
const DEFAULT_CHANNEL := "playtest"
const OS_KEYS := ["linux", "windows", "macos"]
const SHA256_RE := "^[0-9a-f]{64}$"
const CHANNEL_RE := "^[a-z0-9-]{1,40}$"
const COMMIT_RE := "^[0-9a-f]{40}$"
const BUILD_ID_RE := "^[A-Za-z0-9._:-]{1,80}$"
const PUBLISHED_RE := "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"


static func os_key(os_name: String) -> String:
	match os_name:
		"Linux":
			return "linux"
		"Windows":
			return "windows"
		"macOS":
			return "macos"
		_:
			return ""


static func parse(value) -> Dictionary:
	if not value is Dictionary:
		return {}
	var channel := str(value.get("channel", ""))
	var published := str(value.get("published_at", ""))
	var build_id := str(value.get("build_id", ""))
	var commit := str(value.get("commit_sha", "")).to_lower()
	if int(value.get("schema_version", 0)) != SCHEMA_VERSION:
		return {}
	if not _matches(CHANNEL_RE, channel) or not _matches(PUBLISHED_RE, published):
		return {}
	if not _matches(BUILD_ID_RE, build_id) or not _matches(COMMIT_RE, commit):
		return {}
	var min_save := int(value.get("min_save_version", 0))
	if min_save < 1:
		return {}
	var builds = value.get("builds", null)
	if not builds is Dictionary:
		return {}
	var parsed_builds := {}
	for key in OS_KEYS:
		var entry := _parse_build((builds as Dictionary).get(key, null))
		if entry.is_empty():
			return {}
		parsed_builds[key] = entry
	return {
		"schema_version": SCHEMA_VERSION, "channel": channel, "published_at": published,
		"build_id": build_id, "commit_sha": commit, "min_save_version": min_save,
		"builds": parsed_builds,
	}


static func is_newer(latest: Dictionary, current: Dictionary, applied: Dictionary = {}) -> bool:
	if latest.is_empty():
		return false
	var latest_id := str(latest.get("build_id", ""))
	if latest_id.is_empty():
		return false
	if latest_id == str(current.get("build_id", "")):
		return false
	if latest_id == str(applied.get("build_id", "")):
		return false
	var latest_ts := stamp_of(latest)
	if latest_ts.is_empty():
		return false
	if not _is_newer_stamp(latest_ts, latest_id, stamp_of(applied), str(applied.get("build_id", ""))):
		return false
	return _is_newer_stamp(latest_ts, latest_id, stamp_of(current), str(current.get("build_id", "")))


static func stamp_of(value: Dictionary) -> String:
	var published := str(value.get("published_at", ""))
	if _matches(PUBLISHED_RE, published):
		return published
	return _stamp_from_build_id(str(value.get("build_id", "")))


static func _parse_build(value) -> Dictionary:
	if not value is Dictionary:
		return {}
	var url := str(value.get("url", "")).strip_edges()
	var digest := str(value.get("sha256", "")).to_lower()
	var filename := str(value.get("filename", ""))
	var bytes := int(value.get("bytes", 0))
	if bytes < 1 or filename.is_empty() or filename.contains("/") or filename.contains("\\"):
		return {}
	if not _matches(SHA256_RE, digest) or not url.to_lower().begins_with("https://"):
		return {}
	if url.contains("?") or url.contains("#") or url.contains("@") or url.contains("\\"):
		return {}
	return {"url": url, "sha256": digest, "bytes": bytes, "filename": filename}


static func _stamp_from_build_id(build_id: String) -> String:
	var parts := build_id.split("-")
	if parts.is_empty():
		return ""
	var tail := parts[parts.size() - 1]
	if not _matches("^[0-9]{8}T[0-9]{6}Z$", tail):
		return ""
	return "%s-%s-%sT%s:%s:%sZ" % [tail.substr(0, 4), tail.substr(4, 2), tail.substr(6, 2),
		tail.substr(9, 2), tail.substr(11, 2), tail.substr(13, 2)]


static func _is_newer_stamp(latest_ts: String, latest_id: String, baseline_ts: String,
		baseline_id: String) -> bool:
	if baseline_ts.is_empty() and baseline_id.is_empty():
		return true
	if baseline_ts.is_empty() or latest_ts.is_empty():
		return false
	if latest_ts != baseline_ts:
		return latest_ts > baseline_ts
	return latest_id > baseline_id


static func _matches(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	return regex.compile(pattern) == OK and regex.search(value) != null
