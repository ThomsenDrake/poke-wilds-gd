extends Control

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")

signal submitted(message: String)
signal cancelled

var _editor: TextEdit
var _status: Label
var _in_flight := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func open_dialog() -> void:
	if _in_flight:
		return
	_editor.text = ""
	_editor.editable = true
	_status.text = "Enter: Send   Shift+Enter: New line   Esc/X: Cancel"
	visible = true
	_editor.grab_focus()


func show_sending() -> void:
	_in_flight = true
	_editor.editable = false
	_status.text = "Sending..."


func show_result(text: String) -> void:
	_status.text = text


func close_dialog() -> void:
	visible = false
	_in_flight = false
	_editor.release_focus()


func _input(event: InputEvent) -> void:
	if not visible or _in_flight:
		return
	if event is InputEventKey and event.pressed and event.keycode == Key.KEY_ESCAPE:
		_cancel_pressed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("action_b"):
		_cancel_pressed()
		get_viewport().set_input_as_handled()


func _on_editor_gui_input(event: InputEvent) -> void:
	if _in_flight or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == Key.KEY_ENTER or event.keycode == Key.KEY_KP_ENTER:
		if event.shift_pressed:
			_editor.insert_text_at_caret("\n")
		else:
			_send_pressed()
		_editor.accept_event()


func _on_text_changed() -> void:
	if _editor.text.length() <= 1000:
		return
	var caret_line := _editor.get_caret_line()
	var caret_column := _editor.get_caret_column()
	_editor.text = _editor.text.left(1000)
	_editor.set_caret_line(mini(caret_line, _editor.get_line_count() - 1))
	_editor.set_caret_column(caret_column)


func _send_pressed() -> void:
	if _in_flight:
		return
	var message := _editor.text.strip_edges()
	if message.is_empty():
		_status.text = "Please describe what went wrong."
		return
	_in_flight = true
	submitted.emit(message)


func _cancel_pressed() -> void:
	if _in_flight:
		return
	cancelled.emit()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "ReportPanel"
	panel.custom_minimum_size = Vector2(600, 420)
	var style := StyleBoxFlat.new()
	style.bg_color = Color.WHITE
	style.border_color = Color.BLACK
	style.set_border_width_all(5)
	style.set_corner_radius_all(0)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -300
	panel.offset_top = -210
	panel.offset_right = 300
	panel.offset_bottom = 210
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	panel.add_child(rows)
	rows.add_child(_label("Report a bug", 20))
	rows.add_child(_label("What went wrong?", 15))
	_editor = TextEdit.new()
	_editor.name = "Description"
	_editor.custom_minimum_size = Vector2(550, 190)
	_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_editor.accessibility_name = "Bug description"
	_editor.gui_input.connect(_on_editor_gui_input)
	_editor.text_changed.connect(_on_text_changed)
	_editor.add_theme_font_override("font", GbcStage.font())
	_editor.add_theme_font_size_override("font_size", 14)
	rows.add_child(_editor)
	var disclosure := _label("Your message is posted publicly; screenshot, save, and diagnostics stay private.", 11)
	disclosure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(disclosure)
	_status = _label("", 11)
	_status.accessibility_live = DisplayServer.AccessibilityLiveMode.LIVE_POLITE
	rows.add_child(_status)


func _label(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", GbcStage.font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color.BLACK)
	return label
