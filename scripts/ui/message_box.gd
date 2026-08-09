extends Control

# Toast plus a yes/no confirm, rendered as a Crystal GBC textbox band on a
# transparent 160x144 stage (gbc_stage idiom). show_message() is the timed toast
# (textbox_bg1 bottom band); show_confirm() holds until Z confirms or X cancels
# (textbox_bg2 bottom band) and never auto-hides while confirming.
# FROZEN API (scenarios read _label.text for toasts + is_confirming()): signals
# confirmed/cancelled; show_message/show_confirm/is_confirming/hide_message and
# the confirm suffix are byte-stable in meaning. The display carries z_index so
# the band draws OVER later $UI siblings (StartMenu/StorageScreen/CampMenu)
# without touching Main.tscn child order (visual_sweep_* read ../StorageScreen).

signal confirmed
signal cancelled

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const TOAST_ART := "res://pokewilds/textbox_bg1.png"
const CONFIRM_ART := "res://pokewilds/textbox_bg2.png"

var _label: Label
var _timer: Timer
var _art: TextureRect
var _stage: Control
var _display: TextureRect

var _confirming := false


func _ready() -> void:
	visible = false
	var built := GbcStage.build(self, {"opaque_backing": false, "transparent_bg": true})
	_stage = built["stage"]
	_display = built["display"]
	_display.z_index = 20 # over later $UI siblings; Main.tscn order stays untouched
	GbcStage.on_resized(self, _display)
	_art = TextureRect.new()
	_art.name = "TextboxArt"
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_art.offset_right = GbcStage.STAGE_SIZE.x
	_art.offset_bottom = GbcStage.STAGE_SIZE.y
	_stage.add_child(_art)
	_label = Label.new()
	_label.name = "TextLabel"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART # long confirms/toasts wrap inside the band — never bleed past its right edge
	GbcStage.apply_font(_label, Color.BLACK)
	_stage.add_child(_label)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timeout)
	add_child(_timer)


func show_message(text: String, duration_seconds: float = 2.0) -> void:
	if _confirming:
		# An unexpected toast supersedes the pending confirm; tell the owner so
		# it can drop its awaiting state instead of stranding the menu.
		_close_confirm()
		cancelled.emit()
	_art.texture = load(TOAST_ART)
	_set_band(false)
	_label.text = _ascii_arrows(text)
	visible = true
	_timer.start(max(duration_seconds, 0.1))


func show_confirm(text: String, key_hint: String = "") -> void:
	_timer.stop()
	_confirming = true
	_art.texture = load(CONFIRM_ART)
	_set_band(true)
	_label.text = _ascii_arrows(text + "\n(Z: Yes   X: No" + ("" if key_hint.is_empty() else "   " + key_hint) + ")") # an optional hint rides the answer line
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


# textbox_bg1 = opaque bottom 48 rows, textbox_bg2 = bottom 64 rows; put the ink
# inside the frame interior.
func _set_band(confirm: bool) -> void:
	_label.offset_left = 10
	_label.offset_right = 150
	_label.offset_top = (144 - 64 + 8) if confirm else (144 - 48 + 16)
	_label.offset_bottom = 140


# fonts.ttf lacks the U+2190-2193 arrows (they would render tofu); ASCII equivalents.
func _ascii_arrows(s: String) -> String:
	return s.replace("←", "<-").replace("→", "->").replace("↑", "^").replace("↓", "v")
