extends Control
class_name BattleUI
## BattleUI - Handles all battle scene UI elements
## Manages menus, HP bars, Pokemon sprites, and message display

# Signals
signal action_selected(action: String, data: Variant)
signal battle_ui_ready

# UI States
enum UIState {
	INTRO,           # Battle starting
	ACTION_MENU,     # Fight/Bag/Pokemon/Run
	MOVE_MENU,       # Selecting a move
	BAG_MENU,        # Selecting item category
	ITEM_MENU,       # Selecting specific item
	SWITCH_MENU,     # Selecting Pokemon to switch
	MESSAGE,         # Displaying a message
	ANIMATING,       # Animation in progress
	WAITING          # Waiting for battle to complete turn
}

var current_state: UIState = UIState.INTRO

# Menu selection
var action_menu_index: int = 0
var move_menu_index: int = 0
var bag_menu_index: int = 0
var item_menu_index: int = 0
var switch_menu_index: int = 0

# Bag data
var _current_bag_items: Array = []  # Current items being displayed

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT

# Pokemon sprite positions - scaled relative to viewport
var ENEMY_SPRITE_POS: Vector2:
	get: return Vector2(SCREEN_WIDTH * 0.75, SCREEN_HEIGHT * 0.15)  # Top right area
var PLAYER_SPRITE_POS: Vector2:
	get: return Vector2(SCREEN_WIDTH * 0.20, SCREEN_HEIGHT * 0.40)  # Bottom left area

# HP bar dimensions
const HP_BAR_WIDTH := 48
const HP_BAR_HEIGHT := 2

# Node references (will be created in _ready)
var enemy_sprite: Sprite2D
var player_sprite: Sprite2D
var enemy_hp_bar: Control
var player_hp_bar: Control
var enemy_name_label: Label
var player_name_label: Label
var enemy_level_label: Label
var player_level_label: Label
var enemy_hp_label: Label
var player_hp_label: Label

var action_menu: Control
var move_menu: Control
var bag_menu: Control
var item_menu: Control
var switch_menu: Control
var message_box: Control
var message_label: Label
var menu_cursor: Sprite2D

# Cached data
var _player_pokemon: Pokemon
var _enemy_pokemon: Pokemon
var _player_moves: Array[MoveData] = []
var _message_queue: Array[String] = []
var _is_processing_message: bool = false


func _ready() -> void:
	_create_ui_elements()
	_connect_signals()
	battle_ui_ready.emit()
	print("BattleUI ready")


func _create_ui_elements() -> void:
	"""Create all UI elements programmatically for GBC-style battle"""
	
	# Layout proportions (classic GBC: 2/3 arena, 1/3 menu)
	var arena_height := int(SCREEN_HEIGHT * 2.0 / 3.0)  # Top 2/3 for battle arena
	var menu_y := arena_height  # Menu starts at bottom 1/3
	
	# Background
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.95, 0.95, 0.95)  # Light gray/white battle background
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Battle arena area (top portion)
	var arena := Control.new()
	arena.name = "Arena"
	arena.size = Vector2(SCREEN_WIDTH, arena_height)
	add_child(arena)
	
	# Enemy Pokemon sprite
	enemy_sprite = Sprite2D.new()
	enemy_sprite.name = "EnemySprite"
	enemy_sprite.position = ENEMY_SPRITE_POS
	enemy_sprite.texture = _create_placeholder_sprite(Color(0.8, 0.2, 0.2), 48, 48)  # Red placeholder
	arena.add_child(enemy_sprite)
	
	# Player Pokemon sprite (back view, larger)
	player_sprite = Sprite2D.new()
	player_sprite.name = "PlayerSprite"
	player_sprite.position = PLAYER_SPRITE_POS
	player_sprite.texture = _create_placeholder_sprite(Color(0.2, 0.5, 0.8), 56, 56)  # Blue placeholder
	arena.add_child(player_sprite)
	
	# Enemy info box (top left) - scale position proportionally
	var enemy_info := _create_info_box(true)
	enemy_info.position = Vector2(SCREEN_WIDTH * 0.025, SCREEN_HEIGHT * 0.02)
	arena.add_child(enemy_info)
	
	# Player info box (bottom right, above menu) - scale position proportionally
	var player_info := _create_info_box(false)
	player_info.position = Vector2(SCREEN_WIDTH * 0.55, arena_height * 0.6)
	arena.add_child(player_info)
	
	# Message box (bottom of screen)
	message_box = _create_message_box()
	message_box.position = Vector2(0, menu_y)
	add_child(message_box)
	
	# Action menu (Fight/Bag/Pokemon/Run) - right half of menu area
	action_menu = _create_action_menu()
	action_menu.position = Vector2(SCREEN_WIDTH * 0.5, menu_y)
	action_menu.visible = false
	add_child(action_menu)
	
	# Move menu (4 moves)
	move_menu = _create_move_menu()
	move_menu.position = Vector2(0, menu_y)
	move_menu.visible = false
	add_child(move_menu)
	
	# Bag menu (category selection)
	bag_menu = _create_bag_menu()
	bag_menu.position = Vector2(0, 0)
	bag_menu.visible = false
	add_child(bag_menu)
	
	# Item menu (item selection within category)
	item_menu = _create_item_menu()
	item_menu.position = Vector2(0, 0)
	item_menu.visible = false
	add_child(item_menu)
	
	# Switch menu
	switch_menu = _create_switch_menu()
	switch_menu.position = Vector2(0, 0)
	switch_menu.visible = false
	add_child(switch_menu)
	
	# Menu cursor
	menu_cursor = Sprite2D.new()
	menu_cursor.name = "Cursor"
	menu_cursor.texture = _create_cursor_texture()
	add_child(menu_cursor)


