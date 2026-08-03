extends Control

# NEW GAME's custom world-seed entry, added by StartMenu at runtime (no scene
# node: start_menu.gd sits at the 220 ui wall — the menu_context.gd extraction
# precedent). RANDOM stays the ONE-PRESS default: the MessageBox confirm's Z
# answers straight (the menu_save smoke + input_gate part D drivers pin that
# single tap), and this prompt opens ONLY from the confirm-phase left/right
# gesture, a tap those drivers never perform. No LineEdit/SpinBox exists in the
# repo, so digits enter by typing; ←/→ moves the cursor, ↑/↓ bumps the selected
# digit, Backspace deletes; Z starts the game with the shown seed, X backs out
# to the menu. Pure input UI — no rng, no game state: the chosen seed rides
# _call_context("new_game", [seed]) into game_runtime.new_game(custom_seed).

signal seed_confirmed(seed_value: int)
signal cancelled

const MAX_SEED := 2147483647 # 0x7fffffff: game_runtime's world_seed mask (the random draw's range)

var _label: Label
var _value := 0 # the entry SURVIVES across opens (tweak a previous seed); first open shows 0
var _cursor := 0


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dim := ColorRect.new() # the StartMenu Dim shade
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var panel := PanelContainer.new() # the MessageBox panel placement, below the toast band
	panel.offset_left = 8.0
	panel.offset_top = 64.0
	panel.offset_right = 532.0
	panel.offset_bottom = 168.0
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	margin.add_child(_label)
	panel.add_child(margin)
	add_child(panel)


func open_prompt() -> void:
	_refresh()
	visible = true


func close_prompt() -> void: # silent (menu hide): no cancelled — the closer owns its own state
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("action_a"):
		visible = false
		seed_confirmed.emit(_value)
	elif event.is_action_pressed("action_b"):
		visible = false
		cancelled.emit()
	elif event.is_action_pressed("move_left", true):
		_move_cursor(-1)
	elif event.is_action_pressed("move_right", true):
		_move_cursor(1)
	elif event.is_action_pressed("move_up", true):
		_bump_digit(1)
	elif event.is_action_pressed("move_down", true):
		_bump_digit(-1)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if key.unicode >= 48 and key.unicode <= 57:
			_append_digit(key.unicode - 48)
		elif key.keycode == KEY_BACKSPACE:
			_backspace()
		else:
			return # Enter and friends stay unhandled (the menu toggle keeps working)
	else:
		return
	get_viewport().set_input_as_handled()


func _move_cursor(delta: int) -> void:
	_cursor = clampi(_cursor + delta, 0, str(_value).length() - 1)
	_refresh()


func _bump_digit(delta: int) -> void:
	var digits := str(_value)
	var bumped := posmod(digits.unicode_at(_cursor) - 48 + delta, 10)
	var next := int(digits.left(_cursor) + str(bumped) + digits.substr(_cursor + 1))
	if next > MAX_SEED:
		return # the 0x7fffffff cap refuses the bump too (the typed-entry guard's precedent)
	_value = next
	_cursor = clampi(_cursor, 0, str(_value).length() - 1) # a bumped leading zero shrinks the string
	_refresh()


func _append_digit(digit: int) -> void:
	var next := _value * 10 + digit
	if next > MAX_SEED:
		return # the 0x7fffffff cap refuses the key; Backspace first to make room
	_value = next
	_cursor = str(_value).length() - 1
	_refresh()


func _backspace() -> void:
	_value /= 10
	_cursor = str(_value).length() - 1
	_refresh()


func _refresh() -> void:
	var digits := str(_value)
	_cursor = clampi(_cursor, 0, digits.length() - 1)
	var marked := digits.left(_cursor) + "[" + digits[_cursor] + "]" + digits.substr(_cursor + 1)
	_label.text = "NEW GAME — CUSTOM SEED\n%s\nType digits; ←/→ pick a digit; ↑/↓ change it; Backspace deletes.\n(Z: Start   X: Back)" % marked
