extends Control
class_name PCBoxMenu
## PCBoxMenu - Pokemon PC storage system UI
## Allows managing Pokemon between party and PC boxes

signal menu_closed()

# UI States
enum State {
	SELECTING_MODE,   # Choose between Party and Box
	PARTY_SELECT,     # Selecting from party
	BOX_SELECT,       # Selecting from box
	HOLDING,          # Holding a Pokemon to move
	CONFIRM_ACTION    # Confirming deposit/withdraw
}

# Modes
enum Mode {
	WITHDRAW,   # Take from PC to party
	DEPOSIT,    # Put from party to PC
	MOVE,       # Move within PC
	ORGANIZE    # Full organization mode
}

var current_state: State = State.SELECTING_MODE
var current_mode: Mode = Mode.ORGANIZE
var current_box: int = 0

# Selection
var party_index: int = 0
var box_slot_x: int = 0
var box_slot_y: int = 0
var is_in_party: bool = true  # True = party side, False = box side

# Held Pokemon for moving
var held_pokemon: Pokemon = null
var held_from_party: bool = false
var held_party_index: int = -1
var held_box_index: int = -1
var held_box_slot: int = -1

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT
const BOX_COLS := 5
const BOX_ROWS := 4
const SLOT_SIZE := 20

# Node references
var box_name_label: Label
var box_grid: Control
var party_panel: Control
var held_indicator: Control
var info_label: Label


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create PC Box UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.2, 0.3)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Box name header
	var header_bg := ColorRect.new()
	header_bg.color = Color(0.15, 0.25, 0.4)
	header_bg.size = Vector2(SCREEN_WIDTH, 14)
	add_child(header_bg)
	
	box_name_label = Label.new()
	box_name_label.name = "BoxName"
	box_name_label.text = "< BOX 1 >"
	box_name_label.position = Vector2(52, 1)
	box_name_label.add_theme_font_size_override("font_size", 8)
	box_name_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(box_name_label)
	
	# Box grid area (left side)
	box_grid = Control.new()
	box_grid.name = "BoxGrid"
	box_grid.position = Vector2(4, 18)
	add_child(box_grid)
	
	var grid_bg := ColorRect.new()
	grid_bg.color = Color(0.2, 0.3, 0.4)
	grid_bg.size = Vector2(BOX_COLS * SLOT_SIZE + 4, BOX_ROWS * SLOT_SIZE + 4)
	box_grid.add_child(grid_bg)
	
	# Create box slots
	for y in range(BOX_ROWS):
		for x in range(BOX_COLS):
			var slot := _create_box_slot(x, y)
			box_grid.add_child(slot)
	
	# Party panel (right side)
	party_panel = Control.new()
	party_panel.name = "PartyPanel"
	party_panel.position = Vector2(112, 18)
	add_child(party_panel)
	
	var party_bg := ColorRect.new()
	party_bg.color = Color(0.25, 0.2, 0.3)
	party_bg.size = Vector2(44, 100)
	party_panel.add_child(party_bg)
	
	var party_title := Label.new()
	party_title.text = "PARTY"
	party_title.position = Vector2(8, 0)
	party_title.add_theme_font_size_override("font_size", 7)
	party_title.add_theme_color_override("font_color", Color.WHITE)
	party_panel.add_child(party_title)
	
	# Party slots
	for i in range(6):
		var slot := _create_party_slot(i)
		party_panel.add_child(slot)
	
	# Held Pokemon indicator
	held_indicator = ColorRect.new()
	held_indicator.name = "HeldIndicator"
	held_indicator.color = Color(1, 1, 0, 0.5)
	held_indicator.size = Vector2(SLOT_SIZE - 2, SLOT_SIZE - 2)
	held_indicator.visible = false
	add_child(held_indicator)
	
	# Info/instructions at bottom
	var info_bg := ColorRect.new()
	info_bg.color = Color(0.1, 0.1, 0.15)
	info_bg.size = Vector2(SCREEN_WIDTH, 20)
	info_bg.position = Vector2(0, 124)
	add_child(info_bg)
	
	info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.text = "A:Select B:Back L/R:Box"
	info_label.position = Vector2(4, 128)
	info_label.add_theme_font_size_override("font_size", 7)
	info_label.add_theme_color_override("font_color", Color.GRAY)
	add_child(info_label)
	
	# Cursor
	var cursor := ColorRect.new()
	cursor.name = "Cursor"
	cursor.color = Color(1, 1, 1, 0.7)
	cursor.size = Vector2(SLOT_SIZE, SLOT_SIZE)
	add_child(cursor)