func _create_placeholder_sprite(color: Color, width: int, height: int) -> ImageTexture:
	"""Create a colored placeholder sprite"""
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	# Add simple border
	for x in range(width):
		image.set_pixel(x, 0, Color.BLACK)
		image.set_pixel(x, height - 1, Color.BLACK)
	for y in range(height):
		image.set_pixel(0, y, Color.BLACK)
		image.set_pixel(width - 1, y, Color.BLACK)
	return ImageTexture.create_from_image(image)


func _create_info_box(is_enemy: bool) -> Control:
	"""Create Pokemon info box with name, level, HP bar"""
	var box := Control.new()
	box.name = "EnemyInfo" if is_enemy else "PlayerInfo"
	
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.9, 0.9, 0.85)
	bg.size = Vector2(68, 32)
	box.add_child(bg)
	
	# Border
	var border := ColorRect.new()
	border.color = Color.BLACK
	border.size = Vector2(68, 32)
	border.modulate.a = 0
	# We'll draw border with lines instead
	box.add_child(border)
	
	# Name label
	var name_lbl := Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.text = "POKEMON"
	name_lbl.position = Vector2(2, 0)
	name_lbl.add_theme_font_size_override("font_size", 8)
	name_lbl.add_theme_color_override("font_color", Color.BLACK)
	box.add_child(name_lbl)
	
	if is_enemy:
		enemy_name_label = name_lbl
	else:
		player_name_label = name_lbl
	
	# Level label
	var level_lbl := Label.new()
	level_lbl.name = "LevelLabel"
	level_lbl.text = "Lv5"
	level_lbl.position = Vector2(48, 0)
	level_lbl.add_theme_font_size_override("font_size", 8)
	level_lbl.add_theme_color_override("font_color", Color.BLACK)
	box.add_child(level_lbl)
	
	if is_enemy:
		enemy_level_label = level_lbl
	else:
		player_level_label = level_lbl
	
	# HP bar container
	var hp_container := Control.new()
	hp_container.name = "HPContainer"
	hp_container.position = Vector2(16, 12)
	box.add_child(hp_container)
	
	# HP label
	var hp_text := Label.new()
	hp_text.text = "HP:"
	hp_text.position = Vector2(-14, -2)
	hp_text.add_theme_font_size_override("font_size", 6)
	hp_text.add_theme_color_override("font_color", Color.BLACK)
	hp_container.add_child(hp_text)
	
	# HP bar background
	var hp_bg := ColorRect.new()
	hp_bg.color = Color(0.2, 0.2, 0.2)
	hp_bg.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	hp_container.add_child(hp_bg)
	
	# HP bar fill
	var hp_bar := ColorRect.new()
	hp_bar.name = "HPBar"
	hp_bar.color = Color(0.2, 0.8, 0.2)  # Green
	hp_bar.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	hp_container.add_child(hp_bar)
	
	if is_enemy:
		enemy_hp_bar = hp_bar
	else:
		player_hp_bar = hp_bar
	
	# HP numbers (player only)
	if not is_enemy:
		var hp_numbers := Label.new()
		hp_numbers.name = "HPNumbers"
		hp_numbers.text = "25/25"
		hp_numbers.position = Vector2(8, 8)
		hp_numbers.add_theme_font_size_override("font_size", 8)
		hp_numbers.add_theme_color_override("font_color", Color.BLACK)
		box.add_child(hp_numbers)
		player_hp_label = hp_numbers
	
	return box


func _create_message_box() -> Control:
	"""Create the message display box"""
	var box := Control.new()
	box.name = "MessageBox"
	
	var menu_height := int(SCREEN_HEIGHT / 3.0)  # Bottom 1/3 of screen
	
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.size = Vector2(SCREEN_WIDTH, menu_height)
	box.add_child(bg)
	
	# Border (top line)
	var border_top := ColorRect.new()
	border_top.color = Color.BLACK
	border_top.size = Vector2(SCREEN_WIDTH, 2)
	box.add_child(border_top)
	
	# Message text
	message_label = Label.new()
	message_label.name = "MessageLabel"
	message_label.text = ""
	message_label.position = Vector2(8, 8)
	message_label.size = Vector2(SCREEN_WIDTH * 0.9, menu_height - 16)
	message_label.add_theme_font_size_override("font_size", 8)
	message_label.add_theme_color_override("font_color", Color.BLACK)
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(message_label)
	
	return box


