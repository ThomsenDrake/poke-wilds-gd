extends Control
class_name BreedingMenu
## BreedingMenu - UI for managing Pokemon breeding at Breeding Dens

signal menu_closed()

# UI States
enum State {
	MAIN,           # Main breeding view
	SELECT_POKEMON, # Selecting Pokemon to deposit
	CONFIRM         # Confirming action
}

var current_state: State = State.MAIN
var selected_slot: int = 0  # 0 or 1 for breeding slots
var party_cursor: int = 0
var current_den_tile: Vector2i = Vector2i.ZERO

# Constants
const SCREEN_WIDTH := 160
const SCREEN_HEIGHT := 144


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create the breeding menu UI"""
	# Background
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.15, 0.2, 0.15)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Title
	var title := Label.new()
	title.name = "Title"
	title.text = "BREEDING DEN"
	title.position = Vector2(44, 2)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)
	
	# Slot 1 panel
	var slot1 := _create_slot_panel(0)
	slot1.position = Vector2(4, 16)
	add_child(slot1)
	
	# Slot 2 panel
	var slot2 := _create_slot_panel(1)
	slot2.position = Vector2(82, 16)
	add_child(slot2)
	
	# Compatibility indicator
	var compat := Label.new()
	compat.name = "Compatibility"
	compat.text = ""
	compat.position = Vector2(50, 72)
	compat.add_theme_font_size_override("font_size", 7)
	compat.add_theme_color_override("font_color", Color.YELLOW)
	add_child(compat)
	
	# Progress bar background
	var progress_bg := ColorRect.new()
	progress_bg.name = "ProgressBG"
	progress_bg.color = Color(0.2, 0.2, 0.2)
	progress_bg.size = Vector2(120, 8)
	progress_bg.position = Vector2(20, 85)
	add_child(progress_bg)
	
	# Progress bar fill
	var progress := ColorRect.new()
	progress.name = "Progress"
	progress.color = Color(0.3, 0.8, 0.3)
	progress.size = Vector2(0, 8)
	progress.position = Vector2(20, 85)
	add_child(progress)
	
	# Progress label
	var progress_lbl := Label.new()
	progress_lbl.name = "ProgressLabel"
	progress_lbl.text = ""
	progress_lbl.position = Vector2(50, 95)
	progress_lbl.add_theme_font_size_override("font_size", 7)
	progress_lbl.add_theme_color_override("font_color", Color.WHITE)
	add_child(progress_lbl)
	
	# Instructions
	var instructions := Label.new()
	instructions.name = "Instructions"
	instructions.text = "A:Select  B:Back"
	instructions.position = Vector2(40, 130)
	instructions.add_theme_font_size_override("font_size", 7)
	instructions.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(instructions)
	
	# Party selection panel (hidden by default)
	var party_panel := _create_party_panel()
	party_panel.name = "PartyPanel"
	party_panel.visible = false
	add_child(party_panel)


func _create_slot_panel(slot_index: int) -> Control:
	"""Create a breeding slot panel"""
	var panel := Control.new()
	panel.name = "Slot" + str(slot_index)
	
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.25, 0.3, 0.25)
	bg.size = Vector2(74, 54)
	panel.add_child(bg)
	
	# Pokemon sprite placeholder
	var sprite := ColorRect.new()
	sprite.name = "Sprite"
	sprite.color = Color(0.4, 0.4, 0.4)
	sprite.size = Vector2(32, 32)
	sprite.position = Vector2(21, 4)
	panel.add_child(sprite)
	
	# Name
	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = "Empty"
	name_lbl.position = Vector2(4, 38)
	name_lbl.add_theme_font_size_override("font_size", 7)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(name_lbl)
	
	# Cursor indicator
	var cursor := ColorRect.new()
	cursor.name = "Cursor"
	cursor.color = Color.WHITE
	cursor.size = Vector2(74, 2)
	cursor.position = Vector2(0, 52)
	cursor.visible = false
	panel.add_child(cursor)
	
	return panel


func _create_party_panel() -> Control:
	"""Create party selection panel"""
	var panel := Control.new()
	
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.15)
	bg.size = Vector2(SCREEN_WIDTH - 20, SCREEN_HEIGHT - 20)
	bg.position = Vector2(10, 10)
	panel.add_child(bg)
	
	var title := Label.new()
	title.text = "Select Pokemon"
	title.position = Vector2(50, 14)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(title)
	
	# Party list will be populated dynamically
	for i in range(6):
		var slot := Control.new()
		slot.name = "PartySlot" + str(i)
		slot.position = Vector2(20, 28 + i * 16)
		
		var slot_bg := ColorRect.new()
		slot_bg.name = "BG"
		slot_bg.color = Color(0.2, 0.2, 0.25)
		slot_bg.size = Vector2(120, 14)
		slot.add_child(slot_bg)
		
		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.text = "---"
		name_lbl.position = Vector2(4, 1)
		name_lbl.add_theme_font_size_override("font_size", 7)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(name_lbl)
		
		panel.add_child(slot)
	
	# Cursor
	var cursor := Sprite2D.new()
	cursor.name = "PartyCursor"
	cursor.texture = _create_cursor_texture()
	cursor.position = Vector2(16, 36)
	panel.add_child(cursor)
	
	return panel


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(6, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(3):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.WHITE)
	return ImageTexture.create_from_image(image)


func open(den_tile: Vector2i) -> void:
	"""Open the breeding menu for a specific den"""
	current_den_tile = den_tile
	current_state = State.MAIN
	selected_slot = 0
	party_cursor = 0
	visible = true
	_refresh_display()
	GameManager.change_state(GameManager.GameState.MENU)


func close() -> void:
	"""Close the breeding menu"""
	visible = false
	menu_closed.emit()
	GameManager.change_state(GameManager.GameState.OVERWORLD)


func _refresh_display() -> void:
	"""Update the display based on current state"""
	var den := BreedingManager.get_den_data(current_den_tile)
	
	# Update slot displays
	_update_slot_display(0, den.pokemon1 if den else null)
	_update_slot_display(1, den.pokemon2 if den else null)
	
	# Update cursor
	var slot0_cursor: Control = get_node("Slot0/Cursor")
	var slot1_cursor: Control = get_node("Slot1/Cursor")
	slot0_cursor.visible = (selected_slot == 0 and current_state == State.MAIN)
	slot1_cursor.visible = (selected_slot == 1 and current_state == State.MAIN)
	
	# Update compatibility
	var compat_label: Label = get_node("Compatibility")
	if den and den.pokemon1 and den.pokemon2:
		var compat := BreedingManager.get_compatibility(den.pokemon1, den.pokemon2)
		if compat > 0:
			compat_label.text = "Compatible! " + str(compat) + "%"
			compat_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			compat_label.text = "Incompatible"
			compat_label.add_theme_color_override("font_color", Color.RED)
	else:
		compat_label.text = ""
	
	# Update progress
	var progress: ColorRect = get_node("Progress")
	var progress_lbl: Label = get_node("ProgressLabel")
	if den:
		progress.size.x = 120 * den.progress
		if den.has_egg:
			progress_lbl.text = "Egg ready!"
		elif den.pokemon1 and den.pokemon2 and BreedingManager.can_breed(den.pokemon1, den.pokemon2):
			progress_lbl.text = "Breeding: " + str(int(den.progress * 100)) + "%"
		else:
			progress_lbl.text = ""
	else:
		progress.size.x = 0
		progress_lbl.text = ""
	
	# Update party panel
	var party_panel: Control = get_node("PartyPanel")
	party_panel.visible = (current_state == State.SELECT_POKEMON)
	if party_panel.visible:
		_refresh_party_display()


func _update_slot_display(slot_index: int, pokemon: Pokemon) -> void:
	"""Update a slot's display"""
	var slot: Control = get_node("Slot" + str(slot_index))
	var name_lbl: Label = slot.get_node("Name")
	var sprite: ColorRect = slot.get_node("Sprite")
	
	if pokemon:
		name_lbl.text = pokemon.get_display_name()
		# Color sprite based on type
		var species := pokemon.get_species()
		if species:
			sprite.color = _get_type_color(species.type1)
		else:
			sprite.color = Color(0.5, 0.5, 0.5)
	else:
		name_lbl.text = "Empty"
		sprite.color = Color(0.3, 0.3, 0.3)


