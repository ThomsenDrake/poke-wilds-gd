extends RefCounted

# Party-row style constants + HP-bar geometry extracted from party_rows.gd at
# the 220 ui wall (the house extract-before-edit pattern; the party_actions.gd
# precedent). Pure presentation data + the threshold-colored HP-bar builder;
# all row ASSEMBLY (the layout_audit.gd:137-156 child-order contract, the egg
# branch, the summary text) stays in party_rows.gd.

const SHINY_BADGE_COLOR := Color(1.0, 0.85, 0.2) # gold, like the GSC sparkle

const HP_BAR_SIZE := Vector2(22.0, 4.0)
# Fill floor (as a ratio) keeps a sliver visible at 1/max HP instead of an
# invisible bar; colors follow the classic green/orange/red HP thresholds.
const HP_BAR_MIN_FILL := 0.06
const HP_HIGH_THRESHOLD := 0.5
const HP_LOW_THRESHOLD := 0.2
const HP_COLOR_HIGH := Color(0.35, 0.78, 0.35)
const HP_COLOR_MID := Color(0.92, 0.66, 0.22)
const HP_COLOR_LOW := Color(0.88, 0.28, 0.24)
const HP_BAR_BG_COLOR := Color(0.10, 0.11, 0.13, 0.95)
const MARKER_WIDTH := 7.0
const NAME_FIELD_WIDTH := 98.0 # 126 (picker rows) - marker 7 - seps 2x2 - sprite 16 - 1px slack
const ROW_HEIGHT := 16.0 # two fonts.ttf@7 lines
const SPRITE_SIZE := Vector2(16.0, 16.0)
const SPRITE_FRAME := Rect2(0, 0, 16, 16) # frame 0 (down-idle) of the 96x16 walking strip
const OVERWORLD_SHEET := "res://assets/source/pokemon/pokemon/%s/overworld.png"
const OVERWORLD_SHINY_SHEET := "res://assets/source/pokemon/pokemon/%s/overworld-shiny.png"
const LINE2_Y := 8.0
const LINE2_H := 9.0
const HP_LABEL_POS := Vector2(26, 8)
const HP_LABEL_SIZE := Vector2(44, 9)
const STATUS_POS := Vector2(72, 8)
const STATUS_SIZE := Vector2(20, 9)
const STEPS_LABEL_SIZE := Vector2(72, 9)
const EGG_TAG_POS := Vector2(74, 8)
const EGG_TAG_SIZE := Vector2(20, 9)
const ICON_SIZE := Vector2(8.0, 8.0)
const BADGE_SIZE := Vector2(6.0, 6.0)


static func hp_bar_color(hp_ratio: float) -> Color:
	if hp_ratio > HP_HIGH_THRESHOLD:
		return HP_COLOR_HIGH
	if hp_ratio > HP_LOW_THRESHOLD:
		return HP_COLOR_MID
	return HP_COLOR_LOW


# The line-2 HP bar: min-fill sliver over the threshold-colored fill on the dark
# backing. The caller parents it to the name Label (the layout_audit contract's
# absolute-positioned line 2); the (0,10) offset is name-label-local.
static func hp_bar(mon: Dictionary) -> ProgressBar:
	var max_hp := maxi(1, int(mon.get("max_hp", 1)))
	var current_hp := clampi(int(mon.get("current_hp", 0)), 0, max_hp)
	var hp_ratio := float(current_hp) / float(max_hp)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = maxf(hp_ratio, HP_BAR_MIN_FILL) if current_hp > 0 else 0.0
	bar.show_percentage = false
	bar.position = Vector2(0, 10)
	bar.size = HP_BAR_SIZE
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = hp_bar_color(hp_ratio)
	fill_style.set_corner_radius_all(1)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = HP_BAR_BG_COLOR
	bg_style.set_corner_radius_all(1)
	bar.add_theme_stylebox_override("background", bg_style)
	bar.add_theme_stylebox_override("fill", fill_style)
	return bar
