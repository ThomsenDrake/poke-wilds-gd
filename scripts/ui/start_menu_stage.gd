extends RefCounted

# StartMenu stage composition EXTRACTED from start_menu.gd at the 220 ui wall
# (restyle slice wave 2; the title_screen_stage.gd / menu_context.gd extraction
# precedent). Builds the MenuCard inside the 160x144 ScreenStage: menu1.png
# full-stage art (the right-side double-border panel; load-guarded — a missing
# asset falls back to a composed white panel plate, never a crash) + a white
# plate over the panel interior (covers the art's etched sample text so the six
# ENTRIES own their rows) + the black-ink gbc_widgets row list with the black
# arrow cursor (white plate -> black cursor, the gbc_widgets ink rule).

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const MENU_ART := "res://pokewilds/menu/menu1.png"
const PANEL_RECT := Rect2(81, 0, 79, 127) # the art's panel bbox (pixel-verified)
const PLATE_RECT := Rect2(87, 6, 66, 116) # the panel interior, over the etched text
const ROWS_ORIGIN := Vector2i(98, 40) # 6 rows x 8px pitch, centered in the plate


static func build(stage: Control) -> Dictionary:
	var card := Control.new()
	card.name = "MenuCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(card)
	if ResourceLoader.exists(MENU_ART):
		var art := TextureRect.new()
		art.name = "MenuArt"
		art.texture = load(MENU_ART)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP # 160x144 art draws 1:1
		art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.offset_right = GbcStage.STAGE_SIZE.x
		art.offset_bottom = GbcStage.STAGE_SIZE.y
		card.add_child(art)
	else:
		GbcWidgets.plate(PANEL_RECT, card) # the composed fallback panel
	GbcWidgets.plate(PLATE_RECT, card)
	var rows = GbcWidgets.row_list(card, ROWS_ORIGIN) # black ink + black arrow cursor
	return {"card": card, "rows": rows}


# Host wiring EXTRACTED from start_menu._ready: the runtime-built stage parts
# (Backing/Viewport/Display) must sit BEFORE the scene's submenu children
# (PartyScreen/BagScreen/OptionsScreen) so submenus draw over the stage (the
# scene's old Dim/MenuPanel-first order), and the Dim/MenuPanel witness names
# survive for app get_node readers. Returns {card, rows, dim, panel}.
static func compose(host: Control, parts: Dictionary) -> Dictionary:
	host.move_child(parts.backing, 0)
	host.move_child(parts.viewport, 1)
	host.move_child(parts.display, 2)
	var built := build(parts.stage)
	built["dim"] = witness(host, "Dim")
	built["panel"] = witness(host, "MenuPanel")
	return built


# Stage-space row hit test for the root _gui_input click convenience (the
# gbc_stage.stage_point inverse map): the row index whose row_rect contains the
# host-local point, or -1 (outside the display rect or between rows).
static func row_at(rows, display: TextureRect, host_point: Vector2) -> int:
	var point = GbcStage.stage_point(display, host_point)
	if point == null:
		return -1
	for i in rows.row_count():
		if rows.row_rect(i).has_point(point):
			return i
	return -1


# Contentless visibility witness with a KEPT node name (app readers resolve
# get_node(name) while their rect reads move to the stage_root() seam); the
# ink lives inside the stage, so this carries none. Shown by default — the
# scene's Dim/MenuPanel were visible; the root's own visible=false hides all.
static func witness(host: Control, node_name: String) -> Control:
	var node := Control.new()
	node.name = node_name
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(node)
	return node
