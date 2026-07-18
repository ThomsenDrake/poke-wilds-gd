extends RefCounted

# Baked-art measurements for the Lane 2 render model (ui_render_model.gd).
# Every constant is measured pixel-wise from the source PNGs (dark-ink runs
# over decoded RGBA data), not copied from layout code:
# - pokewilds/battle/battle_screen2.png (action/message overlay): message box
#   x 1..70 y 96..143, action box x 65..159 y 96..143; FIGHT/PKMN/ITEM/RUN
#   glyphs baked 7px tall (PKMN ligature 8px) at the row tops below.
# - pokewilds/menu/attack_screen1.png (moves overlay): side box x 1..87
#   y 64..103, move list box x 33..159 y 96..143; "TYPE/" baked at
#   (8,72,31,8); the PP "/" baked diagonally at (56,89,7,7).
# - pokewilds/battle/battle_bg1.png (blank background): full-width bottom box
#   x 1..159 y 96..143.

const STAGE := Rect2(0, 0, 160, 144)

const MSG_INTERIOR := Rect2(7, 104, 56, 31)
const ACTION_INTERIOR := Rect2(72, 104, 79, 31)
const ACTION_ROWS := [
	{"id": "fight", "row": Rect2(80, 112, 39, 7), "cursor": Rect2(72, 112, 4, 4)},
	{"id": "pkmn", "row": Rect2(128, 112, 15, 8), "cursor": Rect2(115, 112, 4, 4)},
	{"id": "item", "row": Rect2(81, 128, 30, 7), "cursor": Rect2(72, 128, 4, 4)},
	{"id": "run", "row": Rect2(128, 128, 23, 7), "cursor": Rect2(115, 128, 4, 4)},
]
const ACTION_FORBIDDEN := [Rect2(72, 120, 80, 7), Rect2(120, 112, 7, 8), Rect2(120, 128, 7, 7)]

const SIDE_INTERIOR := Rect2(7, 72, 74, 23)
const TYPE_SLASH_INK := Rect2(8, 72, 31, 8)
const PP_SLASH_INK := Rect2(56, 89, 7, 7)
const MOVE_INTERIOR := Rect2(39, 103, 113, 32)
const MOVE_ROW_TOPS := [104.0, 112.0, 120.0, 128.0]
const MOVE_ANCHOR := Vector2(45, 103)
const MOVE_CURSOR_X := 37.0
const MOVE_FORBIDDEN := [Rect2(128, 104, 24, 31), Rect2(45, 111, 80, 1), Rect2(45, 119, 80, 1), Rect2(45, 127, 80, 1)]

const ITEM_INTERIOR := Rect2(7, 104, 145, 31)
const ITEM_ROW_TOPS := [111.0, 119.0, 127.0]
const ITEM_ANCHOR := Vector2(16, 111)
const ITEM_CURSOR_X := 8.0
const ITEM_FORBIDDEN := [Rect2(100, 111, 52, 24), Rect2(16, 119, 80, 1), Rect2(16, 127, 80, 1)]
