extends RefCounted

# Battle moves-panel name fitting (split off battle_surface_layout.gd at the 220
# ui wall — the GBC-restyle extraction pattern). Move rows anchor at x=45 and the
# baked art's reserved band (scripts/app/ui_render_art.gd MOVE_FORBIDDEN) starts
# at x=128, so name ink gets 128-45 = 83px at the battle font. Canon Gen-9 move
# names reach 16 chars ("BURNING JEALOUSY" ~ 93px at fonts.ttf@7, vs the old
# 13-char max), so overlong names tail-ellipsize; fonts.ttf ships U+2026. The
# Lane-2 oracle (ui_render_model.gd) calls display_name too, so the expected
# model predicts exactly what the panel draws.

const FONT_PATH := "res://assets/source/fonts.ttf"
const FONT_SIZE := 7
const ROW_ANCHOR_X := 45.0
const INK_LIMIT_X := 128.0
const MAX_WIDTH := INK_LIMIT_X - ROW_ANCHOR_X

static var _font: Font = null


static func display_name(raw_name: String) -> String:
	var text := raw_name.to_upper()
	if _width(text) <= MAX_WIDTH:
		return text
	var trimmed := text
	while trimmed.length() > 1 and _width(trimmed + "…") > MAX_WIDTH:
		trimmed = trimmed.left(trimmed.length() - 1)
	return trimmed.strip_edges(false, true) + "…"


static func _width(text: String) -> float:
	if _font == null:
		_font = load(FONT_PATH)
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE).x
