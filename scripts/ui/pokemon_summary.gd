extends Control
class_name PokemonSummary
## PokemonSummary - Detailed Pokemon information screen
## Shows stats, moves, and other Pokemon details

signal closed()

# Pages
enum Page {
	INFO,      # Basic info, nature, ability
	STATS,     # Stats and EVs/IVs
	MOVES      # Move list with details
}

var current_page: Page = Page.INFO
var pokemon: Pokemon = null

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT

# Node references
var page_container: Control
var sprite: Sprite2D


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create summary UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.15, 0.25)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Pokemon sprite area (top left)
	var sprite_bg := ColorRect.new()
	sprite_bg.color = Color(0.2, 0.25, 0.35)
	sprite_bg.size = Vector2(56, 56)
	sprite_bg.position = Vector2(4, 4)
	add_child(sprite_bg)
	
	sprite = Sprite2D.new()
	sprite.name = "Sprite"
	sprite.position = Vector2(32, 32)
	add_child(sprite)
	
	# Name and level (top right)
	var name_lbl := Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.text = "POKEMON"
	name_lbl.position = Vector2(64, 4)
	name_lbl.add_theme_font_size_override("font_size", 8)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	add_child(name_lbl)
	
	var level_lbl := Label.new()
	level_lbl.name = "LevelLabel"
	level_lbl.text = "Lv100"
	level_lbl.position = Vector2(64, 16)
	level_lbl.add_theme_font_size_override("font_size", 8)
	level_lbl.add_theme_color_override("font_color", Color.WHITE)
	add_child(level_lbl)
	
	# Type display
	var type_lbl := Label.new()
	type_lbl.name = "TypeLabel"
	type_lbl.text = "TYPE"
	type_lbl.position = Vector2(64, 28)
	type_lbl.add_theme_font_size_override("font_size", 7)
	type_lbl.add_theme_color_override("font_color", Color.LIGHT_BLUE)
	add_child(type_lbl)
	
	# OT and ID
	var ot_lbl := Label.new()
	ot_lbl.name = "OTLabel"
	ot_lbl.text = "OT: ---"
	ot_lbl.position = Vector2(64, 42)
	ot_lbl.add_theme_font_size_override("font_size", 7)
	ot_lbl.add_theme_color_override("font_color", Color.WHITE)
	add_child(ot_lbl)
	
	# Page container
	page_container = Control.new()
	page_container.name = "PageContainer"
	page_container.position = Vector2(0, 64)
	add_child(page_container)
	
	# Page indicator
	var page_indicator := Label.new()
	page_indicator.name = "PageIndicator"
	page_indicator.text = "< INFO >"
	page_indicator.position = Vector2(56, 132)
	page_indicator.add_theme_font_size_override("font_size", 7)
	page_indicator.add_theme_color_override("font_color", Color.WHITE)
	add_child(page_indicator)


func open(p_pokemon: Pokemon) -> void:
	"""Open summary for a Pokemon"""
	pokemon = p_pokemon
	current_page = Page.INFO
	visible = true
	_update_display()


func close() -> void:
	visible = false
	closed.emit()


func _update_display() -> void:
	if pokemon == null:
		return
	
	# Update header info
	var name_lbl: Label = get_node("NameLabel")
	name_lbl.text = pokemon.get_display_name()
	if pokemon.is_shiny:
		name_lbl.add_theme_color_override("font_color", Color.YELLOW)
	else:
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
	
	var level_lbl: Label = get_node("LevelLabel")
	level_lbl.text = "Lv" + str(pokemon.level)
	
	var type_lbl: Label = get_node("TypeLabel")
	var species := pokemon.get_species()
	if species:
		var type_text := TypeChart.type_to_string(species.type1)
		if species.type2 >= 0:
			type_text += "/" + TypeChart.type_to_string(species.type2)
		type_lbl.text = type_text
	
	var ot_lbl: Label = get_node("OTLabel")
	ot_lbl.text = "OT: " + (pokemon.ot_name if pokemon.ot_name != "" else "---")
	
	# Load sprite
	_load_sprite()
	
	# Update page indicator
	var page_names := ["INFO", "STATS", "MOVES"]
	var page_indicator: Label = get_node("PageIndicator")
	page_indicator.text = "< " + page_names[current_page] + " >"
	
	# Clear and rebuild page content
	for child in page_container.get_children():
		child.queue_free()
	
	match current_page:
		Page.INFO:
			_build_info_page()
		Page.STATS:
			_build_stats_page()
		Page.MOVES:
			_build_moves_page()


