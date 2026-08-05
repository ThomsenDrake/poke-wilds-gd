extends RefCounted

# Shared GBC widget library (menu restyle slice, wave 0): row lists, cursors,
# white plates, and hint labels for the 160x144 stages built by gbc_stage.gd.
# All geometry is absolute integer offsets in stage space. Ink contract:
# black ink on white plates (cursor: black battle/arrow_right1.png); the white
# cursor is for dark backings only (arrow_right_white2.png). Labels use
# fonts.ttf@7 on an 8px row pitch (the text_oracle raster contract).

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const BLACK_CURSOR_PATH := "res://pokewilds/battle/arrow_right1.png" # 8x8
const WHITE_CURSOR_PATH := "res://pokewilds/arrow_right_white2.png" # 7x9
const HINT_POS := Vector2i(8, 104) # 8px into the 48px bottom textbox band


# Cursor factories (NEAREST, input-ignoring, native texture size).
static func black_cursor() -> TextureRect:
	return _cursor(load(BLACK_CURSOR_PATH))


static func white_cursor() -> TextureRect:
	return _cursor(load(WHITE_CURSOR_PATH))


static func _cursor(texture: Texture2D) -> TextureRect:
	var cursor := TextureRect.new()
	cursor.texture = texture
	cursor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cursor.stretch_mode = TextureRect.STRETCH_KEEP
	cursor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if texture != null:
		cursor.size = texture.get_size()
	return cursor


# Row list on a host stage: Label rows at 8px pitch from origin + an arrow
# cursor left of the selected row. ink defaults to black (white plates); pass
# cursor_texture to override the black arrow (white cursor on dark backing).
static func row_list(stage: Control, origin: Vector2i, ink: Color = Color.BLACK,
		cursor_texture: Texture2D = null) -> RowList:
	var list := RowList.new()
	var texture: Texture2D = cursor_texture if cursor_texture != null else load(BLACK_CURSOR_PATH)
	var cursor := _cursor(texture)
	list.setup(stage, Vector2(origin), cursor,
			func(label: Label) -> void: GbcStage.apply_font(label, ink))
	return list


# White plate: white fill + 1px black border ColorRects, absolute integer
# rect (crisp GBC plate, no stretch risk). Returns the plate root Control;
# plate-local children use offsets relative to the plate's top-left.
static func plate(rect: Rect2, parent: Control) -> Control:
	var root := Control.new()
	root.name = "Plate"
	root.position = rect.position.floor()
	root.size = rect.size.floor()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(root)
	var w := int(root.size.x)
	var h := int(root.size.y)
	_bar(root, Rect2i(1, 1, w - 2, h - 2), Color.WHITE)
	_bar(root, Rect2i(0, 0, w, 1), Color.BLACK)
	_bar(root, Rect2i(0, h - 1, w, 1), Color.BLACK)
	_bar(root, Rect2i(0, 0, 1, h), Color.BLACK)
	_bar(root, Rect2i(w - 1, 0, 1, h), Color.BLACK)
	return root


# Bottom-band hint Label (fonts.ttf@7, black ink, at HINT_POS).
static func hint_label(text: String, parent: Control) -> Label:
	return GbcStage.make_label(text, HINT_POS, Color.BLACK, parent)


static func _bar(parent: Control, rect: Rect2i, color: Color) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = color
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.position = Vector2(rect.position)
	bar.size = Vector2(rect.size)
	parent.add_child(bar)
	return bar


# Stateful row-list widget. Lives under its own Rows Control so screens can
# show/hide the whole widget via root().visible. row_rect()/cursor_rect() are
# STAGE-local (mouse hit tests + audits). set_rows() resets the selection to
# row 0. move(dir) wraps (wrapi): dir 1 = down, -1 = up.
class RowList extends RefCounted:
	const PITCH := 8
	const CURSOR_GAP := 2

	var _root: Control
	var _cursor: TextureRect
	var _rows: Array = []
	var _selected := 0
	var _apply_font: Callable

	func setup(stage: Control, origin: Vector2, cursor: TextureRect,
			apply_font_cb: Callable) -> void:
		_apply_font = apply_font_cb
		_root = Control.new()
		_root.name = "Rows"
		_root.position = origin
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(_root)
		_cursor = cursor
		_root.add_child(_cursor)

	func set_rows(texts: Array) -> void:
		for row in _rows:
			row.queue_free()
		_rows.clear()
		for i in texts.size():
			var label := Label.new()
			label.text = str(texts[i])
			label.position = Vector2(0, i * PITCH)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_apply_font.call(label)
			label.size = label.get_combined_minimum_size()
			_root.add_child(label)
			_rows.append(label)
		_selected = 0
		_place_cursor()

	func select(index: int) -> void:
		if _rows.is_empty():
			return
		_selected = wrapi(index, 0, _rows.size())
		_place_cursor()

	func move(dir: int) -> void:
		if _rows.is_empty():
			return
		_selected = wrapi(_selected + dir, 0, _rows.size())
		_place_cursor()

	func selected() -> int:
		return _selected

	func row_count() -> int:
		return _rows.size()

	func row_text(index: int) -> String:
		return _rows[index].text

	func row_texts() -> Array:
		var texts: Array = []
		for row in _rows:
			texts.append(row.text)
		return texts

	func row_rect(index: int) -> Rect2:
		var label: Label = _rows[index]
		return Rect2(_root.position + label.position, label.size)

	func cursor_rect() -> Rect2:
		return Rect2(_root.position + _cursor.position, _cursor.size)

	func root() -> Control:
		return _root

	func _place_cursor() -> void:
		_cursor.visible = not _rows.is_empty()
		_cursor.position = Vector2(-(_cursor.size.x + CURSOR_GAP), _selected * PITCH)
