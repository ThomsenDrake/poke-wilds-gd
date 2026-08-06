extends RefCounted

# StorageScreen stage composition EXTRACTED from storage_screen.gd at the 220
# ui wall (restyle slice wave 2; the title_screen_stage.gd precedent). Builds
# inside the 160x144 ScreenStage: the guarded gsc background, box/party title
# plates, two two-line-entry Columns (">" marker + name line + info line,
# windowed at 4 visible entries), the bottom detail plate + full-width hint
# plate, the actions popup plate (menu_list_stage.gd Rows, black cursor) and
# the summary overlay plate. All stage children carry EXPLICIT integer offsets
# (never set_anchors_preset on a parented node). Black ink on white plates
# only — no text sits on the raw background (design §1.3).

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")
const MenuList := preload("res://scripts/ui/menu_list_stage.gd")
const PartyRows := preload("res://scripts/ui/party_rows.gd")


# Two-line column entry texts; every substring is a PartyRows.build_row format
# (name "%s  Lv.%d" / "Egg (%s)"; info "%d/%d" + status_abbrev / "Steps: %d" + "EGG").
static func entry_rows(entries: Array, empty_text: String) -> Array:
	if entries.is_empty():
		return [{"name": empty_text, "info": ""}]
	var rows: Array = []
	for entry in entries:
		var mon: Dictionary = entry if entry is Dictionary else {}
		if bool(mon.get("is_egg", false)):
			rows.append({"name": "Egg (%s)" % str(mon.get("egg", {}).get("display_name", "?")),
				"info": "Steps: %d EGG" % int(mon.get("egg", {}).get("steps_to_hatch", 0))})
		else:
			rows.append({"name": "%s  Lv.%d" % [str(mon.get("name", "Pokemon")), int(mon.get("level", 1))],
				"info": "%d/%d %s" % [int(mon.get("current_hp", 0)), maxi(1, int(mon.get("max_hp", 1))), PartyRows.status_abbrev(mon)]})
	return rows


# Summary accessors: catalog species + rules exp curve; invalid callables
# degrade PartyRows.summary_text gracefully (party-screen precedent).
static func rules_accessor(runtime: Node, method: String) -> Callable:
	if runtime == null:
		return Callable()
	var target: Variant = runtime.catalog if method == "get_species" else runtime.pokemon_rules
	return Callable(target, method) if target is Object and (target as Object).has_method(method) else Callable()


# RELEASE confirm trio (extracted at the 220 wall; bound to the screen in
# _ready). RELEASE is permanent (no overworld-mon drop until Phase 6 —
# documented deviation), so the wording double-emphasizes permanence before
# the confirm. The screen keeps the _awaiting_confirm/_confirm_index members;
# these statics only read/write them.
static func begin_release_confirm(screen: Control) -> void:
	var confirm_box := screen.get_node_or_null("../MessageBox")
	if confirm_box == null or not confirm_box.has_method("show_confirm"):
		screen._detail.text = "The confirm box is missing; release was refused."
		return
	screen._confirm_index = screen._box_index
	screen._awaiting_confirm = true
	confirm_box.call("show_confirm", "Release %s? It will be gone for good." % str(screen._active_mon().get("name", "this Pokemon")))


static func on_release_confirmed(screen: Control) -> void:
	# The MessageBox confirmed signal is SHARED (the StartMenu's NEW GAME confirm
	# rides it too): a confirm this screen did not open releases nothing.
	if not screen._awaiting_confirm:
		return
	screen._awaiting_confirm = false
	var storage: Variant = screen._storage()
	screen._apply(storage.release_from_box(screen._tile, screen._confirm_index) if storage != null else {})


static func on_release_cancelled(screen: Control) -> void:
	screen._awaiting_confirm = false # the spec's cancel branch: back to the actions


# Snapshot -> titles + columns (extracted at the 220 wall; byte-identical).
static func refresh(screen: Control) -> void:
	var storage: Variant = screen._storage()
	screen._box = storage.box_snapshot(screen._tile) if storage != null else []
	var session: Variant = screen._runtime.get("session") if screen._runtime != null else null
	var snapshot: Variant = session.get_party_snapshot() if session != null else []
	screen._party = snapshot if snapshot is Array else []
	screen._box_index = clampi(screen._box_index, 0, maxi(0, screen._box.size() - 1))
	screen._party_index = clampi(screen._party_index, 0, maxi(0, screen._party.size() - 1))
	screen._box_title.text = "STORAGE BOX %d" % screen._box.size()
	screen._party_title.text = "PARTY %d/6" % screen._party.size()
	rebuild_rows(screen)


static func rebuild_rows(screen: Control) -> void:
	screen._box_column.set_entries(entry_rows(screen._box, "Empty."))
	screen._box_column.set_selected(screen._box_index if screen._side == "box" and not screen._box.is_empty() else -1) # no marker on the empty placeholder (the old _fill_column contract)
	screen._party_column.set_entries(entry_rows(screen._party, "No Pokemon yet."))
	screen._party_column.set_selected(screen._party_index if screen._side == "party" and not screen._party.is_empty() else -1)


