extends Control

# On-screen name-entry grid for the creation flow, rebuilt as a GBC stage widget
# (restyle slice wave 0): a white plate PanelContainer with fonts.ttf@7 black ink
# that lives INSIDE the CreationScreen 160x144 stage (creation_screen.gd parents
# it there), so it can never collapse to 0x0 or drift off-window — the stage
# idiom's explicit-integer-offset rule makes the old anchor-preset defect class
# impossible. 28 cells in a 7x4 grid: A-Z, then DEL, then OK. Arrows wrap-nav
# (left/right +-1, up/down +-COLUMNS), Z presses the cell, X backs out to the
# NAME step. Letters append up to SessionState.PLAYER_NAME_MAX (FLAGGED cap —
# Gen-2-era 8); at the cap a letter press is ignored (DEL first). OK confirms
# whatever is shown, INCLUDING the empty name — the creation payload then falls
# back to DEFAULT_PLAYER_NAME. The cursor is the INVERTED cell (black cell +
# white glyph — authentic GBC inversion). The entry SURVIVES across opens
# (tweak, don't retype). Input arrives via creation_screen's _unhandled_input
# delegating to handle_input(): the screen ROOT owns input (battle idiom) —
# the stage is a pure render surface.

const SessionState := preload("res://scripts/runtime/session_state.gd")
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")

signal name_confirmed(text: String)
signal cancelled

const COLUMNS := 7
const CELL_DEL := 26
const CELL_OK := 27
const CELL_COUNT := 28
const CELL_W := 16 # stage px: selection target around the 8px glyph
const CELL_H := 13 # 8px glyph + row gap
const PLATE_RECT := Rect2(13, 22, 134, 100) # stage-centered (the geo witness)
const GRID_ORIGIN := Vector2i(11, 21) # the 7x16 grid centered in the plate

var plate: PanelContainer # the geo witness reads this member (new_game_flow_geo)
var _name_label: Label # "NAME — %s_" — the trailing _ is the insertion point
var _cells: Array = [] # Labels; index == cell id (0-25 letters, DEL, OK)
var _cursor_bg: ColorRect # the inverted-cell backing (black; glyph goes white)
var _text := ""
var _cursor := 0

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
	_name_label = GbcStage.make_label("", Vector2i(GRID_ORIGIN.x, 7), Color.BLACK, content)
	_name_label.size = Vector2(112, 8)
	var grid := Control.new()
	grid.position = Vector2(GRID_ORIGIN)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(grid)
	_cursor_bg = ColorRect.new()
	_cursor_bg.color = Color.BLACK
	_cursor_bg.size = Vector2(CELL_W, CELL_H - 2)
	_cursor_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(_cursor_bg)
	for i in CELL_COUNT:
		var cell := GbcStage.make_label(_cell_text(i), Vector2i((i % COLUMNS) * CELL_W, (i / COLUMNS) * CELL_H), Color.BLACK, grid)
		cell.size = Vector2(CELL_W, 8)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_cells.append(cell)
	# Explicit two-line wrap: Label autowrap proved unreliable at fonts.ttf@7
	# (the one-line render bled past the plate — off-stage ink); both lines fit
	# the 112px content width.
	var hint := GbcStage.make_label("(arrows: move\nZ: press   X: done)", Vector2i(GRID_ORIGIN.x, 79), Color.BLACK, content)
	hint.size = Vector2(112, 16)

func open_entry() -> void:
	_refresh()
	visible = true

func close_entry() -> void: # silent (screen hide): no cancelled — the closer owns its own state
	visible = false

# Creation-screen-delegated input (the screen root owns _unhandled_input).
# Returns true when consumed; Enter and friends stay unhandled so the router
# latch keeps working.
func handle_input(event: InputEvent) -> bool:
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
		return false
	return true

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
	# at the cap a letter press is ignored (the event is still consumed)
	_refresh()

func _refresh() -> void:
	for i in CELL_COUNT:
		(_cells[i] as Label).add_theme_color_override("font_color", Color.WHITE if i == _cursor else Color.BLACK)
	_cursor_bg.position = Vector2((_cursor % COLUMNS) * CELL_W, (_cursor / COLUMNS) * CELL_H - 1)
	_name_label.text = "NAME — %s_" % _text

func _cell_text(index: int) -> String:
	if index == CELL_DEL:
		return "DEL"
	if index == CELL_OK:
		return "OK"
	return char(65 + index) # A-Z
