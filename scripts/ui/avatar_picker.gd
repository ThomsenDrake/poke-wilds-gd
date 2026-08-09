extends Control

# Avatar-set picker for the creation flow, rebuilt as a GBC stage widget
# (restyle slice wave 0): a white plate PanelContainer that lives INSIDE the
# CreationScreen 160x144 stage (creation_screen.gd parents it there), so it can
# never collapse to 0x0 or drift off-window — explicit integer offsets only.
# AVATARS is the SORTED list of the 24 shipped player sets (verified complete by
# ls pokewilds/player/*-walking.png). The grid shows one cell per set: an
# AtlasTexture over the walking sheet, region (0,0,16,16) = frame 0 down-idle
# (the canonical facing pose, player_sprite_frames convention), NEAREST
# filtered — plus a x4 preview of the highlighted set and its name line. The
# cursor (a black selection frame on the white plate) SURVIVES across opens.
# Z confirms the highlighted set, X backs out to the AVATAR step. A missing
# sheet degrades to a placeholder ColorRect cell (never crash). Input arrives
# via creation_screen delegating to handle_input() — the screen ROOT owns
# _unhandled_input (battle idiom); the stage is a pure render surface.

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")

signal avatar_confirmed(avatar_name: String)
signal cancelled

const AVATARS := ["ben", "brendan", "calem", "chase", "elaine", "gloria", "gold", "hilbert", "hilda", "kate",
	"kellyn", "kris", "leaf", "lucas", "lunick", "lyra", "mark", "may", "mint", "nate", "rosa", "serena", "summer", "victor"]
const COLUMNS := 6
const FRAME := Rect2(0, 0, 16, 16) # walking-sheet frame 0 = down-idle
const CELL := 16 # stage px: native sheet frame, NEAREST
const PITCH := 17 # 16px cell + 1px gap
const PLATE_RECT := Rect2(24, 2, 112, 140) # fully on-stage (the geo witness); the extra 2px lift the grid's last row off the bottom border

var plate: PanelContainer # the geo witness reads this member (new_game_flow_geo)
var _name_label: Label
var _preview: TextureRect # the highlighted avatar at x4 (16x16 -> 64x64), NEAREST
var _cells: Array = [] # Control per avatar: TextureRect, or ColorRect placeholder
var _textures: Array = [] # Texture2D per avatar (null when the sheet is missing)
var _cursor_frame: Control # black selection frame around the highlighted cell
var _cursor := 0 # persists across opens (seed_prompt precedent)

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate = PanelContainer.new()
	plate.name = "Plate"
	plate.position = PLATE_RECT.position
	plate.size = PLATE_RECT.size
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new() # the white plate with a 1px black border
	style.bg_color = Color.WHITE
	style.border_color = Color.BLACK
	style.set_border_width_all(1)
	style.set_content_margin_all(0.0)
	plate.add_theme_stylebox_override("panel", style)
	add_child(plate)
	var content := Control.new() # PanelContainer sizes it to the plate rect
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(content)
	_preview = TextureRect.new()
	_preview.position = Vector2(2, 2)
	_preview.size = Vector2(64, 64)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_preview)
	_name_label = GbcStage.make_label("", Vector2i(68, 30), Color.BLACK, content)
	_name_label.size = Vector2(42, 8)
	var grid := Control.new()
	grid.position = Vector2(5, 69)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(grid)
	for avatar_name in AVATARS:
		var texture := _sheet(avatar_name)
		_textures.append(texture)
		var cell: Control
		if texture != null:
			var rect := TextureRect.new()
			rect.texture = texture
			rect.size = Vector2(CELL, CELL)
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP
			rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			cell = rect
		else:
			var placeholder := ColorRect.new() # a missing sheet never crashes the picker
			placeholder.size = Vector2(CELL, CELL)
			placeholder.color = Color(0.3, 0.3, 0.35, 1.0)
			cell = placeholder
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.position = Vector2((_cells.size() % COLUMNS) * PITCH, (_cells.size() / COLUMNS) * PITCH)
		grid.add_child(cell)
		_cells.append(cell)
	_cursor_frame = Control.new() # 4 black bars around the highlighted cell
	_cursor_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(_cursor_frame)
	for bar in [Rect2(0, 0, CELL + 2, 1), Rect2(0, CELL + 1, CELL + 2, 1), Rect2(0, 0, 1, CELL + 2), Rect2(CELL + 1, 0, 1, CELL + 2)]:
		var rect := ColorRect.new()
		rect.color = Color.BLACK
		rect.position = Vector2(bar.position)
		rect.size = Vector2(bar.size)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cursor_frame.add_child(rect)

func open_picker() -> void:
	_refresh()
	visible = true

func close_picker() -> void: # silent (screen hide): no cancelled — the closer owns its own state
	visible = false

# Creation-screen-delegated input (the screen root owns _unhandled_input).
# Returns true when consumed; Enter and friends stay unhandled (router latch).
func handle_input(event: InputEvent) -> bool:
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
		return false
	return true

func _move(delta: int) -> void:
	_cursor = posmod(_cursor + delta, AVATARS.size())
	_refresh()

func _refresh() -> void:
	_preview.texture = _textures[_cursor]
	_name_label.text = AVATARS[_cursor]
	_cursor_frame.position = Vector2((_cursor % COLUMNS) * PITCH - 1, (_cursor / COLUMNS) * PITCH - 1)

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
