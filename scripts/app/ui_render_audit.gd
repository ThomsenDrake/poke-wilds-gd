extends Node

# Lane 2 of the autonomous oracle suite (spec: docs/superpowers/specs/
# 2026-07-18-autonomous-playtesting-oracles-design.md). Renders the live
# battle surface and menu screens with worst-case catalog data and checks the
# scene tree against UiRenderModel expectations: expected strings sit at their
# modeled positions, no two labels' text ink intersects, cursors sit on their
# rows, and labels stay onstage. Windowed runs add the pixel half via
# tools/visual_lint.py; findings stay quarantined (traces only, never red)
# until GRADUATED flips true.

const UiRenderModel := preload("res://scripts/app/ui_render_model.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")

const GRADUATED := false
const POS_TOLERANCE := 1.5
const BOUNDS_TOLERANCE := 1.0

var _ctx: Dictionary = {}
var _snap = SnapshotCapture.new()
var _failures: Array = []
var _states_checked := 0
var _labels_checked := 0
var _cursors_checked := 0
var _quarantined := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await _settle(2)
	var catalog = _runtime().get("catalog")
	var snapshot: Dictionary = UiRenderModel.worst_snapshot(catalog)
	await _audit_battle(snapshot)
	await _audit_menus(catalog)
	if _failures.is_empty():
		_runtime().emit_trace("ui_render_audit_passed", "SmokeScenarios", {
			"states_checked": _states_checked, "labels_checked": _labels_checked,
			"cursors_checked": _cursors_checked, "quarantined": _quarantined})
	else:
		for failure in _failures:
			push_error(str(failure))


func _audit_battle(snapshot: Dictionary) -> void:
	var stage: Control = _battle_view().get_node("BattleViewport/BattleStage")
	var specs := [["battle_action", "action", "fight", ""], ["battle_message", "action", "fight", str(snapshot.get("message", ""))],
		["battle_moves", "moves", "move_0", ""], ["battle_item", "item", "poke_ball", ""]]
	# The SubViewport only redraws while the view is visible; the pixel half
	# captures its texture directly, so the scene-tree half drives it shown.
	var was_visible: bool = _battle_view().visible
	_battle_view().visible = true
	for spec in specs:
		stage.render(snapshot, spec[1], spec[2], spec[3])
		await _settle(1)
		var model: Dictionary = UiRenderModel.expected(spec[0], snapshot)
		_states_checked += 1
		var labels := UiRenderModel.visible_labels(stage)
		_check_strings(spec[0], labels, model)
		_check_labels(spec[0], labels, UiRenderModel.STAGE)
		_check_pairs(spec[0], stage, model, spec[2])
		await _pixel_half(spec[0], model)
	_battle_view().visible = was_visible


func _check_strings(state: String, labels: Array, model: Dictionary) -> void:
	var consumed := {}
	for expected in model["strings"]:
		var text := str(expected["text"])
		_labels_checked += 1
		var matched: Label = null
		for label in labels:
			if not consumed.has(label) and label.text == text and _string_in_region(label, expected):
				matched = label
				break
		if matched == null:
			_failures.append({"state": state, "kind": "missing_or_misplaced", "text": text})
		else:
			consumed[matched] = true


func _string_in_region(label: Label, expected: Dictionary) -> bool:
	var region: Rect2 = expected["region"]
	if str(expected["mode"]) == "anchor":
		return label.get_global_rect().position.distance_to(region.position) <= POS_TOLERANCE
	var ink := UiRenderModel.ink_rect(label)
	if not region.grow(BOUNDS_TOLERANCE).encloses(ink):
		return false
	for avoid in expected.get("avoid", []):
		if ink.intersects(avoid):
			return false
	return true


func _check_labels(state: String, labels: Array, bounds: Rect2) -> void:
	var rects := []
	for label in labels:
		_labels_checked += 1
		if not bounds.grow(BOUNDS_TOLERANCE).encloses(label.get_global_rect()):
			_failures.append({"state": state, "kind": "off_stage", "label": str(label.name)})
		rects.append(UiRenderModel.ink_rect(label))
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j]):
				_failures.append({"state": state, "kind": "label_overlap", "a": str(labels[i].name), "b": str(labels[j].name)})


