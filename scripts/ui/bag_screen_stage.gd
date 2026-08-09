extends RefCounted

# BagScreen stage composition (restyle slice wave 2; title_screen_stage.gd
# precedent). item_menu_gsc1.png (160x144 Crystal bag frame) full stage,
# load-guarded — a missing asset degrades to the plate-composition fallback
# (the same two surfaces as white plates on the opaque black backing).
# Pixel-probed interiors: item list x41..159 y8..95, bottom description frame
# x5..154 y104..139. Item rows + the black arrow cursor sit in the list
# interior; the description + hint ride the baked bottom frame; the party
# picker is a MODAL white plate (six two-line party_rows.gd rows need 126px —
# wider than the art's list column, so it overlays). All stage children carry
# EXPLICIT integer offsets.

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const ART_PATH := "res://assets/source/menu/item_menu_gsc1.png"
const VISIBLE_ROWS := 10
const LIST_ORIGIN := Vector2i(52, 10) # the black arrow cursor lands at x42, inside the list interior
const DESC_POS := Vector2i(6, 104)
const DESC_SIZE := Vector2i(148, 24)
const HINT_POS := Vector2i(6, 131)
const HINT_SIZE := Vector2i(148, 9)
const PICKER_RECT := Rect2(16, 8, 132, 122)
const PICKER_TITLE_POS := Vector2i(3, 3)
const PICKER_TITLE_SIZE := Vector2i(112, 9)
const PICKER_ROWS_POS := Vector2i(3, 13)
const PICKER_ROWS_SIZE := Vector2i(126, 106) # 6 rows x 16px + 2px separation
const PICKER_TITLE := "HEAL WHICH POKEMON?"


static func build(stage: Control) -> Dictionary:
	_background(stage)
	var rows = GbcWidgets.row_list(stage, LIST_ORIGIN) # black ink + black arrow (white interior)
	rows.root().name = "ItemRows"
	var description := GbcStage.make_label("", DESC_POS, Color.BLACK, stage)
	description.name = "Description"
	description.size = Vector2(DESC_SIZE)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var hint := GbcStage.make_label("", HINT_POS, Color.BLACK, stage)
	hint.name = "Hint"
	hint.size = Vector2(HINT_SIZE)
	var picker := GbcWidgets.plate(PICKER_RECT, stage)
	picker.name = "PickerPlate"
	picker.visible = false
	var title := GbcStage.make_label(PICKER_TITLE, PICKER_TITLE_POS, Color.BLACK, picker)
	title.name = "PickerTitle"
	title.size = Vector2(PICKER_TITLE_SIZE)
	var picker_rows := VBoxContainer.new()
	picker_rows.name = "Rows"
	picker_rows.position = Vector2(PICKER_ROWS_POS)
	picker_rows.size = Vector2(PICKER_ROWS_SIZE)
	picker_rows.add_theme_constant_override("separation", 2)
	picker_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picker.add_child(picker_rows)
	return {"rows": rows, "description": description, "hint": hint,
		"picker_plate": picker, "picker_rows": picker_rows}


# Full-stage NEAREST art; a missing asset falls back to the two surfaces the
# ink needs as white plates on the opaque backing (never crash, never edit
# the submodule).
static func _background(stage: Control) -> void:
	if ResourceLoader.exists(ART_PATH):
		var rect := TextureRect.new()
		rect.name = "Background"
		rect.position = Vector2.ZERO
		rect.size = GbcStage.STAGE_SIZE
		rect.texture = load(ART_PATH)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(rect)
		return
	var list_plate := GbcWidgets.plate(Rect2(40, 8, 120, 88), stage)
	list_plate.name = "BackgroundList"
	var desc_plate := GbcWidgets.plate(Rect2(2, 100, 156, 44), stage)
	desc_plate.name = "BackgroundDescription"


# The frozen row format + display-name resolution (bag_screen.gd:97 contract).
static func row_text(entry: Dictionary, get_item: Callable) -> String:
	return "%s x%d" % [display_name(str(entry.get("item_id", "")), get_item), int(entry.get("count", 0))]


static func item_description(item_id: String, get_item: Callable) -> String:
	return str(_catalog_item(item_id, get_item).get("description", ""))


static func display_name(item_id: String, get_item: Callable) -> String:
	var item_name := str(_catalog_item(item_id, get_item).get("display_name", ""))
	if not item_name.is_empty():
		return item_name.capitalize()
	return item_id.capitalize()


static func _catalog_item(item_id: String, get_item: Callable) -> Dictionary:
	if not get_item.is_valid():
		return {}
	var item: Variant = get_item.call(item_id.strip_edges().to_lower())
	return item if item is Dictionary else {}
