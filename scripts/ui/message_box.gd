extends Control

@onready var _label: Label = $PanelContainer/MarginContainer/Label
@onready var _timer: Timer = $Timer


func _ready() -> void:
	visible = false
	_timer.timeout.connect(_on_timeout)


func show_message(text: String, duration_seconds: float = 2.0) -> void:
	_label.text = text
	visible = true
	_timer.start(max(duration_seconds, 0.1))


func _on_timeout() -> void:
	visible = false
