extends RefCounted

# Seed digit row (menu restyle slice, wave 0): seed_prompt.gd's digit-editing
# state as a host-agnostic widget so the creation SEED step can carry an
# in-stage digit row. The typed-digit append / bump / backspace logic is
# PORTED VERBATIM from seed_prompt.gd:90-118 — MAX_SEED 0x7fffffff cap,
# "[d]" cursor marking, unicode 48-57 branch semantics. Pure state: the host
# owns the Label (reads display_text()/render()) and calls
# get_viewport().set_input_as_handled() when handle() returns true.

const MAX_SEED := 2147483647 # 0x7fffffff: game_runtime's world_seed mask (the random draw's range)

var _value := 0
var _cursor := 0
var _editing := false


func set_seed(value: int) -> void:
	_value = clampi(value, 0, MAX_SEED)
	_cursor = str(_value).length() - 1


func seed() -> int:
	return _value


func start_edit() -> void:
	_editing = true


func stop_edit() -> void:
	_editing = false


func editing_active() -> bool:
	return _editing


# Consumes SeedPrompt input while editing ONLY: arrows move the cursor / bump
# the digit, typed unicode digits append, Backspace deletes. Returns true when
# consumed (a bump/append refused by the cap still consumes, seed_prompt
# semantics). Z/X commit/cancel and edit toggles stay the host screen's.
func handle(event: InputEvent) -> bool:
	if not _editing:
		return false
	if event.is_action_pressed("move_left", true):
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
			return false # Enter and friends stay unhandled (the menu toggle keeps working)
	else:
		return false
	return true


# seed_prompt._refresh's "[d]" marking applied to any digit text (the host
# composes surrounding label copy itself).
func render(text: String) -> String:
	if text.is_empty():
		return text
	var marked := clampi(_cursor, 0, text.length() - 1)
	return text.left(marked) + "[" + text[marked] + "]" + text.substr(marked + 1)


func display_text() -> String:
	var digits := str(_value)
	_cursor = clampi(_cursor, 0, digits.length() - 1)
	return render(digits)


func _move_cursor(delta: int) -> void:
	_cursor = clampi(_cursor + delta, 0, str(_value).length() - 1)


func _bump_digit(delta: int) -> void:
	var digits := str(_value)
	var bumped := posmod(digits.unicode_at(_cursor) - 48 + delta, 10)
	var next := int(digits.left(_cursor) + str(bumped) + digits.substr(_cursor + 1))
	if next > MAX_SEED:
		return # the 0x7fffffff cap refuses the bump too (the typed-entry guard's precedent)
	_value = next
	_cursor = clampi(_cursor, 0, str(_value).length() - 1) # a bumped leading zero shrinks the string


func _append_digit(digit: int) -> void:
	var next := _value * 10 + digit
	if next > MAX_SEED:
		return # the 0x7fffffff cap refuses the key; Backspace first to make room
	_value = next
	_cursor = str(_value).length() - 1


func _backspace() -> void:
	_value /= 10
	_cursor = str(_value).length() - 1
