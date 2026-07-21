extends Control

# Toast plus a yes/no confirm. show_message() is the timed toast; show_confirm()
# holds until Z confirms or X cancels and never auto-hides while confirming.
# StartMenu is a later tree sibling, so it gates its own input while a confirm
# is pending and lets those Z/X keys reach this box first (Main.tscn child
# order: MessageBox -> BattleView -> StartMenu).

signal confirmed
signal cancelled

@onready var _label: Label = $PanelContainer/MarginContainer/Label
@onready var _timer: Timer = $Timer

var _confirming := false


func _ready() -> void:
	visible = false
	_timer.timeout.connect(_on_timeout)


func show_message(text: String, duration_seconds: float = 2.0) -> void:
	if _confirming:
		# An unexpected toast supersedes the pending confirm; tell the owner so
		# it can drop its awaiting state instead of stranding the menu.
		_close_confirm()
		cancelled.emit()
	_label.text = text
	visible = true
	_timer.start(max(duration_seconds, 0.1))


func show_confirm(text: String) -> void:
	_timer.stop()
	_confirming = true
	_label.text = text + "\n(Z: Yes   X: No)"
	visible = true


func is_confirming() -> bool:
	return _confirming


# Programmatic hide (battle start, menu close): clears the confirm silently;
# the caller owns any awaiting state it no longer needs.
func hide_message() -> void:
	_confirming = false
	_timer.stop()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not _confirming:
		return
	if event.is_action_pressed("action_a"):
		_close_confirm()
		confirmed.emit()
	elif event.is_action_pressed("action_b"):
		_close_confirm()
		cancelled.emit()
	else:
		return
	get_viewport().set_input_as_handled()


func _close_confirm() -> void:
	_confirming = false
	visible = false


func _on_timeout() -> void:
	if not _confirming:
		visible = false
