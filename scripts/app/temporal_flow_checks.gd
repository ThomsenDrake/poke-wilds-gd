extends RefCounted

# Generic deterministic temporal predicates. Keep this side-effect-free: it
# only inspects trace lines, manifests, and semantic snapshots. Coverage is
# tracked through the usual _failed symmetric event, never through silent pass.

static func _payload_matches(payload: Variant, expected: Dictionary) -> bool:
	if not (payload is Dictionary):
		return expected.is_empty()
	var normalized: Dictionary = JSON.parse_string(JSON.stringify(expected))
	for key in normalized.keys():
		if (payload as Dictionary).get(key) != normalized[key]:
			return false
	return true


static func trace_has_since(lines: PackedStringArray, from_line: int, event_name: String, payload_match: Dictionary = {}) -> bool:
	for i in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if not (parsed is Dictionary):
			continue
		if str((parsed as Dictionary).get("event", "")) != event_name:
			continue
		if _payload_matches((parsed as Dictionary).get("payload", {}), payload_match):
			return true
	return false


static func failing_since(lines: PackedStringArray, from_line: int) -> Array:
	var out: Array = []
	for i in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if parsed is Dictionary and str(parsed.get("event", "")).ends_with("_failed"):
			out.append(parsed)
	return out


static func first_line_for_event(lines: PackedStringArray, from_line: int, event_name: String) -> int:
	for i in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if parsed is Dictionary and str(parsed.get("event", "")) == event_name:
			return i
	return -1


static func event_order_ok(lines: PackedStringArray, from_line: int, events: Array) -> Dictionary:
	var cursor := maxi(from_line, 0)
	for event_name in events:
		var found := first_line_for_event(lines, cursor, str(event_name))
		if found < 0:
			return {"ok": false, "missing": str(event_name)}
		cursor = found + 1
	return {"ok": true, "missing": ""}


static func monotonic_frames_ok(manifest: Dictionary) -> Dictionary:
	var frames: Array = manifest.get("frames", [])
	if frames.is_empty():
		return {"ok": false, "reason": "no temporal frames captured"}
	for i in range(frames.size()):
		var entry: Dictionary = frames[i]
		if int(entry.get("index", -1)) != i:
			return {"ok": false, "reason": "frame index gap at %d" % i}
	return {"ok": true, "reason": ""}
