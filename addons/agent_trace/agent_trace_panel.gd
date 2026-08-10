@tool
extends VBoxContainer

const MAX_LINES := 4000

var _lines: Array[String] = []
var _paused := false
var _filter: LineEdit
var _output: RichTextLabel
var _count: Label
var _pause_button: Button


func _init() -> void:
	var toolbar := HBoxContainer.new()
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter (event / source / payload substring)"
	_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter.text_changed.connect(func(_text: String) -> void: _rebuild())
	toolbar.add_child(_filter)
	_pause_button = Button.new()
	_pause_button.text = "Pause"
	_pause_button.tooltip_text = "Freeze the view; the stream keeps buffering"
	_pause_button.pressed.connect(_toggle_pause)
	toolbar.add_child(_pause_button)
	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_clear)
	toolbar.add_child(clear_button)
	_count = Label.new()
	toolbar.add_child(_count)
	add_child(toolbar)
	_output = RichTextLabel.new()
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.scroll_following = true
	_output.selection_enabled = true
	add_child(_output)
	_update_count()


func _ready() -> void:
	var mono := get_theme_font("source", "EditorFonts")
	if mono != null:
		_output.add_theme_font_override("normal_font", mono)


func ingest(record: Dictionary, raw: String) -> void:
	_lines.append(_format(record, raw))
	if _lines.size() > MAX_LINES * 2:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
		_rebuild()
	elif not _paused and _passes(_lines[-1]):
		_output.append_text(_lines[-1] + "\n")
		_update_count()


func _format(record: Dictionary, raw: String) -> String:
	if record.is_empty():
		return raw
	var event := str(record.get("event", "?"))
	var source := str(record.get("source", "?"))
	var ts := str(record.get("ts_msec", 0))
	var compact := JSON.stringify(record.get("payload", {}))
	return "%s %s %s %s" % [ts.rpad(10), event.rpad(30), source, compact]


func _passes(line: String) -> bool:
	var needle := _filter.text.strip_edges().to_lower()
	return needle.is_empty() or line.to_lower().contains(needle)


func _rebuild() -> void:
	_output.clear()
	for line in _lines:
		if _passes(line):
			_output.append_text(line + "\n")
	_update_count()


func _toggle_pause() -> void:
	_paused = not _paused
	_pause_button.text = "Resume" if _paused else "Pause"
	if not _paused:
		_rebuild()


func _clear() -> void:
	_lines.clear()
	_output.clear()
	_update_count()


func _update_count() -> void:
	_count.text = "%d events" % _lines.size()