func _load_sprite() -> void:
	var species := pokemon.get_species()
	if species == null:
		return
	
	var sprite_path := species.sprite_front
	if sprite_path.is_empty():
		sprite_path = "res://assets/sprites/pokemon/" + species.id.to_lower() + "/front.png"
	
	if ResourceLoader.exists(sprite_path):
		var texture := load(sprite_path) as Texture2D
		if texture:
			sprite.texture = texture


func _build_info_page() -> void:
	var y := 0
	
	# Species
	var species := pokemon.get_species()
	var species_lbl := _create_label("Species: " + (species.display_name if species else "???"), Vector2(8, y))
	page_container.add_child(species_lbl)
	y += 12
	
	# Gender
	var gender_text := "Gender: "
	match pokemon.gender:
		"male": gender_text += "Male"
		"female": gender_text += "Female"
		_: gender_text += "---"
	var gender_lbl := _create_label(gender_text, Vector2(8, y))
	page_container.add_child(gender_lbl)
	y += 12
	
	# Status
	var status_text := "Status: "
	match pokemon.status:
		Pokemon.Status.NONE: status_text += "Healthy"
		Pokemon.Status.BURN: status_text += "Burned"
		Pokemon.Status.FREEZE: status_text += "Frozen"
		Pokemon.Status.PARALYSIS: status_text += "Paralyzed"
		Pokemon.Status.POISON: status_text += "Poisoned"
		Pokemon.Status.BADLY_POISONED: status_text += "Badly Psnd"
		Pokemon.Status.SLEEP: status_text += "Asleep"
	var status_lbl := _create_label(status_text, Vector2(8, y))
	page_container.add_child(status_lbl)
	y += 12
	
	# HP
	var hp_lbl := _create_label("HP: " + str(pokemon.current_hp) + "/" + str(pokemon.max_hp), Vector2(8, y))
	page_container.add_child(hp_lbl)
	y += 12
	
	# EXP
	var exp_lbl := _create_label("EXP: " + str(pokemon.experience), Vector2(8, y))
	page_container.add_child(exp_lbl)
	y += 12
	
	# Field moves
	if species and species.has_field_moves():
		var field_lbl := _create_label("Field: " + ", ".join(species.get_field_moves()), Vector2(8, y))
		page_container.add_child(field_lbl)


func _build_stats_page() -> void:
	var stats := [
		["HP", pokemon.max_hp, pokemon.iv_hp],
		["Attack", pokemon.max_attack, pokemon.iv_attack],
		["Defense", pokemon.max_defense, pokemon.iv_defense],
		["Sp.Atk", pokemon.max_sp_attack, pokemon.iv_sp_attack],
		["Sp.Def", pokemon.max_sp_defense, pokemon.iv_sp_defense],
		["Speed", pokemon.max_speed, pokemon.iv_speed]
	]
	
	var y := 0
	for stat in stats:
		var stat_text: String = str(stat[0]) + ": " + str(stat[1])
		var stat_lbl := _create_label(stat_text, Vector2(8, y))
		page_container.add_child(stat_lbl)
		
		# IV indicator
		var iv_lbl := _create_label("IV:" + str(stat[2]), Vector2(100, y))
		iv_lbl.add_theme_font_size_override("font_size", 6)
		iv_lbl.add_theme_color_override("font_color", Color.GRAY)
		page_container.add_child(iv_lbl)
		
		y += 12


func _build_moves_page() -> void:
	var y := 0
	
	for i in range(pokemon.move_ids.size()):
		var move_id := pokemon.move_ids[i]
		var move := MoveDatabase.get_move(move_id)
		
		if move:
			var move_text := move.display_name
			var move_lbl := _create_label(move_text, Vector2(8, y))
			page_container.add_child(move_lbl)
			
			# Type
			var type_lbl := _create_label(TypeChart.type_to_string(move.type), Vector2(80, y))
			type_lbl.add_theme_font_size_override("font_size", 6)
			page_container.add_child(type_lbl)
			
			# PP
			var pp := pokemon.move_pp[i] if i < pokemon.move_pp.size() else 0
			var pp_lbl := _create_label("PP:" + str(pp) + "/" + str(move.max_pp), Vector2(110, y))
			pp_lbl.add_theme_font_size_override("font_size", 6)
			page_container.add_child(pp_lbl)
		else:
			var move_lbl := _create_label("---", Vector2(8, y))
			page_container.add_child(move_lbl)
		
		y += 16


func _create_label(text: String, pos: Vector2) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", 8)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	return lbl


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_b"):
		close()
	elif event.is_action_pressed("move_left"):
		current_page = (current_page - 1) as Page
		if current_page < 0:
			current_page = Page.MOVES
		_update_display()
	elif event.is_action_pressed("move_right"):
		current_page = (current_page + 1) as Page
		if current_page > Page.MOVES:
			current_page = Page.INFO
		_update_display()