func _create_action_menu() -> Control:
	"""Create the Fight/Bag/Pokemon/Run menu"""
	var menu := Control.new()
	menu.name = "ActionMenu"
	
	var menu_width := int(SCREEN_WIDTH * 0.5)  # Right half of screen
	var menu_height := int(SCREEN_HEIGHT / 3.0)  # Bottom 1/3 of screen
	
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.size = Vector2(menu_width, menu_height)
	menu.add_child(bg)
	
	# Border
	var border := ColorRect.new()
	border.color = Color.BLACK
	border.size = Vector2(menu_width, 2)
	menu.add_child(border)
	
	var border_left := ColorRect.new()
	border_left.color = Color.BLACK
	border_left.size = Vector2(2, menu_height)
	menu.add_child(border_left)
	
	# Menu options (2x2 grid) - scale positions
	var options := ["FIGHT", "BAG", "PKMN", "RUN"]
	var col1_x := int(menu_width * 0.15)
	var col2_x := int(menu_width * 0.6)
	var row1_y := int(menu_height * 0.15)
	var row2_y := int(menu_height * 0.5)
	var positions := [
		Vector2(col1_x, row1_y), Vector2(col2_x, row1_y),
		Vector2(col1_x, row2_y), Vector2(col2_x, row2_y)
	]
	
	for i in range(options.size()):
		var lbl := Label.new()
		lbl.name = "Option" + str(i)
		lbl.text = options[i]
		lbl.position = positions[i]
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.BLACK)
		menu.add_child(lbl)
	
	return menu


func _create_move_menu() -> Control:
	"""Create the move selection menu"""
	var menu := Control.new()
	menu.name = "MoveMenu"
	
	var menu_height := int(SCREEN_HEIGHT / 3.0)
	
	# Background covers full bottom area
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.size = Vector2(SCREEN_WIDTH, menu_height)
	menu.add_child(bg)
	
	# Border
	var border := ColorRect.new()
	border.color = Color.BLACK
	border.size = Vector2(SCREEN_WIDTH, 2)
	menu.add_child(border)
	
	# Move slots (4 moves, 2x2 grid) - scale positions
	var col_spacing := int(SCREEN_WIDTH * 0.45)
	var row_spacing := int(menu_height * 0.35)
	for i in range(4):
		var lbl := Label.new()
		lbl.name = "Move" + str(i)
		lbl.text = "-"
		var col := i % 2
		var row := i / 2
		lbl.position = Vector2(12 + col * col_spacing, 8 + row * row_spacing)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.BLACK)
		menu.add_child(lbl)
	
	# PP display - right side
	var pp_label := Label.new()
	pp_label.name = "PPLabel"
	pp_label.text = "PP --/--"
	pp_label.position = Vector2(SCREEN_WIDTH * 0.65, menu_height * 0.65)
	pp_label.add_theme_font_size_override("font_size", 7)
	pp_label.add_theme_color_override("font_color", Color.BLACK)
	menu.add_child(pp_label)
	
	# Type display - right side
	var type_label := Label.new()
	type_label.name = "TypeLabel"
	type_label.text = "TYPE/---"
	type_label.position = Vector2(SCREEN_WIDTH * 0.65, 8)
	type_label.add_theme_font_size_override("font_size", 7)
	type_label.add_theme_color_override("font_color", Color.BLACK)
	menu.add_child(type_label)
	
	return menu


func _create_switch_menu() -> Control:
	"""Create Pokemon switch selection menu (full screen overlay)"""
	var menu := Control.new()
	menu.name = "SwitchMenu"
	
	# Full screen background
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.2, 0.3)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	menu.add_child(bg)
	
	# Title
	var title := Label.new()
	title.text = "Choose a POKEMON"
	title.position = Vector2(SCREEN_WIDTH * 0.2, 4)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	menu.add_child(title)
	
	# Pokemon slots (6 slots) - scale positions and sizes
	var slot_width := int(SCREEN_WIDTH * 0.9)
	var slot_height := int(SCREEN_HEIGHT * 0.12)
	var slot_spacing := int(SCREEN_HEIGHT * 0.14)
	var slot_start_y := int(SCREEN_HEIGHT * 0.1)
	
	for i in range(6):
		var slot := Control.new()
		slot.name = "Slot" + str(i)
		slot.position = Vector2(8, slot_start_y + i * slot_spacing)
		
		var slot_bg := ColorRect.new()
		slot_bg.color = Color(0.3, 0.3, 0.4)
		slot_bg.size = Vector2(slot_width, slot_height)
		slot.add_child(slot_bg)
		
		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.text = "---"
		name_lbl.position = Vector2(4, 2)
		name_lbl.add_theme_font_size_override("font_size", 8)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(name_lbl)
		
		var hp_lbl := Label.new()
		hp_lbl.name = "HP"
		hp_lbl.text = ""
		hp_lbl.position = Vector2(slot_width * 0.55, 2)
		hp_lbl.add_theme_font_size_override("font_size", 8)
		hp_lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(hp_lbl)
		
		menu.add_child(slot)
	
	return menu


