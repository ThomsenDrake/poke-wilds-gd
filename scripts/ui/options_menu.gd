extends Control
class_name OptionsMenu
## OptionsMenu - Game settings UI
## Allows adjusting volume, text speed, and battle animations

signal menu_closed()
signal settings_changed()

# Menu options
enum Option {
	MUSIC_VOLUME,
	SFX_VOLUME,
	TEXT_SPEED,
	BATTLE_ANIM,
	FULLSCREEN,
	WINDOW_SCALE,
	CAMERA_ZOOM,
	BACK
}

var selected_option: int = 0
var option_count: int = 8  # Updated for new options

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT
const ITEM_HEIGHT := 14  # Slightly smaller to fit more options

# Text speed names
const TEXT_SPEEDS := ["SLOW", "NORMAL", "FAST"]

# Volume levels (0-10)
const MAX_VOLUME := 10

# Node references
var cursor: Sprite2D


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create the options menu UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.18)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Title
	var title := Label.new()
	title.text = "OPTIONS"
	title.position = Vector2(58, 4)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)
	
	# Options panel
	var panel := Control.new()
	panel.name = "OptionsPanel"
	panel.position = Vector2(8, 20)
	add_child(panel)
	
	var panel_bg := ColorRect.new()
	panel_bg.color = Color(0.15, 0.18, 0.22)
	panel_bg.size = Vector2(144, 130)  # Taller to fit more options
	panel.add_child(panel_bg)
	
	# Create option rows
	_create_option_row(panel, 0, "MUSIC", "MusicValue")
	_create_option_row(panel, 1, "SOUND", "SFXValue")
	_create_option_row(panel, 2, "TEXT", "TextValue")
	_create_option_row(panel, 3, "BATTLE ANIM", "AnimValue")
	_create_option_row(panel, 4, "FULLSCREEN", "FullscreenValue")
	_create_option_row(panel, 5, "WINDOW", "WindowValue")
	_create_option_row(panel, 6, "ZOOM", "ZoomValue")
	
	# Back option
	var back_lbl := Label.new()
	back_lbl.name = "Back"
	back_lbl.text = "BACK"
	back_lbl.position = Vector2(12, 8 + 7 * ITEM_HEIGHT)
	back_lbl.add_theme_font_size_override("font_size", 8)
	back_lbl.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(back_lbl)
	
	# Cursor
	cursor = Sprite2D.new()
	cursor.texture = _create_cursor_texture()
	add_child(cursor)
	
	# Instructions
	var instructions := Label.new()
	instructions.text = "L/R:Change  F11:Fullscreen  Q/E:Zoom"
	instructions.position = Vector2(8, 156)
	instructions.add_theme_font_size_override("font_size", 6)
	instructions.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(instructions)


func _create_option_row(parent: Control, index: int, label_text: String, value_name: String) -> void:
	"""Create a single option row with label and value"""
	var y_pos := 8 + index * ITEM_HEIGHT
	
	# Label
	var lbl := Label.new()
	lbl.name = "Label" + str(index)
	lbl.text = label_text
	lbl.position = Vector2(12, y_pos)
	lbl.add_theme_font_size_override("font_size", 8)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	parent.add_child(lbl)
	
	# Value
	var val := Label.new()
	val.name = value_name
	val.text = "---"
	val.position = Vector2(90, y_pos)
	val.add_theme_font_size_override("font_size", 8)
	val.add_theme_color_override("font_color", Color.YELLOW)
	parent.add_child(val)
	
	# Left arrow
	var left_arrow := Label.new()
	left_arrow.name = "Left" + str(index)
	left_arrow.text = "<"
	left_arrow.position = Vector2(80, y_pos)
	left_arrow.add_theme_font_size_override("font_size", 8)
	left_arrow.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	parent.add_child(left_arrow)
	
	# Right arrow
	var right_arrow := Label.new()
	right_arrow.name = "Right" + str(index)
	right_arrow.text = ">"
	right_arrow.position = Vector2(130, y_pos)
	right_arrow.add_theme_font_size_override("font_size", 8)
	right_arrow.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	parent.add_child(right_arrow)


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(6, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(3):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.WHITE)
	return ImageTexture.create_from_image(image)


func open() -> void:
	"""Open the options menu"""
	selected_option = 0
	visible = true
	_update_values()
	_update_cursor()


func close() -> void:
	"""Close the options menu"""
	visible = false
	menu_closed.emit()


