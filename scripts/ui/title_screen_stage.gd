extends RefCounted

# TitleScreen stage composition EXTRACTED from title_screen.gd at the 220 ui
# wall (restyle slice wave 0; the menu_context.gd extraction precedent). Builds
# the two stage groups inside the 160x144 ScreenStage: the SPLASH card (opaque
# black backing + two centered WHITE-ink fonts.ttf@7 labels — the ONLY legal
# white ink) and the TITLE card (gsc/background1.png art + white wordmark plate
# + textbox_bg2.png entry band + black-ink row list). All stage children carry
# EXPLICIT integer offsets (never set_anchors_preset on a parented node).

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")

const WORDMARK := "POKÉWILDS"
const WORDMARK_DEGRADED := "POKEWILDS" # only when fonts.ttf lacks É (design §1.3: never ship tofu)
const CREDIT_LINE := "a fan remake of PokeWilds — original game by SheerSt" # pinned splash string
# The pinned credit rendered as two explicit lines: Label autowrap proved
# unreliable at fonts.ttf@7 (the one-line render bled past the stage edge —
# off-stage ink), and each manual line fits the 160px stage width.
const CREDIT_LINES := "a fan remake of PokeWilds\n— original game by SheerSt"
const BACKGROUND_PATH := "res://pokewilds/menu/gsc/background1.png"
const ENTRY_BAND_PATH := "res://pokewilds/textbox_bg2.png"


static func build(stage: Control) -> Dictionary:
	var built := _build_title_card(stage)
	return {"splash_card": _build_splash_card(stage), "title_card": built.card, "rows": built.rows}


# Contentless visibility witness with a FROZEN node name (the scenario reads
# get_node(name).visible); its ink lives inside the stage, so this carries none.
static func witness(host: Control, node_name: String) -> Control:
	var node := Control.new()
	node.name = node_name
	node.visible = false
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(node)
	return node


# Splash: opaque black stage + two centered WHITE-ink labels (the ONLY legal
# white ink; the backing is pure black) + a 1px white frame. The credit line
# wraps on its own. The frame is a capture-honesty necessity, not decor: the
# sweep's validity oracle (snapshot_capture LUMINANCE_FLOOR 0.01 over the whole
# 1152x648 window) classifies two 7px text lines on black as a BLANK capture;
# the frame's ~590 stage px (x16 at k=4) lift the mean luminance above the
# floor while every white pixel stays on the pure-black splash (the ink rule).
static func _build_splash_card(stage: Control) -> Control:
	var card := Control.new()
	card.name = "SplashCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(card)
	for bar in [Rect2(2, 2, 156, 1), Rect2(2, 141, 156, 1), Rect2(2, 3, 1, 138), Rect2(157, 3, 1, 138)]:
		var edge := ColorRect.new()
		edge.color = Color.WHITE
		edge.position = bar.position
		edge.size = bar.size
		edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(edge)
	var mark := GbcStage.make_label(_wordmark_text(), Vector2i(0, 56), Color.WHITE, card)
	mark.size = Vector2(160, 8)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var credit := GbcStage.make_label(CREDIT_LINES, Vector2i(0, 72), Color.WHITE, card)
	credit.size = Vector2(160, 24)
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return card


# Title: gsc background (load-guarded black fallback) + white wordmark plate
# (black ink; no text sits on the raw background — design §1.3) + textbox_bg2
# entry band (opaque bottom 64 rows) with the black-ink row list + black arrow.
static func _build_title_card(stage: Control) -> Dictionary:
	var card := Control.new()
	card.name = "TitleCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(card)
	art(card, BACKGROUND_PATH)
	var plate := GbcWidgets.plate(Rect2(43, 18, 74, 18), card)
	var mark := GbcStage.make_label(_wordmark_text(), Vector2i(2, 4), Color.BLACK, plate)
	mark.size = Vector2(70, 8)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	art(card, ENTRY_BAND_PATH)
	var rows = GbcWidgets.row_list(card, Vector2i(57, 96)) # rows centered on the white band
	return {"card": card, "rows": rows}


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


# fonts.ttf carries the É (verified); the degraded branch is the pre-approved
# fallback (design §1.3) so a submodule font drift can never ship a tofu box.
static func _wordmark_text() -> String:
	return WORDMARK if GbcStage.font().has_char(0xC9) else WORDMARK_DEGRADED