func _create_box_slot(x: int, y: int) -> Control:
	var slot := Control.new()
	slot.name = "BoxSlot_" + str(x) + "_" + str(y)
	slot.position = Vector2(2 + x * SLOT_SIZE, 2 + y * SLOT_SIZE)
	
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.3, 0.4, 0.5)
	bg.size = Vector2(SLOT_SIZE - 1, SLOT_SIZE - 1)
	slot.add_child(bg)
	
	# Pokemon icon placeholder
	var icon := ColorRect.new()
	icon.name = "Icon"
	icon.color = Color(0.4, 0.5, 0.6)
	icon.size = Vector2(SLOT_SIZE - 4, SLOT_SIZE - 4)
	icon.position = Vector2(2, 2)
	icon.visible = false
	slot.add_child(icon)
	
	return slot


func _create_party_slot(index: int) -> Control:
	var slot := Control.new()
	slot.name = "PartySlot_" + str(index)
	slot.position = Vector2(2, 12 + index * 14)
	
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.35, 0.3, 0.4)
	bg.size = Vector2(40, 13)
	slot.add_child(bg)
	
	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = "---"
	name_lbl.position = Vector2(2, 0)
	name_lbl.add_theme_font_size_override("font_size", 6)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	slot.add_child(name_lbl)
	
	return slot


func open() -> void:
	"""Open PC Box menu"""
	current_state = State.BOX_SELECT
	current_box = 0
	is_in_party = false
	box_slot_x = 0
	box_slot_y = 0
	party_index = 0
	held_pokemon = null
	visible = true
	_refresh_display()
	_update_cursor()


func close() -> void:
	"""Close PC Box menu"""
	visible = false
	held_pokemon = null
	menu_closed.emit()


func _refresh_display() -> void:
	"""Update all displays"""
	# Update box name
	box_name_label.text = "< " + GameManager.get_box_name(current_box) + " >"
	
	# Update box slots
	_refresh_box_display()
	
	# Update party slots
	_refresh_party_display()
	
	# Update info text
	_update_info_text()


func _refresh_box_display() -> void:
	"""Update box grid display"""
	var box: Array = GameManager.player_pc_boxes[current_box]
	
	for y in range(BOX_ROWS):
		for x in range(BOX_COLS):
			var slot_index := y * BOX_COLS + x
			var slot := box_grid.get_node("BoxSlot_" + str(x) + "_" + str(y))
			var icon: ColorRect = slot.get_node("Icon")
			var bg: ColorRect = slot.get_node("BG")
			
			if slot_index < box.size() and box[slot_index] != null:
				var pokemon: Pokemon = box[slot_index]
				icon.visible = true
				# Color based on type
				var species := pokemon.get_species()
				if species:
					icon.color = _get_type_color(species.type1)
				else:
					icon.color = Color(0.5, 0.5, 0.5)
				
				if pokemon.is_shiny:
					bg.color = Color(0.5, 0.5, 0.3)
				else:
					bg.color = Color(0.3, 0.4, 0.5)
			else:
				icon.visible = false
				bg.color = Color(0.25, 0.35, 0.45)


func _refresh_party_display() -> void:
	"""Update party panel display"""
	for i in range(6):
		var slot := party_panel.get_node("PartySlot_" + str(i))
		var name_lbl: Label = slot.get_node("Name")
		var bg: ColorRect = slot.get_node("BG")
		
		if i < GameManager.player_party.size():
			var pokemon: Pokemon = GameManager.player_party[i]
			name_lbl.text = pokemon.get_display_name().substr(0, 6)
			
			if pokemon.is_fainted():
				bg.color = Color(0.5, 0.25, 0.25)
			else:
				bg.color = Color(0.35, 0.3, 0.4)
		else:
			name_lbl.text = "---"
			bg.color = Color(0.25, 0.2, 0.3)