func _update_values() -> void:
	"""Update displayed values from settings"""
	var panel: Control = get_node("OptionsPanel")
	
	# Music volume
	var music_val: Label = panel.get_node_or_null("MusicValue")
	if music_val:
		var vol := int(GameManager.settings.music_volume * MAX_VOLUME)
		music_val.text = _get_volume_bar(vol)
	
	# SFX volume
	var sfx_val: Label = panel.get_node_or_null("SFXValue")
	if sfx_val:
		var vol := int(GameManager.settings.sfx_volume * MAX_VOLUME)
		sfx_val.text = _get_volume_bar(vol)
	
	# Text speed
	var text_val: Label = panel.get_node_or_null("TextValue")
	if text_val:
		var speed: int = GameManager.settings.text_speed
		text_val.text = TEXT_SPEEDS[clampi(speed, 0, 2)]
	
	# Battle animations
	var anim_val: Label = panel.get_node_or_null("AnimValue")
	if anim_val:
		anim_val.text = "ON" if GameManager.settings.battle_animations else "OFF"
	
	# Fullscreen
	var fullscreen_val: Label = panel.get_node_or_null("FullscreenValue")
	if fullscreen_val:
		fullscreen_val.text = "ON" if GameManager.settings.fullscreen else "OFF"
	
	# Window scale
	var window_val: Label = panel.get_node_or_null("WindowValue")
	if window_val:
		var scale: int = GameManager.settings.window_scale
		window_val.text = str(scale) + "x"
	
	# Camera zoom
	var zoom_val: Label = panel.get_node_or_null("ZoomValue")
	if zoom_val:
		var zoom: float = GameManager.settings.camera_zoom
		zoom_val.text = str(zoom) + "x"


func _get_volume_bar(level: int) -> String:
	"""Create a simple volume bar visualization"""
	var bar := ""
	for i in range(MAX_VOLUME):
		if i < level:
			bar += "|"
		else:
			bar += "."
	return bar


func _update_cursor() -> void:
	"""Update cursor position"""
	var panel: Control = get_node("OptionsPanel")
	cursor.position = panel.position + Vector2(4, 12 + selected_option * ITEM_HEIGHT)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_a"):
		_handle_confirm()
	elif event.is_action_pressed("button_b"):
		_handle_cancel()
	elif event.is_action_pressed("move_up"):
		_navigate(-1)
	elif event.is_action_pressed("move_down"):
		_navigate(1)
	elif event.is_action_pressed("move_left"):
		_adjust_value(-1)
	elif event.is_action_pressed("move_right"):
		_adjust_value(1)


func _navigate(dir: int) -> void:
	"""Navigate between options"""
	selected_option = clampi(selected_option + dir, 0, option_count - 1)
	_update_cursor()


func _adjust_value(dir: int) -> void:
	"""Adjust the current option's value"""
	match selected_option:
		Option.MUSIC_VOLUME:
			var vol: float = float(GameManager.settings.music_volume)
			vol = clampf(vol + dir * 0.1, 0.0, 1.0)
			GameManager.settings.music_volume = vol
			AudioManager.music_volume = vol
		
		Option.SFX_VOLUME:
			var vol: float = float(GameManager.settings.sfx_volume)
			vol = clampf(vol + dir * 0.1, 0.0, 1.0)
			GameManager.settings.sfx_volume = vol
			AudioManager.sfx_volume = vol
		
		Option.TEXT_SPEED:
			var speed: int = GameManager.settings.text_speed
			speed = clampi(speed + dir, 0, 2)
			GameManager.settings.text_speed = speed
		
		Option.BATTLE_ANIM:
			GameManager.settings.battle_animations = not GameManager.settings.battle_animations
		
		Option.FULLSCREEN:
			GameManager.toggle_fullscreen()
		
		Option.WINDOW_SCALE:
			var scale: int = GameManager.settings.window_scale
			scale = clampi(scale + dir, 1, 4)
			GameManager.set_window_scale(scale)
		
		Option.CAMERA_ZOOM:
			GameManager.adjust_camera_zoom(dir * GameManager.CAMERA_ZOOM_STEP)
	
	_update_values()
	settings_changed.emit()


func _handle_confirm() -> void:
	"""Handle A button press"""
	if selected_option == Option.BACK:
		close()
	else:
		# Toggle or cycle current option
		_adjust_value(1)


func _handle_cancel() -> void:
	"""Handle B button press"""
	close()