func _refresh_party_display() -> void:
	"""Update the party selection display"""
	var party := GameManager.player_party
	
	for i in range(6):
		var slot: Control = get_node("PartyPanel/PartySlot" + str(i))
		var name_lbl: Label = slot.get_node("Name")
		var bg: ColorRect = slot.get_node("BG")
		
		if i < party.size() and party[i]:
			var pokemon: Pokemon = party[i]
			name_lbl.text = pokemon.get_display_name() + " Lv" + str(pokemon.level)
			
			# Check if compatible for breeding
			var den := BreedingManager.get_den_data(current_den_tile)
			var other: Pokemon = null
			if den:
				other = den.pokemon2 if selected_slot == 0 else den.pokemon1
			
			if other and not BreedingManager.can_breed(pokemon, other):
				bg.color = Color(0.3, 0.2, 0.2)  # Red tint for incompatible
			else:
				bg.color = Color(0.2, 0.2, 0.25)
		else:
			name_lbl.text = "---"
			bg.color = Color(0.15, 0.15, 0.2)
	
	# Update cursor position
	var cursor: Sprite2D = get_node("PartyPanel/PartyCursor")
	cursor.position = Vector2(16, 36 + party_cursor * 16)


func _get_type_color(type_id: int) -> Color:
	match type_id:
		0: return Color(0.66, 0.66, 0.47)  # Normal
		1: return Color(0.76, 0.38, 0.27)  # Fire
		2: return Color(0.39, 0.56, 0.94)  # Water
		3: return Color(0.95, 0.77, 0.16)  # Electric
		4: return Color(0.47, 0.78, 0.30)  # Grass
		_: return Color(0.5, 0.5, 0.5)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	match current_state:
		State.MAIN:
			if event.is_action_pressed("button_a"):
				_handle_main_confirm()
			elif event.is_action_pressed("button_b"):
				close()
			elif event.is_action_pressed("move_left"):
				selected_slot = 0
				_refresh_display()
			elif event.is_action_pressed("move_right"):
				selected_slot = 1
				_refresh_display()
		
		State.SELECT_POKEMON:
			if event.is_action_pressed("button_a"):
				_handle_select_confirm()
			elif event.is_action_pressed("button_b"):
				current_state = State.MAIN
				_refresh_display()
			elif event.is_action_pressed("move_up") and party_cursor > 0:
				party_cursor -= 1
				_refresh_display()
			elif event.is_action_pressed("move_down") and party_cursor < mini(5, GameManager.player_party.size() - 1):
				party_cursor += 1
				_refresh_display()