func _create_bag_menu() -> Control:
	"""Create bag category selection menu (full screen overlay)"""
	var menu := Control.new()
	menu.name = "BagMenu"
	
	# Full screen background
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.3, 0.2)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	menu.add_child(bg)
	
	# Title
	var title := Label.new()
	title.name = "Title"
	title.text = "BAG"
	title.position = Vector2(SCREEN_WIDTH * 0.4, 4)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	menu.add_child(title)
	
	# Category buttons (only showing battle-relevant ones) - scale positions
	var categories := ["POKE BALLS", "MEDICINE", "BATTLE ITEMS"]
	var slot_width := int(SCREEN_WIDTH * 0.8)
	var slot_height := int(SCREEN_HEIGHT * 0.12)
	var slot_spacing := int(SCREEN_HEIGHT * 0.15)
	var slot_start_y := int(SCREEN_HEIGHT * 0.12)
	
	for i in range(categories.size()):
		var slot := Control.new()
		slot.name = "Category" + str(i)
		slot.position = Vector2(16, slot_start_y + i * slot_spacing)
		
		var slot_bg := ColorRect.new()
		slot_bg.color = Color(0.3, 0.4, 0.3)
		slot_bg.size = Vector2(slot_width, slot_height)
		slot.add_child(slot_bg)
		
		var lbl := Label.new()
		lbl.name = "Label"
		lbl.text = categories[i]
		lbl.position = Vector2(8, 3)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(lbl)
		
		menu.add_child(slot)
	
	# Cancel option
	var cancel := Label.new()
	cancel.name = "Cancel"
	cancel.text = "CANCEL"
	cancel.position = Vector2(24, SCREEN_HEIGHT * 0.7)
	cancel.add_theme_font_size_override("font_size", 8)
	cancel.add_theme_color_override("font_color", Color.WHITE)
	menu.add_child(cancel)
	
	return menu


func _create_item_menu() -> Control:
	"""Create item selection menu within a category"""
	var menu := Control.new()
	menu.name = "ItemMenu"
	
	# Full screen background
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.3, 0.2)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	menu.add_child(bg)
	
	# Title (will be set dynamically)
	var title := Label.new()
	title.name = "Title"
	title.text = "POKE BALLS"
	title.position = Vector2(SCREEN_WIDTH * 0.3, 4)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	menu.add_child(title)
	
	# Item slots (show up to 6 items) - scale positions
	var slot_width := int(SCREEN_WIDTH * 0.9)
	var slot_height := int(SCREEN_HEIGHT * 0.1)
	var slot_spacing := int(SCREEN_HEIGHT * 0.12)
	var slot_start_y := int(SCREEN_HEIGHT * 0.1)
	
	for i in range(6):
		var slot := Control.new()
		slot.name = "Item" + str(i)
		slot.position = Vector2(8, slot_start_y + i * slot_spacing)
		
		var slot_bg := ColorRect.new()
		slot_bg.name = "BG"
		slot_bg.color = Color(0.3, 0.4, 0.3)
		slot_bg.size = Vector2(slot_width, slot_height)
		slot.add_child(slot_bg)
		
		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.text = "---"
		name_lbl.position = Vector2(4, 1)
		name_lbl.add_theme_font_size_override("font_size", 8)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(name_lbl)
		
		var qty_lbl := Label.new()
		qty_lbl.name = "Qty"
		qty_lbl.text = ""
		qty_lbl.position = Vector2(slot_width * 0.75, 1)
		qty_lbl.add_theme_font_size_override("font_size", 8)
		qty_lbl.add_theme_color_override("font_color", Color.WHITE)
		slot.add_child(qty_lbl)
		
		menu.add_child(slot)
	
	# Cancel at bottom
	var cancel := Label.new()
	cancel.name = "Cancel"
	cancel.text = "CANCEL"
	cancel.position = Vector2(12, SCREEN_HEIGHT * 0.88)
	cancel.add_theme_font_size_override("font_size", 8)
	cancel.add_theme_color_override("font_color", Color.WHITE)
	menu.add_child(cancel)
	
	return menu


func _create_cursor_texture() -> ImageTexture:
	"""Create a simple cursor arrow"""
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	# Draw right-pointing arrow
	for i in range(4):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.BLACK)
	return ImageTexture.create_from_image(image)


func _connect_signals() -> void:
	"""Connect to BattleManager signals"""
	BattleManager.battle_started.connect(_on_battle_started)
	BattleManager.battle_ended.connect(_on_battle_ended)
	BattleManager.phase_changed.connect(_on_phase_changed)
	BattleManager.message_queued.connect(_on_message_queued)
	BattleManager.pokemon_damaged.connect(_on_pokemon_damaged)
	BattleManager.pokemon_fainted.connect(_on_pokemon_fainted)
	BattleManager.pokemon_switched.connect(_on_pokemon_switched)
	BattleManager.move_used.connect(_on_move_used)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_a"):
		_handle_confirm()
	elif event.is_action_pressed("button_b"):
		_handle_cancel()
	elif event.is_action_pressed("move_up"):
		_handle_direction(Vector2i.UP)
	elif event.is_action_pressed("move_down"):
		_handle_direction(Vector2i.DOWN)
	elif event.is_action_pressed("move_left"):
		_handle_direction(Vector2i.LEFT)
	elif event.is_action_pressed("move_right"):
		_handle_direction(Vector2i.RIGHT)


