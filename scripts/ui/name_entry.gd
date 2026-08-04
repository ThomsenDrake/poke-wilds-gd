extends Control

# On-screen name-entry grid for the creation flow (title-flow slice), added by
# creation_screen.gd at runtime (no scene node — the seed_prompt.gd precedent).
# 28 cells in a 7x4 grid: A-Z, then DEL, then OK. Arrows wrap-nav (left/right +-1,
# up/down +-COLUMNS), Z presses the cell, X backs out to the NAME step. Letters
# append up to SessionState.PLAYER_NAME_MAX (FLAGGED cap — Gen-2-era 8); at the cap
# a letter press is ignored (DEL first). OK confirms whatever is shown, INCLUDING
# the empty name — the creation payload then falls back to DEFAULT_PLAYER_NAME.
# Type-to-entry is impossible: letters collide with the InputMap (A/D/W/S move, Z/X
# confirm/cancel), which is why this is a grid keyboard. Pure input UI — no rng, no
# game state. The entry SURVIVES across opens (seed_prompt precedent: tweak, don't retype).

const SessionState := preload("res://scripts/runtime/session_state.gd")

signal name_confirmed(text: String)
signal cancelled

const COLUMNS := 7
const CELL_DEL := 26
const CELL_OK := 27
const CELL_COUNT := 28
const COLOR_CURSOR := Color(1.0, 0.85, 0.3, 1.0)
const COLOR_IDLE := Color(0.9, 0.92, 0.96, 1.0)

var _cells: Array = [] # Labels; index == cell id (0-25 letters, DEL, OK)
var _name_label: Label
var _text := ""
var _cursor := 0

func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dim := ColorRect.new() # the seed_prompt Dim shade
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var panel := PanelContainer.new() # centered OVER the creation panel (added after it, so drawn on top)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -168.0
	panel.offset_top = -120.0
	panel.offset_right = 168.0
	panel.offset_bottom = 120.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_name_label)
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	for i in CELL_COUNT:
		var cell := Label.new()
		cell.text = _cell_text(i)
		cell.add_theme_font_size_override("font_size", 14)
		grid.add_child(cell)
		_cells.append(cell)
	vbox.add_child(grid)
	var hint := Label.new()
	hint.text = "(arrows: move   Z: press   X: done)"
	hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(hint)
	margin.add_child(vbox)
	panel.add_child(margin)
	add_child(panel)

func open_entry() -> void:
	_refresh()
	visible = true

func close_entry() -> void: # silent (screen hide): no cancelled — the closer owns its own state
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("action_a"):
		_activate()
	elif event.is_action_pressed("action_b"):
		visible = false
		cancelled.emit()
	elif event.is_action_pressed("move_left", true):
		_move(-1)
	elif event.is_action_pressed("move_right", true):
		_move(1)
	elif event.is_action_pressed("move_up", true):
		_move(-COLUMNS)
	elif event.is_action_pressed("move_down", true):
		_move(COLUMNS)
	else:
		return # Enter and friends stay unhandled (the router latch keeps working)
	get_viewport().set_input_as_handled()

func _move(delta: int) -> void:
	_cursor = posmod(_cursor + delta, CELL_COUNT)
	_refresh()

func _activate() -> void:
	if _cursor == CELL_DEL:
		_text = _text.left(_text.length() - 1)
	elif _cursor == CELL_OK:
		visible = false
		name_confirmed.emit(_text)
		return # already hidden — no refresh
	elif _text.length() < SessionState.PLAYER_NAME_MAX:
		_text += _cell_text(_cursor) # letters live below CELL_DEL
	# at the cap a letter press is ignored (the event is still consumed below)
	_refresh()

func _refresh() -> void:
	for i in CELL_COUNT:
		(_cells[i] as Label).modulate = COLOR_CURSOR if i == _cursor else COLOR_IDLE
	_name_label.text = "NAME — %s_" % _text # the trailing _ is the insertion point

func _cell_text(index: int) -> String:
	if index == CELL_DEL:
		return "DEL"
	if index == CELL_OK:
		return "OK"
	return char(65 + index) # A-Z