func _handle_main_confirm() -> void:
	"""Handle A button in main state"""
	var den := BreedingManager.get_den_data(current_den_tile)
	
	# Check if egg is ready
	if den and den.has_egg:
		var egg := BreedingManager.collect_egg(current_den_tile)
		if egg:
			if GameManager.can_add_to_party():
				GameManager.add_pokemon_to_party(egg)
				BreedingManager.register_egg(egg)
				print("Got egg!")
			else:
				GameManager.add_pokemon_to_pc(egg)
				print("Egg sent to PC!")
			_refresh_display()
		return
	
	# Check if slot has Pokemon (remove it)
	var current_pokemon: Pokemon = null
	if den:
		current_pokemon = den.pokemon1 if selected_slot == 0 else den.pokemon2
	
	if current_pokemon:
		# Remove Pokemon from den
		var removed := BreedingManager.remove_pokemon(current_den_tile, selected_slot)
		if removed and GameManager.can_add_to_party():
			GameManager.add_pokemon_to_party(removed)
		_refresh_display()
	else:
		# Open party selection
		if GameManager.player_party.size() > 0:
			current_state = State.SELECT_POKEMON
			party_cursor = 0
			_refresh_display()


func _handle_select_confirm() -> void:
	"""Handle A button in select state"""
	if party_cursor >= GameManager.player_party.size():
		return
	
	var pokemon: Pokemon = GameManager.player_party[party_cursor]
	
	# Can't use eggs for breeding
	if pokemon.is_egg:
		return
	
	# Place Pokemon in den
	if BreedingManager.place_pokemon(current_den_tile, pokemon, selected_slot):
		GameManager.player_party.remove_at(party_cursor)
		current_state = State.MAIN
		_refresh_display()