func _handle_confirm() -> void:
	match current_state:
		UIState.MESSAGE:
			_advance_message()
		UIState.ACTION_MENU:
			_select_action()
		UIState.MOVE_MENU:
			_select_move()
		UIState.BAG_MENU:
			_select_bag_category()
		UIState.ITEM_MENU:
			_select_item()
		UIState.SWITCH_MENU:
			_select_switch()


func _handle_cancel() -> void:
	match current_state:
		UIState.MOVE_MENU:
			_show_action_menu()
		UIState.BAG_MENU:
			_show_action_menu()
		UIState.ITEM_MENU:
			_show_bag_menu()
		UIState.SWITCH_MENU:
			# Can only cancel if not forced switch
			if BattleManager.current_battle and BattleManager.current_battle.player_active and BattleManager.current_battle.player_active.can_battle():
				_show_action_menu()


func _handle_direction(dir: Vector2i) -> void:
	match current_state:
		UIState.ACTION_MENU:
			_navigate_action_menu(dir)
		UIState.MOVE_MENU:
			_navigate_move_menu(dir)
		UIState.BAG_MENU:
			_navigate_bag_menu(dir)
		UIState.ITEM_MENU:
			_navigate_item_menu(dir)
		UIState.SWITCH_MENU:
			_navigate_switch_menu(dir)


func _navigate_action_menu(dir: Vector2i) -> void:
	# 2x2 grid: FIGHT(0) BAG(1) / PKMN(2) RUN(3)
	var col := action_menu_index % 2
	var row := action_menu_index / 2
	
	if dir == Vector2i.LEFT and col > 0:
		col -= 1
	elif dir == Vector2i.RIGHT and col < 1:
		col += 1
	elif dir == Vector2i.UP and row > 0:
		row -= 1
	elif dir == Vector2i.DOWN and row < 1:
		row += 1
	
	action_menu_index = row * 2 + col
	_update_cursor()


func _navigate_move_menu(dir: Vector2i) -> void:
	# 2x2 grid of moves
	var col := move_menu_index % 2
	var row := move_menu_index / 2
	var max_moves := _player_moves.size()
	
	if dir == Vector2i.LEFT and col > 0:
		col -= 1
	elif dir == Vector2i.RIGHT and col < 1 and (row * 2 + col + 1) < max_moves:
		col += 1
	elif dir == Vector2i.UP and row > 0:
		row -= 1
	elif dir == Vector2i.DOWN and row < 1 and ((row + 1) * 2 + col) < max_moves:
		row += 1
	
	var new_index := row * 2 + col
	if new_index < max_moves:
		move_menu_index = new_index
	_update_cursor()
	_update_move_info()


func _navigate_switch_menu(dir: Vector2i) -> void:
	var party_size := BattleManager.current_battle.player_party.size() if BattleManager.current_battle else 0
	
	if dir == Vector2i.UP and switch_menu_index > 0:
		switch_menu_index -= 1
	elif dir == Vector2i.DOWN and switch_menu_index < party_size - 1:
		switch_menu_index += 1
	
	_update_cursor()


func _navigate_bag_menu(dir: Vector2i) -> void:
	# 3 categories + cancel = 4 options
	if dir == Vector2i.UP and bag_menu_index > 0:
		bag_menu_index -= 1
	elif dir == Vector2i.DOWN and bag_menu_index < 3:
		bag_menu_index += 1
	
	_update_cursor()


func _navigate_item_menu(dir: Vector2i) -> void:
	var max_items := _current_bag_items.size()
	# 6 visible items + cancel
	var total_options := mini(max_items, 6) + 1  # +1 for cancel
	
	if dir == Vector2i.UP and item_menu_index > 0:
		item_menu_index -= 1
	elif dir == Vector2i.DOWN and item_menu_index < total_options - 1:
		item_menu_index += 1
	
	_update_cursor()


func _select_action() -> void:
	match action_menu_index:
		0:  # FIGHT
			_show_move_menu()
		1:  # BAG
			_show_bag_menu()
		2:  # PKMN
			_show_switch_menu()
		3:  # RUN
			BattleManager.select_run()
			_set_state(UIState.WAITING)


func _select_move() -> void:
	if move_menu_index < _player_moves.size():
		BattleManager.select_attack(move_menu_index)
		_set_state(UIState.WAITING)


func _select_switch() -> void:
	BattleManager.select_switch(switch_menu_index)
	_set_state(UIState.WAITING)


