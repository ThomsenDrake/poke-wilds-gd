extends RefCounted

# PartyScreen stage composition (restyle slice wave 2; title_screen_stage.gd
# precedent). Builds inside the 160x144 ScreenStage: gsc/background1.png art
# (load-guarded — a missing asset degrades to the opaque black backing), the
# LIST plate (white plate, ≤6 two-line party rows), the hint on the
# background's baked bottom band (pixel-probed interior x5..154, y120..139),
# the ACTION popup plate (dynamic height, bottom/right-anchored — the GSC
# party-menu idiom; sized to hold the worst fonts.ttf@7 label, "RETRIEVE:
# <name>" ≈ 128px), and the SUMMARY plate (modal, autowrap). All stage
# children carry EXPLICIT integer offsets (never set_anchors_preset on a
# parented node).

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const BACKGROUND_PATH := "res://assets/source/menu/gsc/background1.png"
const LIST_PLATE_RECT := Rect2(2, 2, 134, 112)
const ROWS_POS := Vector2i(3, 3)
const ROWS_SIZE := Vector2i(127, 106) # 6 rows x 16px + 2px separation
const HINT_POS := Vector2i(8, 120)
const HINT_SIZE := Vector2i(144, 18) # two wrapped lines on the baked band
const ACTION_PLATE_WIDTH := 142
const ACTION_PLATE_MAX_HEIGHT := 136
const ACTION_PLATE_BOTTOM := 140
const ACTION_PLATE_SIDE_MARGIN := 4
const ACTION_ROW_OFFSET := Vector2i(11, 5) # plate-local: 8px cursor + 2px gap + border/pad
const SUMMARY_PLATE_RECT := Rect2(2, 2, 156, 140)
const SUMMARY_TEXT_POS := Vector2i(5, 3)
const SUMMARY_TEXT_SIZE := Vector2i(150, 135)


static func build(stage: Control) -> Dictionary:
	art(stage, BACKGROUND_PATH)
	var list_plate := GbcWidgets.plate(LIST_PLATE_RECT, stage)
	list_plate.name = "ListPlate"
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.position = Vector2(ROWS_POS)
	rows.size = Vector2(ROWS_SIZE)
	rows.add_theme_constant_override("separation", 2)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_plate.add_child(rows)
	var hint := GbcStage.make_label("", HINT_POS, Color.BLACK, stage)
	hint.name = "Hint"
	hint.size = Vector2(HINT_SIZE)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var summary_plate := GbcWidgets.plate(SUMMARY_PLATE_RECT, stage)
	summary_plate.name = "SummaryPlate"
	summary_plate.visible = false
	var summary_text := GbcStage.make_label("", SUMMARY_TEXT_POS, Color.BLACK, summary_plate)
	summary_text.name = "SummaryText"
	summary_text.size = Vector2(SUMMARY_TEXT_SIZE)
	summary_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return {"rows": rows, "hint": hint, "summary_plate": summary_plate, "summary_text": summary_text}


# The action popup for `labels`: white plate + black-ink RowList + black
# arrow cursor, bottom/right-anchored over the list. The caller owns freeing
# BOTH the plate and the RowList root (separate stage children) on dismiss.
static func build_actions(stage: Control, labels: Array) -> Dictionary:
	var height := mini(labels.size() * GbcWidgets.RowList.PITCH + 10, ACTION_PLATE_MAX_HEIGHT)
	var rect := Rect2(160 - ACTION_PLATE_SIDE_MARGIN - ACTION_PLATE_WIDTH,
		ACTION_PLATE_BOTTOM - height, ACTION_PLATE_WIDTH, height)
	var plate := GbcWidgets.plate(rect, stage)
	plate.name = "ActionPlate"
	var rows = GbcWidgets.row_list(stage, Vector2i(int(rect.position.x) + ACTION_ROW_OFFSET.x,
		int(rect.position.y) + ACTION_ROW_OFFSET.y)) # black ink + black arrow (white plate)
	rows.root().name = "ActionRows"
	rows.set_rows(labels)
	return {"plate": plate, "rows": rows}


# Full-stage NEAREST TextureRect; a missing asset degrades to the opaque black
# backing (never crash, never edit the submodule). Title-screen art() idiom.
static func art(parent: Control, path: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = "Background"
	rect.position = Vector2.ZERO
	rect.size = GbcStage.STAGE_SIZE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(path):
		rect.texture = load(path)
	parent.add_child(rect)
	return rect
