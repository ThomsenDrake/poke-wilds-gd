extends RefCounted

# Shared release-report hygiene. Gameplay data is intentionally preserved;
# machine identity, filesystem identity, and credential-shaped material are not.

static func sanitize_text(value: String) -> String:
	var text := _strip_controls(value)
	var home := OS.get_environment("HOME")
	if not home.is_empty():
		text = text.replace(home, "$HOME")
	var user_profile := OS.get_environment("USERPROFILE")
	if not user_profile.is_empty():
		text = text.replace(user_profile, "$HOME")
	var app_dir := OS.get_executable_path().get_base_dir()
	if not app_dir.is_empty():
		text = text.replace(app_dir, "$APP")
	text = text.replace(ProjectSettings.globalize_path("user://"), "$USER_DATA/")
	for variable in ["USER", "USERNAME", "HOSTNAME", "COMPUTERNAME"]:
		var machine_value := OS.get_environment(variable)
		if not machine_value.is_empty():
			text = text.replace(machine_value, "[REDACTED_MACHINE]")
	text = _redact_pattern(text, "(?i)authorization\\s*:\\s*(?:bearer\\s+)?[^\\s]+",
		"Authorization: [REDACTED]")
	text = _redact_pattern(text,
		"(?i)\\b(access[_-]?token|invite[_-]?token|admin[_-]?token|private[_-]?key)\\s*[:=]\\s*[^\\s,;]+",
		"$1=[REDACTED]")
	text = _redact_pattern(text, "(?i)\\bgh[pousr]_[A-Za-z0-9_]{20,}\\b", "[REDACTED_TOKEN]")
	text = _redact_pattern(text,
		"\\beyJ[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}(?:\\.[A-Za-z0-9_-]{8,})?\\b",
		"[REDACTED_TOKEN]")
	text = _redact_pattern(text, "(?i)\\b[0-9a-f]{64,}\\b", "[REDACTED_TOKEN]")
	text = _redact_pattern(text, "(?:/Users|/home)/[^/\\s]+(?:/[^\\s]*)?", "[REDACTED_PATH]")
	text = _redact_pattern(text, "(?i)[A-Z]:\\\\Users\\\\[^\\\\\\s]+(?:\\\\[^\\s]*)?", "[REDACTED_PATH]")
	text = _redact_pattern(text, "(?i)\\b(hostname|computername|host|username|user)\\s*[:=]\\s*[^\\s,;]+",
		"$1=[REDACTED_MACHINE]")
	return text


static func sanitize_message(value: String) -> String:
	return sanitize_text(value).strip_edges().left(1000)


static func public_message(value: String) -> String:
	return sanitize_message(value)


static func sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


static func random_token(byte_count: int = 16) -> String:
	return Crypto.new().generate_random_bytes(byte_count).hex_encode()


static func _strip_controls(value: String) -> String:
	var clean := ""
	for index in value.length():
		var code := value.unicode_at(index)
		if code == 9 or code == 10 or code == 13 or code >= 32:
			clean += value[index]
	return clean


static func _redact_pattern(value: String, pattern: String, replacement: String) -> String:
	var regex := RegEx.new()
	return regex.sub(value, replacement, true) if regex.compile(pattern) == OK else value
