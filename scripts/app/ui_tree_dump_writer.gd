extends RefCounted

# The ui_tree contract-artifact writer (agent-neutral integration Phase 2; the
# battle_scenario_fixtures.gd single-home precedent): the SINGLE writer of the
# agent-surface manifest [ui_tree] dump_dir artifacts —
# .godot-smoke/ui_tree/<screen>.json. Per dumped node: path relative to the
# screen root, type,
# global rect, disabled, label text when non-empty, plus the AccessKit
# annotations the GBC widget library sets (a11y_name/a11y_description/
# a11y_live, emitted only when non-default; every dumped node passed the
# full-chain shown filter, so a constant "visible" field carries no
# information) — plus the screen id and the cursor/selection where the screen
# exposes one. Paths in the transcript, never binary payloads (the
# snapshot-sidecar convention). Extracted from the verbatim _dump_screen/
# _shown/_rect_payload copies in ui_tree_dump_scenario.gd +
# legibility_soak_scenario.gd (strict-review F1) so both scenarios emit the
# IDENTICAL artifact bytes: same key set, same path sort, same JSON formatting
# ("  " indent + trailing newline).

const OUT_DIR := "res://.godot-smoke/ui_tree" # the one canonical artifact dir; consumers reference this const, never redeclare it

# Writes the visible Control subtree under root to OUT_DIR/<screen_id>.json and
# returns the dumped node count; -1 when the artifact cannot be written (the
# callers pin their own failure label).
static func write_screen(screen_id: String, root: Control, cursor: Dictionary) -> int:
	var snapshot := snapshot_screen(screen_id, root, cursor)
	var nodes: Array = snapshot["nodes"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := "%s/%s.json" % [OUT_DIR, screen_id]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return -1
	file.store_string(JSON.stringify(snapshot, "  ") + "\n")
	file.close()
	return nodes.size()


# Pure snapshot seam reused by release feedback capture. write_screen remains
# byte-identical because it serializes this exact dictionary with the original
# indentation and trailing newline.
static func snapshot_screen(screen_id: String, root: Control, cursor: Dictionary = {}) -> Dictionary:
	var all: Array = [root]
	all.append_array(root.find_children("*", "Control", true, false))
	var nodes: Array = []
	for node in all:
		var control := node as Control
		if control == null or not shown(control):
			continue
		var entry := {
			"path": str(root.get_path_to(control)),
			"type": control.get_class(),
			"rect": rect_payload(control.get_global_rect()),
			"disabled": control.get("disabled") == true,
		}
		var text = control.get("text")
		if text is String and not (text as String).is_empty():
			entry["text"] = text
		var a11y_name := str(control.get("accessibility_name"))
		if not a11y_name.is_empty():
			entry["a11y_name"] = a11y_name
		var a11y_desc := str(control.get("accessibility_description"))
		if not a11y_desc.is_empty():
			entry["a11y_description"] = a11y_desc
		var a11y_live := int(control.get("accessibility_live"))
		if a11y_live != 0: # LIVE_OFF default: only live regions carry the field
			entry["a11y_live"] = a11y_live
		nodes.append(entry)
	nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["path"]) < str(b["path"]))
	return {"screen": screen_id, "cursor": cursor, "node_count": nodes.size(), "nodes": nodes}

# Full-chain visibility to the window root (the accessibility-snapshot semantic):
# unlike layout_audit._shown — which stops at the owning Viewport so it can audit
# a HIDDEN BattleView's stage internals — the dump scenarios open every screen for
# real, so a hidden sibling screen root (e.g. OptionsScreen under the start menu)
# must mask its SubViewport children; stopping at the Viewport would leak them in
# as visible. SubViewport nodes themselves are not CanvasItems and skip cleanly.
static func shown(control: Control) -> bool:
	var node: Node = control
	while node != null:
		if node is CanvasItem and not (node as CanvasItem).visible:
			return false
		node = node.get_parent()
	return true

static func rect_payload(rect: Rect2) -> Array:
	return [int(roundf(rect.position.x)), int(roundf(rect.position.y)), int(roundf(rect.size.x)), int(roundf(rect.size.y))]