func _get_type_color(type: int) -> Color:
	"""Get a color representing a Pokemon type"""
	match type:
		TypeChart.Type.NORMAL: return Color(0.6, 0.6, 0.5)
		TypeChart.Type.FIRE: return Color(0.9, 0.4, 0.2)
		TypeChart.Type.WATER: return Color(0.3, 0.5, 0.9)
		TypeChart.Type.ELECTRIC: return Color(0.9, 0.8, 0.2)
		TypeChart.Type.GRASS: return Color(0.4, 0.7, 0.3)
		TypeChart.Type.ICE: return Color(0.6, 0.8, 0.9)
		TypeChart.Type.FIGHTING: return Color(0.7, 0.3, 0.2)
		TypeChart.Type.POISON: return Color(0.6, 0.3, 0.6)
		TypeChart.Type.GROUND: return Color(0.7, 0.6, 0.3)
		TypeChart.Type.FLYING: return Color(0.6, 0.5, 0.9)
		TypeChart.Type.PSYCHIC: return Color(0.9, 0.4, 0.6)
		TypeChart.Type.BUG: return Color(0.6, 0.7, 0.2)
		TypeChart.Type.ROCK: return Color(0.6, 0.5, 0.3)
		TypeChart.Type.GHOST: return Color(0.4, 0.3, 0.5)
		TypeChart.Type.DRAGON: return Color(0.4, 0.3, 0.8)
		TypeChart.Type.DARK: return Color(0.4, 0.3, 0.3)
		TypeChart.Type.STEEL: return Color(0.6, 0.6, 0.7)
		TypeChart.Type.FAIRY: return Color(0.9, 0.6, 0.7)
		_: return Color(0.5, 0.5, 0.5)


func _update_cursor() -> void:
	"""Update cursor position"""
	var cursor: ColorRect = get_node("Cursor")
	
	if is_in_party:
		cursor.size = Vector2(40, 13)
		cursor.position = party_panel.position + Vector2(2, 12 + party_index * 14)
	else:
		cursor.size = Vector2(SLOT_SIZE, SLOT_SIZE)
		cursor.position = box_grid.position + Vector2(2 + box_slot_x * SLOT_SIZE, 2 + box_slot_y * SLOT_SIZE)


func _update_info_text() -> void:
	"""Update info/instruction text"""
	if held_pokemon != null:
		info_label.text = "Holding: " + held_pokemon.get_display_name()
	elif is_in_party:
		if party_index < GameManager.player_party.size():
			var pokemon: Pokemon = GameManager.player_party[party_index]
			info_label.text = pokemon.get_display_name() + " Lv" + str(pokemon.level)
		else:
			info_label.text = "Empty slot"
	else:
		var slot_index := box_slot_y * BOX_COLS + box_slot_x
		var box: Array = GameManager.player_pc_boxes[current_box]
		if slot_index < box.size() and box[slot_index] != null:
			var pokemon: Pokemon = box[slot_index]
			info_label.text = pokemon.get_display_name() + " Lv" + str(pokemon.level)
		else:
			info_label.text = "Empty slot"


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_b"):
		_handle_cancel()
	elif event.is_action_pressed("button_a"):
		_handle_confirm()
	elif event.is_action_pressed("move_up"):
		_navigate(Vector2i.UP)
	elif event.is_action_pressed("move_down"):
		_navigate(Vector2i.DOWN)
	elif event.is_action_pressed("move_left"):
		_navigate(Vector2i.LEFT)
	elif event.is_action_pressed("move_right"):
		_navigate(Vector2i.RIGHT)
	elif event.is_action_pressed("button_select"):
		# Previous box
		_change_box(-1)
	elif event.is_action_pressed("button_start"):
		# Next box
		_change_box(1)


func _navigate(dir: Vector2i) -> void:
	if is_in_party:
		# Navigate party
		if dir == Vector2i.UP and party_index > 0:
			party_index -= 1
		elif dir == Vector2i.DOWN and party_index < 5:
			party_index += 1
		elif dir == Vector2i.LEFT:
			# Switch to box
			is_in_party = false
			box_slot_x = BOX_COLS - 1
	else:
		# Navigate box grid
		if dir == Vector2i.UP:
			if box_slot_y > 0:
				box_slot_y -= 1
		elif dir == Vector2i.DOWN:
			if box_slot_y < BOX_ROWS - 1:
				box_slot_y += 1
		elif dir == Vector2i.LEFT:
			if box_slot_x > 0:
				box_slot_x -= 1
		elif dir == Vector2i.RIGHT:
			if box_slot_x < BOX_COLS - 1:
				box_slot_x += 1
			else:
				# Switch to party
				is_in_party = true
				party_index = mini(box_slot_y, GameManager.player_party.size() - 1)
				party_index = maxi(party_index, 0)
	
	_update_cursor()
	_update_info_text()