func _select_bag_category() -> void:
	match bag_menu_index:
		0:  # Poke Balls
			_show_item_menu(ItemData.Category.POKEBALL, "POKE BALLS")
		1:  # Medicine
			_show_item_menu(ItemData.Category.MEDICINE, "MEDICINE")
		2:  # Battle Items
			_show_item_menu(ItemData.Category.BATTLE, "BATTLE ITEMS")
		3:  # Cancel
			_show_action_menu()


func _select_item() -> void:
	var max_items := mini(_current_bag_items.size(), 6)
	
	if item_menu_index >= max_items:
		# Cancel selected
		_show_bag_menu()
		return
	
	if item_menu_index >= _current_bag_items.size():
		return
	
	var item_entry: Dictionary = _current_bag_items[item_menu_index]
	var item: ItemData = item_entry.item
	var item_id: String = item_entry.item_id
	
	# Use the item
	if item.category == ItemData.Category.POKEBALL:
		# Throw Pokeball
		if GameManager.player_inventory.has_item(item_id):
			GameManager.player_inventory.remove_item(item_id)
			_hide_all_menus()
			BattleManager.throw_pokeball(item_id)
			_set_state(UIState.WAITING)
		else:
			_queue_message("You don't have any left!")
	elif item.category == ItemData.Category.MEDICINE:
		# Use medicine on active Pokemon
		var result := GameManager.player_inventory.use_item_on_pokemon(item_id, _player_pokemon, true)
		if result.success:
			_hide_all_menus()
			_queue_message(result.message)
			# Using an item takes a turn
			_set_state(UIState.WAITING)
		else:
			_queue_message(result.message)
	elif item.category == ItemData.Category.BATTLE:
		# Use battle item on active Pokemon
		if item.effect == ItemData.Effect.BOOST_ATTACK:
			_player_pokemon.modify_stage("attack", 1)
			GameManager.player_inventory.remove_item(item_id)
			_hide_all_menus()
			_queue_message(_player_pokemon.get_display_name() + "'s Attack rose!")
			_set_state(UIState.WAITING)
		elif item.effect == ItemData.Effect.BOOST_DEFENSE:
			_player_pokemon.modify_stage("defense", 1)
			GameManager.player_inventory.remove_item(item_id)
			_hide_all_menus()
			_queue_message(_player_pokemon.get_display_name() + "'s Defense rose!")
			_set_state(UIState.WAITING)
		elif item.effect == ItemData.Effect.BOOST_SPEED:
			_player_pokemon.modify_stage("speed", 1)
			GameManager.player_inventory.remove_item(item_id)
			_hide_all_menus()
			_queue_message(_player_pokemon.get_display_name() + "'s Speed rose!")
			_set_state(UIState.WAITING)
		else:
			_queue_message("Can't use that here!")


func _show_action_menu() -> void:
	action_menu.visible = true
	move_menu.visible = false
	switch_menu.visible = false
	message_box.visible = true
	action_menu_index = 0
	_set_state(UIState.ACTION_MENU)
	_update_cursor()
	
	# Show "What will X do?"
	if _player_pokemon:
		message_label.text = "What will\n" + _player_pokemon.get_display_name() + " do?"


func _show_move_menu() -> void:
	action_menu.visible = false
	move_menu.visible = true
	switch_menu.visible = false
	move_menu_index = 0
	_set_state(UIState.MOVE_MENU)
	_update_moves_display()
	_update_cursor()
	_update_move_info()


func _show_switch_menu() -> void:
	action_menu.visible = false
	move_menu.visible = false
	bag_menu.visible = false
	item_menu.visible = false
	switch_menu.visible = true
	switch_menu_index = 0
	_set_state(UIState.SWITCH_MENU)
	_update_switch_display()
	_update_cursor()


func _show_bag_menu() -> void:
	action_menu.visible = false
	move_menu.visible = false
	bag_menu.visible = true
	item_menu.visible = false
	switch_menu.visible = false
	bag_menu_index = 0
	_set_state(UIState.BAG_MENU)
	_update_cursor()


func _show_item_menu(category: ItemData.Category, title: String) -> void:
	bag_menu.visible = false
	item_menu.visible = true
	item_menu_index = 0
	_set_state(UIState.ITEM_MENU)
	
	# Set title
	var title_label := item_menu.get_node_or_null("Title")
	if title_label:
		title_label.text = title
	
	# Load items from inventory
	_current_bag_items = GameManager.player_inventory.get_items_by_category(category)
	
	# Update display
	_update_item_display()
	_update_cursor()


func _update_item_display() -> void:
	"""Update item menu with current category items"""
	for i in range(6):
		var slot := item_menu.get_node_or_null("Item" + str(i))
		if slot == null:
			continue
		
		var name_lbl := slot.get_node_or_null("Name")
		var qty_lbl := slot.get_node_or_null("Qty")
		var bg := slot.get_node_or_null("BG")
		
		if i < _current_bag_items.size():
			var item_entry: Dictionary = _current_bag_items[i]
			name_lbl.text = item_entry.item.display_name
			qty_lbl.text = "x" + str(item_entry.quantity)
			bg.color = Color(0.3, 0.4, 0.3)
		else:
			name_lbl.text = "---"
			qty_lbl.text = ""
			bg.color = Color(0.25, 0.3, 0.25)


