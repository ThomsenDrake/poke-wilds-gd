extends RefCounted

# Shared single-list GBC stage composition for the wave-2 menu screens
# (options / camp / way-stone selector; the Rows widget is also reused by the
# storage screen's action plate — the title_screen_stage.gd extraction
# precedent). Builds inside the 160x144 ScreenStage: a guarded full-stage gsc
# background, a white title plate, a white rows plate with a clipped/dimmable/
# windowed black-ink row list (black arrow cursor — the white-plate cursor
# rule), and autowrap detail/hint plates. All stage children carry EXPLICIT
# integer offsets (never set_anchors_preset on a parented node). Row label
# strings are NEVER rewritten — over-long rows clip at the plate interior
# (clip_text) so the .text contract survives intact for the scenario seams.

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const BACKGROUND_PATH := "res://pokewilds/menu/gsc/background1.png"


# opts: title String (+ title_rect), rows_rect Rect2, max_visible int (0=all),
# detail_rect Rect2 (zero size = no detail plate), hint String + hint_rect,
# background bool (default true) + background_path.
# Returns {rows: Rows, title_label, detail_label, hint_label}.
static func build(stage: Control, opts: Dictionary) -> Dictionary:
	if bool(opts.get("background", true)):
		art(stage, str(opts.get("background_path", BACKGROUND_PATH)))
	var title_label: Label = null
	if opts.has("title"):
		var title_rect: Rect2 = opts.get("title_rect", Rect2(40, 6, 80, 14))
		var title_plate := GbcWidgets.plate(title_rect, stage)
		title_label = plate_label(title_plate, Rect2(2, 3, title_rect.size.x - 4, 8), str(opts["title"]))
		title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var rows_rect: Rect2 = opts.get("rows_rect", Rect2(8, 24, 144, 64))
	var rows := Rows.new()
	rows.setup(GbcWidgets.plate(rows_rect, stage), int(opts.get("max_visible", 0)))
	var detail_label: Label = null
	var detail_rect: Rect2 = opts.get("detail_rect", Rect2())
	if detail_rect.size.x > 0.0:
		detail_label = wrapped_label(GbcWidgets.plate(detail_rect, stage),
				Rect2(Vector2(3, 2), detail_rect.size - Vector2(6, 4)))
	var hint_label: Label = null
	var hint_rect: Rect2 = opts.get("hint_rect", Rect2())
	if hint_rect.size.x > 0.0:
		hint_label = wrapped_label(GbcWidgets.plate(hint_rect, stage),
				Rect2(Vector2(3, 1), hint_rect.size - Vector2(6, 2)))
		hint_label.text = str(opts.get("hint", ""))
	return {"rows": rows, "title_label": title_label, "detail_label": detail_label, "hint_label": hint_label}


# Full-stage NEAREST TextureRect; a missing asset degrades to the opaque black
# backing (never crash, never edit the submodule — the title art precedent).
static func art(parent: Control, path: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.position = Vector2.ZERO
	rect.size = GbcStage.STAGE_SIZE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(path):
		rect.texture = load(path)
	parent.add_child(rect)
	return rect


# Root _gui_input click route (the old ItemList item_clicked path): maps a
# root-local mouse position back into stage space (battle _stage_point idiom)
# and returns the hit row index, or -1 when the click lands outside every row.
static func hit_row(display: TextureRect, position: Vector2, rows: Rows) -> int:
	var point = GbcStage.stage_point(display, position)
	if point == null:
		return -1
	for i in rows.row_count():
		if rows.row_rect(i).has_point(point):
			return i
	return -1


# Single-line plate-interior Label (fonts.ttf@7, black ink, clipped to rect).
static func plate_label(parent: Control, rect: Rect2, text: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.clip_text = true
	label.position = rect.position.floor()
	label.size = rect.size.floor()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GbcStage.apply_font(label, Color.BLACK)
	parent.add_child(label)
	return label


# Autowrap plate-interior Label (detail/hint/summary text).
static func wrapped_label(parent: Control, rect: Rect2) -> Label:
	var label := plate_label(parent, rect)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


# Clipped, per-row-ink, windowed row list on a white plate (black arrow
# cursor). set_rows(texts, inks) resets the selection to row 0; inks shorter
# than texts defaults to black. select()/move() wrap (wrapi). row_rect() is
# STAGE-local (root _gui_input hit tests + audits). max_visible > 0 scrolls a
# window so the selected row stays visible (the old ItemList scroll contract).
class Rows extends RefCounted:
	const PITCH := 8
	const CURSOR_GAP := 2

	var _root: Control
	var _cursor: TextureRect
	var _labels: Array = []
	var _selected := 0
	var _window := 0
	var _max_visible := 0
	var _width := 0
	var _plate_pos := Vector2.ZERO

	func setup(plate: Control, max_visible: int = 0) -> void:
		_max_visible = max_visible
		_plate_pos = plate.position
		_width = int(plate.size.x) - 16
		_root = Control.new()
		_root.name = "Rows"
		_root.position = Vector2(12, 3)
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_child(_root)
		_cursor = GbcWidgets.black_cursor()
		_root.add_child(_cursor)

	func set_rows(texts: Array, inks: Array = []) -> void:
		for label in _labels:
			(label as Label).queue_free()
		_labels.clear()
		for i in texts.size():
			var ink: Color = inks[i] if i < inks.size() and inks[i] is Color else Color.BLACK
			var label := Label.new()
			label.text = str(texts[i])
			label.clip_text = true
			label.size = Vector2(_width, PITCH)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			GbcStage.apply_font(label, ink)
			_root.add_child(label)
			_labels.append(label)
		_selected = 0
		_window = 0
		_layout()

	func select(index: int) -> void:
		if _labels.is_empty():
			return
		_selected = wrapi(index, 0, _labels.size())
		_layout()

	func move(direction: int) -> void:
		select(_selected + direction)

	func selected() -> int:
		return _selected

	func row_count() -> int:
		return _labels.size()

	func row_text(index: int) -> String:
		return (_labels[index] as Label).text

	func row_texts() -> Array:
		var texts: Array = []
		for label in _labels:
			texts.append((label as Label).text)
		return texts

	func row_rect(index: int) -> Rect2:
		var label: Label = _labels[index]
		return Rect2(_plate_pos + _root.position + label.position, label.size)

	func root() -> Control:
		return _root

	func _layout() -> void:
		var visible_count := _labels.size() if _max_visible <= 0 else mini(_max_visible, _labels.size())
		if _max_visible > 0 and not _labels.is_empty():
			_window = clampi(_window, 0, maxi(0, _labels.size() - visible_count))
			if _selected < _window:
				_window = _selected
			elif _selected >= _window + visible_count:
				_window = _selected - visible_count + 1
		for i in _labels.size():
			var label: Label = _labels[i]
			var slot := i - _window
			label.visible = slot >= 0 and slot < visible_count
			label.position = Vector2(0, slot * PITCH)
		_cursor.visible = not _labels.is_empty()
		_cursor.position = Vector2(-(_cursor.size.x + CURSOR_GAP), (_selected - _window) * PITCH)
