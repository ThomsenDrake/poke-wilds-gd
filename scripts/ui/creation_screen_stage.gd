extends RefCounted

# CreationScreen stage composition EXTRACTED from creation_screen.gd at the 220
# ui wall (restyle slice wave 0; the menu_context.gd extraction precedent).
# Builds the opaque 160x144 step surfaces inside the ScreenStage: gsc
# background + centered menu/frame1.png step dialog (bbox (48,32)-(119,111))
# holding the Title/Value labels + the textbox_bg1.png bottom hint band
# (opaque bottom 48 rows). All stage children carry EXPLICIT integer offsets
# (never set_anchors_preset on a parented node). Every art load is guarded; a
# missing frame degrades to a composed white plate (design §8), a missing
# background to the stage Backing.

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const BACKGROUND_PATH := "res://pokewilds/menu/gsc/background1.png"
const FRAME_PATH := "res://pokewilds/menu/frame1.png"
const HINT_BAND_PATH := "res://pokewilds/textbox_bg1.png"
const FRAME_RECT := Rect2(48, 32, 72, 80) # frame1.png's verified bbox (48,32)-(119,111); the render slice centers inside it


# Returns {title_label, value_label, hint_label} — the step surfaces. The value
# autowraps inside the frame interior (the GO summary is 4 lines); the hint
# autowraps inside the 144px band width (fonts.ttf has no arrow glyphs —
# verified — so the screen's hint copy rides L/R/U/D, never tofu).
static func build(stage: Control) -> Dictionary:
	art(stage, BACKGROUND_PATH)
	var frame := art(stage, FRAME_PATH)
	if frame.texture == null:
		GbcWidgets.plate(FRAME_RECT, stage) # missing art degrades to the frame's plate
	var title_label := GbcStage.make_label("", Vector2i(52, 35), Color.BLACK, stage)
	title_label.size = Vector2(64, 8)
	var value_label := GbcStage.make_label("", Vector2i(52, 44), Color.BLACK, stage)
	value_label.size = Vector2(64, 64)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.add_theme_constant_override("line_spacing", 0) # the GO summary fits the frame interior
	art(stage, HINT_BAND_PATH)
	var hint_label := GbcWidgets.hint_label("", stage)
	hint_label.size = Vector2(144, 32)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return {"title_label": title_label, "value_label": value_label, "hint_label": hint_label}


# Full-stage NEAREST TextureRect; a missing asset degrades to the opaque black
# backing (never crash, never edit the submodule).
static func art(parent: Control, path: String) -> TextureRect:
	var rect := TextureRect.new()
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
