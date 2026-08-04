extends Control

# Avatar-set picker for the creation flow (title-flow slice), added by
# creation_screen.gd at runtime (no scene node — the seed_prompt.gd precedent).
# AVATARS is the SORTED list of the 24 shipped player sets (verified complete by
# ls pokewilds/player/*-walking.png). The grid shows one cell per set: an
# AtlasTexture over the walking sheet, region (0,0,16,16) = frame 0 down-idle (the
# canonical facing pose, player_sprite_frames convention), NEAREST filtered — plus
# a x4 preview of the highlighted set and its name line. The cursor SURVIVES across
# opens (seed_prompt precedent). Z confirms the highlighted set, X backs out to the
# AVATAR step. A missing sheet degrades to a placeholder ColorRect cell (never
# crash). Pure input UI — no rng, no game state; the confirmed name rides
# session.player_avatar into PlayerAvatar.set_avatar via begin_created_game.

signal avatar_confirmed(avatar_name: String)
signal cancelled

const AVATARS := ["ben", "brendan", "calem", "chase", "elaine", "gloria", "gold", "hilbert", "hilda", "kate",
	"kellyn", "kris", "leaf", "lucas", "lunick", "lyra", "mark", "may", "mint", "nate", "rosa", "serena", "summer", "victor"]
const COLUMNS := 6
const FRAME := Rect2(0, 0, 16, 16) # walking-sheet frame 0 = down-idle
const COLOR_CURSOR := Color(1.0, 0.85, 0.3, 1.0)
const COLOR_IDLE := Color(1.0, 1.0, 1.0, 1.0)

var _cells: Array = [] # Control per avatar: TextureRect, or a ColorRect placeholder when the sheet is missing
var _textures: Array = [] # Texture2D per avatar (null when the sheet is missing)
var _preview: TextureRect
var _name_label: Label
var _cursor := 0 # persists across opens (seed_prompt precedent)

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
	panel.offset_top = -128.0
	panel.offset_right = 168.0
	panel.offset_bottom = 128.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_preview = TextureRect.new() # the highlighted avatar at x4 scale (16x16 -> 64x64)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED # the BattleView background convention
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.custom_minimum_size = Vector2(64, 64)
	_preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(_preview)
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_name_label)
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for avatar_name in AVATARS:
		var texture := _sheet(avatar_name)
		_textures.append(texture)
		var cell: Control
		if texture != null:
			var rect := TextureRect.new()
			rect.texture = texture
			rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			cell = rect
		else:
			var placeholder := ColorRect.new() # a missing sheet never crashes the picker
			placeholder.custom_minimum_size = Vector2(16, 16)
			placeholder.color = Color(0.3, 0.3, 0.35, 1.0)
			cell = placeholder
		grid.add_child(cell)
		_cells.append(cell)
	vbox.add_child(grid)
	var hint := Label.new()
	hint.text = "(arrows: move   Z: choose   X: done)"
	hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(hint)
	margin.add_child(vbox)
	panel.add_child(margin)
	add_child(panel)

func open_picker() -> void:
	_refresh()
	visible = true

func close_picker() -> void: # silent (screen hide): no cancelled — the closer owns its own state
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("action_a"):
		visible = false
		avatar_confirmed.emit(AVATARS[_cursor])
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
	_cursor = posmod(_cursor + delta, AVATARS.size())
	_refresh()

func _refresh() -> void:
	for i in AVATARS.size():
		(_cells[i] as CanvasItem).modulate = COLOR_CURSOR if i == _cursor else COLOR_IDLE
	_preview.texture = _textures[_cursor]
	_name_label.text = AVATARS[_cursor]

# Atlas over frame 0 of the walking sheet; null when the sheet is absent (the cell
# degrades to a placeholder — load is guarded so the picker never crashes).
func _sheet(avatar_name: String) -> Texture2D:
	var path := "res://pokewilds/player/%s-walking.png" % avatar_name
	if not ResourceLoader.exists(path):
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = load(path)
	atlas.region = FRAME
	return atlas