func _change_box(delta: int) -> void:
	current_box += delta
	if current_box < 0:
		current_box = GameManager.MAX_PC_BOXES - 1
	elif current_box >= GameManager.MAX_PC_BOXES:
		current_box = 0
	_refresh_display()


func _handle_confirm() -> void:
	if held_pokemon != null:
		# Place held Pokemon
		_place_held_pokemon()
	else:
		# Pick up Pokemon
		_pick_up_pokemon()


func _handle_cancel() -> void:
	if held_pokemon != null:
		# Put back held Pokemon
		_return_held_pokemon()
	else:
		close()


func _pick_up_pokemon() -> void:
	"""Pick up Pokemon at current selection"""
	if is_in_party:
		if party_index >= GameManager.player_party.size():
			return
		
		# Can't pick up last Pokemon
		if GameManager.player_party.size() <= 1:
			info_label.text = "Can't remove last Pokemon!"
			return
		
		# Can't pick up last healthy Pokemon
		var healthy_others := 0
		for i in range(GameManager.player_party.size()):
			if i != party_index and GameManager.player_party[i].can_battle():
				healthy_others += 1
		if healthy_others == 0:
			info_label.text = "Need one healthy Pokemon!"
			return
		
		held_pokemon = GameManager.player_party[party_index]
		held_from_party = true
		held_party_index = party_index
		GameManager.player_party.remove_at(party_index)
	else:
		var slot_index := box_slot_y * BOX_COLS + box_slot_x
		var box: Array = GameManager.player_pc_boxes[current_box]
		
		if slot_index >= box.size() or box[slot_index] == null:
			return
		
		held_pokemon = box[slot_index]
		held_from_party = false
		held_box_index = current_box
		held_box_slot = slot_index
		box.remove_at(slot_index)
	
	held_indicator.visible = true
	_refresh_display()
	_update_info_text()


func _place_held_pokemon() -> void:
	"""Place held Pokemon at current selection"""
	if held_pokemon == null:
		return
	
	if is_in_party:
		# Place in party
		if GameManager.player_party.size() >= GameManager.MAX_PARTY_SIZE:
			# Swap with selected party Pokemon
			if party_index < GameManager.player_party.size():
				var temp: Pokemon = GameManager.player_party[party_index]
				GameManager.player_party[party_index] = held_pokemon
				held_pokemon = temp
				_refresh_display()
				_update_info_text()
				return
			else:
				info_label.text = "Party is full!"
				return
		
		# Insert at position
		if party_index >= GameManager.player_party.size():
			GameManager.player_party.append(held_pokemon)
		else:
			GameManager.player_party.insert(party_index, held_pokemon)
	else:
		# Place in box
		var slot_index := box_slot_y * BOX_COLS + box_slot_x
		var box: Array = GameManager.player_pc_boxes[current_box]
		
		if slot_index < box.size() and box[slot_index] != null:
			# Swap with existing Pokemon
			var temp: Pokemon = box[slot_index]
			box[slot_index] = held_pokemon
			held_pokemon = temp
			_refresh_display()
			_update_info_text()
			return
		
		# Place in empty slot
		if box.size() >= GameManager.MAX_BOX_SIZE:
			info_label.text = "Box is full!"
			return
		
		# Append or insert
		if slot_index >= box.size():
			box.append(held_pokemon)
		else:
			box.insert(slot_index, held_pokemon)
	
	held_pokemon = null
	held_indicator.visible = false
	_refresh_display()
	_update_info_text()


func _return_held_pokemon() -> void:
	"""Return held Pokemon to original position"""
	if held_pokemon == null:
		return
	
	if held_from_party:
		GameManager.player_party.insert(held_party_index, held_pokemon)
	else:
		var box: Array = GameManager.player_pc_boxes[held_box_index]
		if held_box_slot >= box.size():
			box.append(held_pokemon)
		else:
			box.insert(held_box_slot, held_pokemon)
	
	held_pokemon = null
	held_indicator.visible = false
	_refresh_display()
	_update_info_text()