func _hide_all_menus() -> void:
	"""Hide all menu overlays"""
	action_menu.visible = false
	move_menu.visible = false
	bag_menu.visible = false
	item_menu.visible = false
	switch_menu.visible = false
	message_box.visible = true


func _update_moves_display() -> void:
	"""Update move menu with player's moves"""
	if _player_pokemon == null:
		return
	
	_player_moves.clear()
	for i in range(_player_pokemon.move_ids.size()):
		var move_id := _player_pokemon.move_ids[i]
		var move := MoveDatabase.get_move(move_id)
		if move:
			_player_moves.append(move)
	
	for i in range(4):
		var lbl := move_menu.get_node_or_null("Move" + str(i))
		if lbl:
			if i < _player_moves.size():
				lbl.text = _player_moves[i].display_name
			else:
				lbl.text = "-"


func _update_move_info() -> void:
	"""Update PP and type display for selected move"""
	if move_menu_index >= _player_moves.size():
		return
	
	var move := _player_moves[move_menu_index]
	var pp := _player_pokemon.move_pp[move_menu_index] if move_menu_index < _player_pokemon.move_pp.size() else 0
	var max_pp := move.max_pp
	
	var pp_label := move_menu.get_node_or_null("PPLabel")
	if pp_label:
		pp_label.text = "PP " + str(pp) + "/" + str(max_pp)
	
	var type_label := move_menu.get_node_or_null("TypeLabel")
	if type_label:
		type_label.text = TypeChart.type_to_string(move.type)


func _update_switch_display() -> void:
	"""Update switch menu with party Pokemon"""
	if BattleManager.current_battle == null:
		return
	
	var party := BattleManager.current_battle.player_party
	
	for i in range(6):
		var slot := switch_menu.get_node_or_null("Slot" + str(i))
		if slot == null:
			continue
		
		var name_lbl := slot.get_node_or_null("Name")
		var hp_lbl := slot.get_node_or_null("HP")
		var slot_bg := slot.get_child(0)
		
		if i < party.size():
			var pokemon: Pokemon = party[i]
			if pokemon:
				name_lbl.text = pokemon.get_display_name() + " Lv" + str(pokemon.level)
				hp_lbl.text = str(pokemon.current_hp) + "/" + str(pokemon.max_hp)
				
				# Color based on status
				if pokemon.is_fainted():
					slot_bg.color = Color(0.5, 0.2, 0.2)  # Red for fainted
				elif i == BattleManager.current_battle.player_active_index:
					slot_bg.color = Color(0.2, 0.4, 0.6)  # Blue for active
				else:
					slot_bg.color = Color(0.3, 0.3, 0.4)  # Normal
			else:
				name_lbl.text = "---"
				hp_lbl.text = ""
		else:
			name_lbl.text = "---"
			hp_lbl.text = ""
			slot_bg.color = Color(0.2, 0.2, 0.2)


func _update_cursor() -> void:
	"""Position cursor based on current menu and selection"""
	menu_cursor.visible = true
	
	match current_state:
		UIState.ACTION_MENU:
			var col := action_menu_index % 2
			var row := action_menu_index / 2
			menu_cursor.position = action_menu.position + Vector2(4 + col * 36, 10 + row * 16)
		
		UIState.MOVE_MENU:
			var col := move_menu_index % 2
			var row := move_menu_index / 2
			menu_cursor.position = move_menu.position + Vector2(4 + col * 72, 10 + row * 16)
		
		UIState.BAG_MENU:
			if bag_menu_index < 3:
				menu_cursor.position = bag_menu.position + Vector2(8, 22 + bag_menu_index * 24)
			else:
				menu_cursor.position = bag_menu.position + Vector2(16, 102)
		
		UIState.ITEM_MENU:
			var max_items := mini(_current_bag_items.size(), 6)
			if item_menu_index < max_items:
				menu_cursor.position = item_menu.position + Vector2(4, 20 + item_menu_index * 18)
			else:
				menu_cursor.position = item_menu.position + Vector2(4, 130)
		
		UIState.SWITCH_MENU:
			menu_cursor.position = switch_menu.position + Vector2(4, 22 + switch_menu_index * 20)
		
		_:
			menu_cursor.visible = false


func _set_state(new_state: UIState) -> void:
	current_state = new_state
	_update_cursor()


func _queue_message(text: String) -> void:
	_message_queue.append(text)
	if not _is_processing_message:
		_process_next_message()


func _process_next_message() -> void:
	if _message_queue.is_empty():
		_is_processing_message = false
		return
	
	_is_processing_message = true
	var msg: String = _message_queue.pop_front()
	message_label.text = msg
	_set_state(UIState.MESSAGE)
	
	# Hide menus while showing message
	action_menu.visible = false
	move_menu.visible = false
	bag_menu.visible = false
	item_menu.visible = false


