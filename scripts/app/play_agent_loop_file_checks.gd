extends RefCounted

# Validation and stamp helpers for play_agent_loop filing. No HTTP.

const INSTALL_ID_PATH := "user://feedback-agent-play-install-id.txt"
const LIVE_ENV := "PLAY_AGENT_LIVE_FILE"
const ENDPOINT_ENV := "PLAY_AGENT_FEEDBACK_ENDPOINT"
const COMMIT_SHA_ENV := "PLAY_AGENT_COMMIT_SHA"
const DEFAULT_ENDPOINT := "https://feedback.invalid/agent-play"


static func message_ok(message: String) -> bool:
	return message.begins_with("[agent-play]") and message.length() >= 1 and message.length() <= 1000


static func live_env_on() -> bool:
	if env_truthy("GITHUB_ACTIONS") or env_truthy("CI"):
		return false
	var raw := OS.get_environment(LIVE_ENV).strip_edges().to_lower()
	if raw.is_empty():
		return true
	return not (raw == "0" or raw == "false" or raw == "no" or raw == "off")


static func live_requested(payload: Dictionary) -> bool:
	var want := true
	if payload.has("live"):
		want = bool(payload.get("live"))
	return live_env_on() and want


static func commit_sha_ok(value: String) -> bool:
	var text := value.strip_edges().to_lower()
	if text == "unknown":
		return true
	if text.length() < 7 or text.length() > 64:
		return false
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if code >= 48 and code <= 57:
			continue
		if code >= 97 and code <= 102:
			continue
		return false
	return true


static func stamp_commit_sha() -> String:
	var env_sha := OS.get_environment(COMMIT_SHA_ENV).strip_edges().to_lower()
	if commit_sha_ok(env_sha):
		return env_sha
	var lines: Array = []
	var root := ProjectSettings.globalize_path("res://").trim_suffix("/")
	if OS.execute("git", ["-C", root, "rev-parse", "HEAD"], lines, true) == 0 and not lines.is_empty():
		var head := str(lines[0]).strip_edges().to_lower()
		if commit_sha_ok(head):
			return head
	return "unknown"


static func public_stamp(_live: bool) -> Dictionary:
	var endpoint := OS.get_environment(ENDPOINT_ENV)
	if endpoint.is_empty():
		endpoint = DEFAULT_ENDPOINT
	return {
		"channel": "public", "version": "alpha", "build_id": "agent-play",
		"commit_sha": stamp_commit_sha(), "endpoint": "", "invite_token": "",
		"tester_id": "PUBLIC-ALPHA", "feedback_mode": "public",
		"feedback_endpoint": endpoint,
	}


static func release_text_focus(tree: SceneTree) -> void:
	var owner = tree.root.gui_get_focus_owner()
	if owner is LineEdit or owner is TextEdit:
		(owner as Control).release_focus()


static func env_truthy(name: String) -> bool:
	return OS.get_environment(name).to_lower() in ["1", "true", "yes", "on"]
