extends RefCounted

# Shared party-member row builder used by PartyScreen and by BagScreen's
# party picker, so both render name/level/HP/status identically.

const ShinyPalette := preload("res://scripts/ui/shiny_palette.gd")
const SHINY_BADGE_COLOR := Color(1.0, 0.85, 0.2) # gold, like the GSC sparkle

const HP_BAR_SIZE := Vector2(72.0, 10.0)
# Fill floor (as a ratio) keeps a sliver visible at 1/max HP instead of an
# invisible bar; colors follow the classic green/orange/red HP thresholds.
const HP_BAR_MIN_FILL := 0.06
const HP_HIGH_THRESHOLD := 0.5
const HP_LOW_THRESHOLD := 0.2
const HP_COLOR_HIGH := Color(0.35, 0.78, 0.35)
const HP_COLOR_MID := Color(0.92, 0.66, 0.22)
const HP_COLOR_LOW := Color(0.88, 0.28, 0.24)
const HP_BAR_BG_COLOR := Color(0.10, 0.11, 0.13, 0.95)
const MARKER_WIDTH := 16.0
const STATUS_WIDTH := 36.0


static func build_row(mon: Dictionary, selected: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var marker := Label.new()
	marker.text = ">" if selected else ""
	marker.custom_minimum_size = Vector2(MARKER_WIDTH, 0.0)
	row.add_child(marker)

	# Phase 5 eggs ride party slots: an egg icon + the pre-hatch status (faithful —
	# species/gender/moveset/shiny are visible before hatch; HP reads as the step countdown).
	var is_egg := bool(mon.get("is_egg", false))
	if is_egg:
		var egg_icon := TextureRect.new()
		egg_icon.texture = ShinyPalette.egg_frame()
		egg_icon.custom_minimum_size = Vector2(16.0, 16.0)
		egg_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(egg_icon)

	var name_label := Label.new()
	if is_egg:
		name_label.text = "Egg (%s)" % str(mon.get("egg", {}).get("display_name", "?"))
	else:
		name_label.text = "%s  Lv.%d" % [str(mon.get("name", "Pokemon")), int(mon.get("level", 1))]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)

	if bool(mon.get("is_shiny", false)): # the status-screen shiny symbol (top-right in the original)
		var shiny_badge := TextureRect.new()
		shiny_badge.texture = ShinyPalette.shiny_icon()
		shiny_badge.custom_minimum_size = Vector2(8.0, 8.0)
		shiny_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		shiny_badge.modulate = SHINY_BADGE_COLOR
		row.add_child(shiny_badge)

	if is_egg:
		var steps_label := Label.new()
		steps_label.text = "Steps: %d" % int(mon.get("egg", {}).get("steps_to_hatch", 0))
		row.add_child(steps_label)
		var egg_tag := Label.new()
		egg_tag.text = "EGG"
		row.add_child(egg_tag)
		return row

	var max_hp := maxi(1, int(mon.get("max_hp", 1)))
	var current_hp := clampi(int(mon.get("current_hp", 0)), 0, max_hp)
	var hp_ratio := float(current_hp) / float(max_hp)
	var hp_bar := ProgressBar.new()
	hp_bar.min_value = 0.0
	hp_bar.max_value = 1.0
	hp_bar.value = maxf(hp_ratio, HP_BAR_MIN_FILL) if current_hp > 0 else 0.0
	hp_bar.show_percentage = false
	hp_bar.custom_minimum_size = HP_BAR_SIZE
	hp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = hp_bar_color(hp_ratio)
	fill_style.set_corner_radius_all(2)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = HP_BAR_BG_COLOR
	bg_style.set_corner_radius_all(2)
	hp_bar.add_theme_stylebox_override("background", bg_style)
	hp_bar.add_theme_stylebox_override("fill", fill_style)
	row.add_child(hp_bar)

	var hp_label := Label.new()
	hp_label.text = "%d/%d" % [current_hp, max_hp]
	row.add_child(hp_label)

	var status_label := Label.new()
	status_label.text = status_abbrev(mon)
	status_label.custom_minimum_size = Vector2(STATUS_WIDTH, 0.0)
	row.add_child(status_label)
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