func _advance_message() -> void:
	if not _message_queue.is_empty():
		_process_next_message()
	else:
		_is_processing_message = false
		# Return to action menu if battle is ongoing
		if BattleManager.current_battle and BattleManager.current_battle.phase == BattleState.Phase.ACTION_SELECT:
			_show_action_menu()


# Signal handlers
func _on_battle_started(battle_state: BattleState) -> void:
	_player_pokemon = battle_state.player_active
	_enemy_pokemon = battle_state.enemy_active
	_update_pokemon_display()
	_set_state(UIState.MESSAGE)


func _on_battle_ended(result: String, data: Dictionary) -> void:
	# Battle ended, will transition back to overworld
	pass


func _on_phase_changed(old_phase: BattleState.Phase, new_phase: BattleState.Phase) -> void:
	match new_phase:
		BattleState.Phase.ACTION_SELECT:
			# Wait a moment for messages to finish, then show action menu
			await get_tree().create_timer(0.3).timeout
			if not _is_processing_message:
				_show_action_menu()
		BattleState.Phase.SWITCH_SELECT:
			_show_switch_menu()


func _on_message_queued(message: String) -> void:
	_queue_message(message)


func _on_pokemon_damaged(is_player: bool, damage: int, remaining_hp: int) -> void:
	_update_hp_bar(is_player)


func _on_pokemon_fainted(is_player: bool, pokemon: Pokemon) -> void:
	_update_hp_bar(is_player)
	# Could play faint animation here


func _on_pokemon_switched(is_player: bool, pokemon: Pokemon) -> void:
	if is_player:
		_player_pokemon = pokemon
	else:
		_enemy_pokemon = pokemon
	_update_pokemon_display()


func _on_move_used(is_player: bool, pokemon: Pokemon, move: MoveData) -> void:
	# Could play move animation here
	pass


func _update_pokemon_display() -> void:
	"""Update all Pokemon-related displays"""
	# Update enemy info and sprite
	if _enemy_pokemon:
		if enemy_name_label:
			enemy_name_label.text = _enemy_pokemon.get_display_name()
		if enemy_level_label:
			enemy_level_label.text = "Lv" + str(_enemy_pokemon.level)
		_load_pokemon_sprite(_enemy_pokemon, false)
	
	# Update player info and sprite
	if _player_pokemon:
		if player_name_label:
			player_name_label.text = _player_pokemon.get_display_name()
		if player_level_label:
			player_level_label.text = "Lv" + str(_player_pokemon.level)
		if player_hp_label:
			player_hp_label.text = str(_player_pokemon.current_hp) + "/" + str(_player_pokemon.max_hp)
		_load_pokemon_sprite(_player_pokemon, true)
	
	_update_hp_bar(true)
	_update_hp_bar(false)


func _load_pokemon_sprite(pokemon: Pokemon, is_back: bool) -> void:
	"""Load Pokemon sprite from species data"""
	var species := pokemon.get_species()
	if species == null:
		return
	
	var sprite_path := species.sprite_back if is_back else species.sprite_front
	
	if sprite_path.is_empty():
		# Try to construct path from species ID
		var species_lower := species.id.to_lower()
		if is_back:
			sprite_path = "res://assets/sprites/pokemon/" + species_lower + "/back.png"
		else:
			sprite_path = "res://assets/sprites/pokemon/" + species_lower + "/front.png"
	
	if ResourceLoader.exists(sprite_path):
		var texture := load(sprite_path) as Texture2D
		if texture:
			if is_back:
				player_sprite.texture = texture
			else:
				enemy_sprite.texture = texture
			print("Loaded sprite: ", sprite_path)
	else:
		print("Sprite not found: ", sprite_path)


func _update_hp_bar(is_player: bool) -> void:
	"""Update HP bar display with animation"""
	var pokemon := _player_pokemon if is_player else _enemy_pokemon
	var hp_bar := player_hp_bar if is_player else enemy_hp_bar
	
	if pokemon == null or hp_bar == null:
		return
	
	var hp_percent := float(pokemon.current_hp) / float(pokemon.max_hp)
	var target_width := HP_BAR_WIDTH * hp_percent
	
	# Animate HP bar change
	var tween := create_tween()
	tween.tween_property(hp_bar, "size:x", target_width, 0.3)
	
	# Update color based on HP
	if hp_percent > 0.5:
		hp_bar.color = Color(0.2, 0.8, 0.2)  # Green
	elif hp_percent > 0.2:
		hp_bar.color = Color(0.8, 0.8, 0.2)  # Yellow
	else:
		hp_bar.color = Color(0.8, 0.2, 0.2)  # Red
	
	# Update HP numbers for player
	if is_player and player_hp_label:
		player_hp_label.text = str(pokemon.current_hp) + "/" + str(pokemon.max_hp)


## Set Pokemon sprite textures
func set_enemy_sprite(texture: Texture2D) -> void:
	if enemy_sprite:
		enemy_sprite.texture = texture


func set_player_sprite(texture: Texture2D) -> void:
	if player_sprite:
		player_sprite.texture = texture
