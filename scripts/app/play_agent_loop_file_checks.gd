extends RefCounted

# Validation and stamp helpers for play_agent_loop filing. No HTTP.

const INSTALL_ID_PATH := "user://feedback-agent-play-install-id.txt"
const LIVE_ENV := "PLAY_AGENT_LIVE_FILE"
const ENDPOINT_ENV := "PLAY_AGENT_FEEDBACK_ENDPOINT"
const DEFAULT_ENDPOINT := "https://feedback.invalid/agent-play"


static func message_ok(message: String) -> bool:
	return message.begins_with("[agent-play]") and message.length() >= 1 and message.length() <= 1000


static func live_env_on() -> bool:
	var raw := OS.get_environment(LIVE_ENV).to_lower()
	return raw in ["1", "true", "yes", "on"]


static func live_requested(payload: Dictionary) -> bool:
	return live_env_on() and bool(payload.get("live", false))


static func public_stamp(_live: bool) -> Dictionary:
	var endpoint := OS.get_environment(ENDPOINT_ENV)
	if endpoint.is_empty():
		endpoint = DEFAULT_ENDPOINT
	return {
		"channel": "public", "version": "alpha", "build_id": "agent-play",
		"commit_sha": "agent-play", "endpoint": "", "invite_token": "",
		"tester_id": "PUBLIC-ALPHA", "feedback_mode": "public",
		"feedback_endpoint": endpoint,
	}


static func release_text_focus(tree: SceneTree) -> void:
	var owner = tree.root.gui_get_focus_owner()
	if owner is LineEdit or owner is TextEdit:
		(owner as Control).release_focus()


static func env_truthy(name: String) -> bool:
	return OS.get_environment(name).to_lower() in ["1", "true", "yes", "on"]