func _check_pairs(state: String, stage: Control, model: Dictionary, selection: String) -> void:
	var live: TextureRect = stage.get_node_or_null("Cursor")
	for pair in model.get("pairs", []):
		_cursors_checked += 1
		var cursor: Rect2 = pair["cursor"]
		var row: Rect2 = pair["row"]
		if absf(cursor.get_center().y - row.get_center().y) > 2.0 or cursor.end.x > row.position.x:
			_failures.append({"state": state, "kind": "cursor_model_off", "id": pair.get("id", "")})
		if str(pair.get("id", "")) != selection or live == null or not live.visible:
			continue
		if live.get_global_rect().position.distance_to((pair["cursor"] as Rect2).position) > POS_TOLERANCE:
			_failures.append({"state": state, "kind": "cursor_misplaced", "id": selection})


func _audit_menus(catalog) -> void:
	var menu := _start_menu()
	var original: Dictionary = menu._raw_context
	var injected := original.duplicate()
	var species := UiRenderModel.worst_entry(catalog.species.values(), "display_name")
	injected["get_party_snapshot"] = func(): return UiRenderModel.worst_party(species)
	injected["get_bag_snapshot"] = func(): return UiRenderModel.worst_bag(catalog)
	menu.setup(injected)
	_ctx["toggle_menu"].call()
	await _settle(2)
	_check_menu_state("menu", menu, menu.get_node("MenuPanel").get_global_rect(), [])
	menu._activate_entry(0)
	await _settle(2)
	var party_screen: Control = menu.get_node("PartyScreen")
	_check_menu_state("party", party_screen, party_screen.get_node("Panel").get_global_rect(), [str(species.get("display_name", "?"))])
	party_screen.close_screen()
	menu._activate_entry(1)
	await _settle(2)
	var bag_screen: Control = menu.get_node("BagScreen")
	_check_menu_state("bag", bag_screen, bag_screen.get_node("Panel").get_global_rect(), _bag_names(catalog))
	bag_screen.close_screen()
	_ctx["toggle_menu"].call()
	menu.setup(original)


func _check_menu_state(state: String, root: Control, bounds: Rect2, contains: Array) -> void:
	_states_checked += 1
	_check_labels(state, UiRenderModel.visible_labels(root), bounds)
	var texts := []
	for label in UiRenderModel.visible_labels(root):
		texts.append(label.text)
	for list in root.find_children("*", "ItemList", true, false):
		if UiRenderModel.shown(list):
			for i in range(list.item_count):
				texts.append(list.get_item_text(i))
	for wanted in contains:
		_labels_checked += 1
		var found := false
		for text in texts:
			if text.contains(wanted):
				found = true
				break
		if not found:
			_failures.append({"state": state, "kind": "missing_string", "text": wanted})


func _bag_names(catalog) -> Array:
	var names := []
	for entry in UiRenderModel.worst_bag(catalog):
		var item: Dictionary = catalog.get_item(str(entry.get("item_id", "")))
		if not item.is_empty():
			names.append(str(item.get("display_name", "")).capitalize())
	return names


# Pixel half: windowed only (headless skips; captures need a real renderer).
# Captures the battle SubViewport texture directly, so regions map 1:1 at
# stage scale; the readback guard is ADDED after the settle (never a
# substitute: the SubViewport only redraws while visible). Magenta/stale
# frames (Godot 4.6 #115402) fall back to a root-viewport crop of the battle
# display resized back to the 160x144 stage so run_lint's display contract
# holds. Findings route to quarantine traces, never to failures, until
# GRADUATED flips true.
func _pixel_half(state: String, model: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await _settle(2)
	await _snap.guard_readback()
	var subvp: SubViewport = _battle_view().get_node("BattleViewport")
	var image := subvp.get_texture().get_image()
	var verdict := _snap.classify(image, -1)
	if verdict.kind == "magenta":
		_snap.trace_invalid(_runtime(), state, verdict, "root_viewport_crop fallback engaged")
		image = _snap.crop_battle_display(get_viewport(), _battle_view())
		if not image.is_empty():
			image.resize(160, 144, Image.INTERPOLATE_NEAREST)
	elif not verdict.kind.is_empty():
		_snap.trace_invalid(_runtime(), state, verdict, "")
		return # known-invalid frame (blank/uniform): lint findings against it would be noise
	if image == null or image.is_empty():
		return
	var display := Rect2(Vector2.ZERO, Vector2(image.get_size()))
	for finding in UiRenderModel.run_lint(state, model, image, display):
		_quarantined += 1
		_runtime().emit_trace("quarantine_finding", "SmokeScenarios",
			{"state": state, "kind": str(finding.get("kind", "")), "region": finding.get("region", [])})
		if GRADUATED:
			_failures.append({"state": state, "kind": "lint_%s" % str(finding.get("kind", "")), "region": finding.get("region", [])})


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _start_menu() -> Node: return _ctx["start_menu"]
