extends RefCounted

# Shared party-member row builder used by PartyScreen and by BagScreen's
# party picker, so both render name/level/HP/status identically. GBC restyle
# (wave 2): rows render at native 160x144 stage scale — fonts.ttf@7 black ink
# on the white plates, TWO 8px lines per row. Line 1 rides the HBoxContainer
# (the layout_audit.gd:137-156 contract: child0 = ">" marker Label, child1 =
# name Label; child2 = the 16x16 overworld sprite / egg icon); line 2 (HP bar +
# numbers + status, or egg steps + EGG tag) is absolute-positioned children of
# the name Label so the contract shape holds.

const ShinyPalette := preload("res://scripts/ui/shiny_palette.gd")
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
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
const OVERWORLD_SHEET := "res://pokewilds/pokemon/pokemon/%s/overworld.png"
const OVERWORLD_SHINY_SHEET := "res://pokewilds/pokemon/pokemon/%s/overworld-shiny.png"
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


static func build_row(mon: Dictionary, selected: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var marker := Label.new()
	marker.text = ">" if selected else ""
	marker.custom_minimum_size = Vector2(MARKER_WIDTH, ROW_HEIGHT)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GbcStage.apply_font(marker, Color.BLACK)
	row.add_child(marker)

	# Phase 5 eggs ride party slots (faithful pre-hatch status — species/gender/
	# moveset/shiny are visible before hatch; HP reads as the step countdown).
	var is_egg := bool(mon.get("is_egg", false))
	var name_label := Label.new()
	if is_egg:
		name_label.text = "Egg (%s)" % str(mon.get("egg", {}).get("display_name", "?"))
	else:
		name_label.text = "%s  Lv.%d" % [str(mon.get("name", "Pokemon")), int(mon.get("level", 1))]
	# FIXED field width: an HBox hands a clip_text Label its minimum size, so the
	# old text-driven minimum collapsed every row's ink to a 1px sliver (the
	# wave-2 blank-name bug the 07 sidecar recorded as [14,5,1,7]). 98px leaves
	# room for the 16px row sprite (126px picker rows are the tightest container);
	# a worst-case name still clips by design (the layout audit skips clip_text).
	name_label.custom_minimum_size = Vector2(NAME_FIELD_WIDTH, ROW_HEIGHT)
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GbcStage.apply_font(name_label, Color.BLACK)
	row.add_child(name_label)

	if is_egg:
		row.add_child(_icon(ShinyPalette.egg_frame(), ICON_SIZE, Color.WHITE))
	else:
		var sprite := _mon_sprite(mon)
		if sprite != null:
			row.add_child(sprite)

	if is_egg:
		name_label.add_child(_line2_label("Steps: %d" % int(mon.get("egg", {}).get("steps_to_hatch", 0)),
			Vector2(0, LINE2_Y), STEPS_LABEL_SIZE))
		name_label.add_child(_line2_label("EGG", EGG_TAG_POS, EGG_TAG_SIZE))
		return row

	var max_hp := maxi(1, int(mon.get("max_hp", 1)))
	var current_hp := clampi(int(mon.get("current_hp", 0)), 0, max_hp)
	var hp_ratio := float(current_hp) / float(max_hp)
	var hp_bar := ProgressBar.new()
	hp_bar.min_value = 0.0
	hp_bar.max_value = 1.0
	hp_bar.value = maxf(hp_ratio, HP_BAR_MIN_FILL) if current_hp > 0 else 0.0
	hp_bar.show_percentage = false
	hp_bar.position = Vector2(0, 10)
	hp_bar.size = HP_BAR_SIZE
	hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = hp_bar_color(hp_ratio)
	fill_style.set_corner_radius_all(1)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = HP_BAR_BG_COLOR
	bg_style.set_corner_radius_all(1)
	hp_bar.add_theme_stylebox_override("background", bg_style)
	hp_bar.add_theme_stylebox_override("fill", fill_style)
	name_label.add_child(hp_bar)

	name_label.add_child(_line2_label("%d/%d" % [current_hp, max_hp], HP_LABEL_POS, HP_LABEL_SIZE))
	name_label.add_child(_line2_label(status_abbrev(mon), STATUS_POS, STATUS_SIZE))
	return row


static func hp_bar_color(hp_ratio: float) -> Color:
	if hp_ratio > HP_HIGH_THRESHOLD:
		return HP_COLOR_HIGH
	if hp_ratio > HP_LOW_THRESHOLD:
		return HP_COLOR_MID
	return HP_COLOR_LOW


static func set_selected(row: HBoxContainer, selected: bool) -> void:
	if row.get_child_count() == 0:
		return
	var marker := row.get_child(0) as Label
	if marker != null:
		marker.text = ">" if selected else ""


static func status_abbrev(mon: Dictionary) -> String:
	if bool(mon.get("is_egg", false)):
		return "EGG"
	if int(mon.get("current_hp", 0)) <= 0:
		return "FNT"
	return str(mon.get("status", "")).strip_edges().to_upper().left(3)


# Rebuilds a rows container (PartyScreen's list / BagScreen's picker) from a
# party snapshot: one build_row per mon — or the empty-state label (the 220
# ui wall extraction; both screens rebuilt this verbatim).
static func rebuild(rows: Container, party: Array, selected: int) -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	if party.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No Pokemon yet."
		empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		GbcStage.apply_font(empty_label, Color.BLACK)
		rows.add_child(empty_label)
		return
	for i in range(party.size()):
		rows.add_child(build_row(party[i], i == selected))


# Re-marks the selected row's ">" marker in place (no rebuild).
static func refresh_markers(rows: Container, selected: int) -> void:
	for i in range(rows.get_child_count()):
		var row := rows.get_child(i) as HBoxContainer
		if row != null:
			set_selected(row, i == selected)


# Compact stats panel text for PartyScreen: types, stats, moves with PP, and
# EXP to next level when the catalog/rules accessors are injected.
static func summary_text(mon: Dictionary, get_species: Callable, exp_for_level: Callable) -> String:
	var lines := PackedStringArray()
	if bool(mon.get("is_egg", false)): # faithful pre-hatch status: everything is visible
		var payload: Dictionary = mon.get("egg", {})
		lines.append("Egg — %s%s" % [str(payload.get("display_name", "?")), "  (SHINY)" if bool(payload.get("is_shiny", false)) else ""])
		lines.append("Gender: %s" % str(payload.get("gender", "?")))
		lines.append("Steps to hatch: %d" % int(payload.get("steps_to_hatch", 0)))
		var egg_moves: Variant = payload.get("moves", [])
		lines.append("Moves: %s" % (", ".join(egg_moves) if egg_moves is Array and not (egg_moves as Array).is_empty() else "-"))
		return "\n".join(lines)
	lines.append("%s  Lv.%d   Type: %s" % [str(mon.get("name", "Pokemon")), int(mon.get("level", 1)), _type_text(mon.get("types", []))])
	lines.append("HP: %d/%d" % [int(mon.get("current_hp", 0)), maxi(1, int(mon.get("max_hp", 1)))])
	var stats: Dictionary = mon.get("stats", {})
	lines.append("ATK %d  DEF %d  SPE %d" % [int(stats.get("atk", 0)), int(stats.get("def", 0)), int(stats.get("spe", 0))])
	lines.append("SAT %d  SDF %d" % [int(stats.get("sat", 0)), int(stats.get("sdf", 0))])
	lines.append("Moves:")
	var moves: Array = mon.get("moves", [])
	if moves.is_empty():
		lines.append("  -")
	for move_variant in moves:
		if move_variant is Dictionary:
			var move: Dictionary = move_variant
			lines.append("  %s  PP %d/%d" % [str(move.get("name", "?")), int(move.get("pp", 0)), int(move.get("max_pp", 0))])
	var level := int(mon.get("level", 1))
	if level < 100 and get_species.is_valid() and exp_for_level.is_valid():
		var species: Variant = get_species.call(str(mon.get("species_id", "")))
		if species is Dictionary and not (species as Dictionary).is_empty():
			var growth := str((species as Dictionary).get("growth_rate", "MEDIUM_FAST"))
			var remaining := maxi(0, int(exp_for_level.call(level + 1, growth)) - int(mon.get("exp", 0)))
			lines.append("EXP to next: %d" % remaining)
	return "\n".join(lines)


static func _type_text(types: Variant) -> String:
	var unique := PackedStringArray()
	for type_variant in (types if types is Array or types is PackedStringArray else []):
		var type_name := str(type_variant).to_upper()
		if not type_name.is_empty() and not unique.has(type_name):
			unique.append(type_name)
	return "/".join(unique) if not unique.is_empty() else "?"


# The mon's overworld walking-sheet frame 0 as the row sprite (the GSC party
# icon idiom). Shinies ride the recolored sheet when one exists and keep the
# gold badge as an overlay, so the shiny signal survives the 400-odd species
# without a shiny sheet; species with no overworld sheet at all skip the sprite.
static func _mon_sprite(mon: Dictionary) -> TextureRect:
	var slug := str(mon.get("species_id", "")).to_lower()
	if slug.is_empty():
		return null
	var shiny := bool(mon.get("is_shiny", false))
	var path := ""
	if shiny and ResourceLoader.exists(OVERWORLD_SHINY_SHEET % slug):
		path = OVERWORLD_SHINY_SHEET % slug
	elif ResourceLoader.exists(OVERWORLD_SHEET % slug):
		path = OVERWORLD_SHEET % slug
	if path.is_empty():
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = load(path)
	atlas.region = SPRITE_FRAME
	var sprite := TextureRect.new()
	sprite.texture = atlas
	sprite.custom_minimum_size = SPRITE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_KEEP
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if shiny: # the status-screen shiny symbol, overlaid on the sprite's top-right corner
		var badge := _icon(ShinyPalette.shiny_icon(), BADGE_SIZE, SHINY_BADGE_COLOR)
		badge.position = Vector2(SPRITE_SIZE.x - BADGE_SIZE.x, 0)
		sprite.add_child(badge)
	return sprite


static func _icon(texture: Texture2D, icon_size: Vector2, tint: Color) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = icon_size
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.modulate = tint
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return icon


static func _line2_label(text: String, pos: Vector2, label_size: Vector2) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.size = label_size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GbcStage.apply_font(label, Color.BLACK)
	return label