# Returns {box_title, party_title, box_column, party_column, action_plate,
# action_rows, summary_plate, summary_label, detail_label, hint_label}.
static func build(stage: Control) -> Dictionary:
	MenuList.art(stage, MenuList.BACKGROUND_PATH)
	var box_title := MenuList.plate_label(GbcWidgets.plate(Rect2(4, 4, 76, 12), stage), Rect2(3, 2, 70, 8), "STORAGE BOX")
	var party_title := MenuList.plate_label(GbcWidgets.plate(Rect2(84, 4, 72, 12), stage), Rect2(3, 2, 66, 8), "PARTY 0/6")
	var box_column := Column.new()
	box_column.setup(GbcWidgets.plate(Rect2(4, 18, 76, 78), stage), 4)
	var party_column := Column.new()
	party_column.setup(GbcWidgets.plate(Rect2(84, 18, 72, 78), stage), 4)
	var detail_label := MenuList.wrapped_label(GbcWidgets.plate(Rect2(4, 100, 100, 30), stage), Rect2(3, 2, 94, 26))
	var hint_label := MenuList.plate_label(GbcWidgets.plate(Rect2(4, 134, 152, 10), stage), Rect2(3, 1, 146, 8))
	var action_plate := GbcWidgets.plate(Rect2(108, 88, 48, 42), stage)
	action_plate.visible = false
	var action_rows := MenuList.Rows.new()
	action_rows.setup(action_plate)
	var summary_plate := GbcWidgets.plate(Rect2(6, 6, 148, 116), stage)
	summary_plate.visible = false
	var summary_label := MenuList.wrapped_label(summary_plate, Rect2(4, 3, 140, 110))
	return {"box_title": box_title, "party_title": party_title,
		"box_column": box_column, "party_column": party_column,
		"action_plate": action_plate, "action_rows": action_rows,
		"summary_plate": summary_plate, "summary_label": summary_label,
		"detail_label": detail_label, "hint_label": hint_label}


# One storage column: two-line entries (marker + name line; indented info
# line) at a 16px pitch, windowed so the selected entry stays visible (the old
# VBox scroll contract). set_selected(-1) marks the column inactive (the cursor
# lives on the OTHER side — the old selected=-1 _fill_column call).
class Column extends RefCounted:
	const ENTRY_PITCH := 16
	const MARKER_WIDTH := 8

	var _root: Control
	var _entries: Array = [] # per entry: {marker: Label, name: Label, info: Label}
	var _selected := -1
	var _window := 0
	var _max_visible := 4
	var _width := 0

	func setup(plate: Control, max_visible: int) -> void:
		_max_visible = max_visible
		_width = int(plate.size.x) - 6
		_root = Control.new()
		_root.name = "Column"
		_root.position = Vector2(3, 2)
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_child(_root)

	# rows: [{"name": String, "info": String}] — the screen composes the frozen
	# row strings; this widget only places them. Resets the window to the top.
	func set_entries(rows: Array) -> void:
		for entry in _entries:
			(entry as Dictionary).marker.queue_free()
			(entry as Dictionary).name_label.queue_free()
			(entry as Dictionary).info.queue_free()
		_entries.clear()
		for i in rows.size():
			var marker := _label("", 0, MARKER_WIDTH)
			var name_label := _label(str((rows[i] as Dictionary).get("name", "")), MARKER_WIDTH, _width - MARKER_WIDTH)
			var info := _label(str((rows[i] as Dictionary).get("info", "")), MARKER_WIDTH, _width - MARKER_WIDTH)
			_entries.append({"marker": marker, "name_label": name_label, "info": info})
		_window = 0
		_layout()

	func set_selected(index: int) -> void:
		_selected = index
		_layout()

	func _layout() -> void:
		if _selected >= 0:
			_window = clampi(_window, 0, maxi(0, _entries.size() - _max_visible))
			if _selected < _window:
				_window = _selected
			elif _selected >= _window + _max_visible:
				_window = _selected - _max_visible + 1
		for i in _entries.size():
			var entry: Dictionary = _entries[i]
			var slot := i - _window
			var shown := slot >= 0 and slot < _max_visible
			(entry.marker as Label).visible = shown
			(entry.name_label as Label).visible = shown
			(entry.info as Label).visible = shown
			(entry.marker as Label).position = Vector2(0, slot * ENTRY_PITCH)
			(entry.name_label as Label).position = Vector2(MARKER_WIDTH, slot * ENTRY_PITCH)
			(entry.info as Label).position = Vector2(MARKER_WIDTH, slot * ENTRY_PITCH + 8)
			(entry.marker as Label).text = ">" if i == _selected else "" # the PartyRows marker contract

	func _label(text: String, x: int, width: int) -> Label:
		var label := Label.new()
		label.text = text
		label.clip_text = true
		label.position = Vector2(x, 0)
		label.size = Vector2(width, 8)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		GbcStage.apply_font(label, Color.BLACK)
		_root.add_child(label)
		return label
