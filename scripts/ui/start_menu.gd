extends Control
class_name StartMenu
## StartMenu - Main pause menu accessible from overworld
## Provides access to Pokemon, Bag, Save, and Options

signal menu_closed()
signal submenu_opened(menu_name: String)
signal field_move_requested(pokemon: Pokemon, move_name: String)
signal build_requested(structure_id: String)

# Menu options
var menu_options := ["POKEMON", "BAG", "BUILD", "PC", "SAVE", "OPTIONS", "EXIT"]
var selected_index: int = 0

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT

# Sub-menus
var party_menu: PartyMenu
var pc_menu: PCBoxMenu
var build_menu: BuildMenu
var bag_menu: BagMenu
var options_menu: OptionsMenu

# State
var is_in_submenu: bool = false


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create start menu UI"""
	# Semi-transparent overlay
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.3)
	overlay.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(overlay)
	
	# Menu box (right side - positioned 70 pixels from right edge)
	var menu_box := Control.new()
	menu_box.name = "MenuBox"
	menu_box.position = Vector2(SCREEN_WIDTH - 70, 8)
	add_child(menu_box)
	
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.size = Vector2(66, 104)
	menu_box.add_child(bg)
	
	# Border
	var border := ColorRect.new()
	border.color = Color.BLACK
	border.size = Vector2(66, 2)
	menu_box.add_child(border)
	
	var border_l := ColorRect.new()
	border_l.color = Color.BLACK
	border_l.size = Vector2(2, 104)
	menu_box.add_child(border_l)
	
	var border_r := ColorRect.new()
	border_r.color = Color.BLACK
	border_r.size = Vector2(2, 104)
	border_r.position = Vector2(64, 0)
	menu_box.add_child(border_r)
	
	var border_b := ColorRect.new()
	border_b.color = Color.BLACK
	border_b.size = Vector2(66, 2)
	border_b.position = Vector2(0, 102)
	menu_box.add_child(border_b)
	
	# Menu options
	for i in range(menu_options.size()):
		var lbl := Label.new()
		lbl.name = "Option" + str(i)
		lbl.text = menu_options[i]
		lbl.position = Vector2(14, 6 + i * 14)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.BLACK)
		menu_box.add_child(lbl)
	
	# Cursor
	var cursor := Sprite2D.new()
	cursor.name = "Cursor"
	cursor.texture = _create_cursor_texture()
	cursor.position = Vector2(6, 10)
	menu_box.add_child(cursor)
	
	# Create party menu (hidden)
	party_menu = PartyMenu.new()
	party_menu.name = "PartyMenu"
	party_menu.menu_closed.connect(_on_submenu_closed)
	party_menu.field_move_requested.connect(_on_field_move_requested)
	add_child(party_menu)
	
	# Create PC menu (hidden)
	pc_menu = PCBoxMenu.new()
	pc_menu.name = "PCMenu"
	pc_menu.menu_closed.connect(_on_submenu_closed)
	add_child(pc_menu)
	
	# Create build menu (hidden)
	build_menu = BuildMenu.new()
	build_menu.name = "BuildMenu"
	build_menu.menu_closed.connect(_on_submenu_closed)
	build_menu.structure_selected.connect(_on_structure_selected)
	add_child(build_menu)
	
	# Create bag menu (hidden)
	bag_menu = BagMenu.new()
	bag_menu.name = "BagMenu"
	bag_menu.menu_closed.connect(_on_submenu_closed)
	bag_menu.item_used.connect(_on_item_used)
	add_child(bag_menu)
	
	# Create options menu (hidden)
	options_menu = OptionsMenu.new()
	options_menu.name = "OptionsMenu"
	options_menu.menu_closed.connect(_on_submenu_closed)
	add_child(options_menu)


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(6, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(3):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.BLACK)
	return ImageTexture.create_from_image(image)


func open() -> void:
	"""Open the start menu"""
	selected_index = 0
	is_in_submenu = false
	visible = true
	_update_cursor()
	GameManager.change_state(GameManager.GameState.MENU)


func close() -> void:
	"""Close the start menu"""
	visible = false
	party_menu.visible = false
	pc_menu.visible = false
	build_menu.visible = false
	bag_menu.visible = false
	options_menu.visible = false
	menu_closed.emit()
	GameManager.change_state(GameManager.GameState.OVERWORLD)


func _update_cursor() -> void:
	var cursor: Sprite2D = get_node("MenuBox/Cursor")
	if cursor:
		cursor.position = Vector2(6, 10 + selected_index * 14)


func _input(event: InputEvent) -> void:
	if not visible or is_in_submenu:
		return
	
	if event.is_action_pressed("button_start") or event.is_action_pressed("button_b"):
		close()
	elif event.is_action_pressed("button_a"):
		_select_option()
	elif event.is_action_pressed("move_up"):
		if selected_index > 0:
			selected_index -= 1
			_update_cursor()
	elif event.is_action_pressed("move_down"):
		if selected_index < menu_options.size() - 1:
			selected_index += 1
			_update_cursor()


func _select_option() -> void:
	match menu_options[selected_index]:
		"POKEMON":
			_open_pokemon_menu()
		"BAG":
			_open_bag_menu()
		"BUILD":
			_open_build_menu()
		"PC":
			_open_pc_menu()
		"SAVE":
			_save_game()
		"OPTIONS":
			_open_options_menu()
		"EXIT":
			close()


func _open_pokemon_menu() -> void:
	is_in_submenu = true
	party_menu.open()
	submenu_opened.emit("POKEMON")


func _open_bag_menu() -> void:
	is_in_submenu = true
	bag_menu.open()
	submenu_opened.emit("BAG")


func _open_build_menu() -> void:
	is_in_submenu = true
	build_menu.open()
	submenu_opened.emit("BUILD")


func _open_pc_menu() -> void:
	is_in_submenu = true
	pc_menu.open()
	submenu_opened.emit("PC")


func _save_game() -> void:
	# Show saving message
	_show_save_message("Saving...")
	
	# Use slot 1 for manual save
	var success := SaveManager.save_game("slot1")
	
	if success:
		_show_save_message("Game saved!")
	else:
		_show_save_message("Save failed!")
	
	# Auto-close message after delay
	await get_tree().create_timer(1.0).timeout
	_hide_save_message()


func _show_save_message(text: String) -> void:
	"""Show a save message overlay"""
	var existing := get_node_or_null("SaveMessage")
	if existing:
		existing.queue_free()
	
	var msg_box := Control.new()
	msg_box.name = "SaveMessage"
	# Center the save message on screen
	msg_box.position = Vector2((SCREEN_WIDTH - 80) / 2, (SCREEN_HEIGHT - 24) / 2)
	add_child(msg_box)
	
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.size = Vector2(80, 24)
	msg_box.add_child(bg)
	
	# Border
	var border := ColorRect.new()
	border.color = Color.BLACK
	border.size = Vector2(80, 2)
	msg_box.add_child(border)
	
	var border_b := ColorRect.new()
	border_b.color = Color.BLACK
	border_b.size = Vector2(80, 2)
	border_b.position = Vector2(0, 22)
	msg_box.add_child(border_b)
	
	var border_l := ColorRect.new()
	border_l.color = Color.BLACK
	border_l.size = Vector2(2, 24)
	msg_box.add_child(border_l)
	
	var border_r := ColorRect.new()
	border_r.color = Color.BLACK
	border_r.size = Vector2(2, 24)
	border_r.position = Vector2(78, 0)
	msg_box.add_child(border_r)
	
	var lbl := Label.new()
	lbl.text = text
	lbl.position = Vector2(8, 4)
	lbl.add_theme_font_size_override("font_size", 8)
	lbl.add_theme_color_override("font_color", Color.BLACK)
	msg_box.add_child(lbl)


func _hide_save_message() -> void:
	"""Hide the save message"""
	var existing := get_node_or_null("SaveMessage")
	if existing:
		existing.queue_free()


func _open_options_menu() -> void:
	is_in_submenu = true
	options_menu.open()
	submenu_opened.emit("OPTIONS")


func _on_submenu_closed() -> void:
	is_in_submenu = false


func _on_field_move_requested(pokemon: Pokemon, move_name: String) -> void:
	# Close the menu and propagate the field move request
	close()
	field_move_requested.emit(pokemon, move_name)


func _on_structure_selected(structure_id: String) -> void:
	# Close the menu and propagate the build request
	close()
	build_requested.emit(structure_id)


func _on_item_used(item_id: String, target_pokemon: Pokemon) -> void:
	# Item usage is handled via signal - parent can open party menu for target selection
	# For now, we just close the menu
	is_in_submenu = false
