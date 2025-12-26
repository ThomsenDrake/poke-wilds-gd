extends Control
class_name PartyMenu
## PartyMenu - Pokemon party management UI
## Allows viewing, selecting, and managing party Pokemon

signal pokemon_selected(index: int, pokemon: Pokemon)
signal menu_closed()
signal item_use_requested(pokemon_index: int)
signal switch_requested(from_index: int, to_index: int)
signal field_move_requested(pokemon: Pokemon, move_name: String)

# UI States
# UI States
enum State {
	SELECTING,       # Selecting a Pokemon
	SUBMENU,         # Pokemon options submenu
	SWITCHING,       # Selecting Pokemon to switch with
	SUMMARY,         # Viewing Pokemon summary
	ITEM_USE         # Using item on Pokemon
}

var current_state: State = State.SELECTING
var selected_index: int = 0
var switch_from_index: int = -1

# Constants
const SCREEN_WIDTH := 160
const SCREEN_HEIGHT := 144
const SLOT_HEIGHT := 22

# Node references
var slots: Array[Control] = []
var submenu: Control
var cursor: Sprite2D

# Submenu options (built dynamically per Pokemon)
var submenu_options: Array[String] = ["SUMMARY", "SWITCH", "ITEM", "CANCEL"]
var submenu_index: int = 0

# Field move options (inserted into submenu when available)
var _field_move_options: Array[String] = []

# External item to use (set before opening menu)
var pending_item_id: String = ""

# Summary screen
var summary_screen: PokemonSummary = null


func _ready() -> void:
	_create_ui()
	_create_summary_screen()
	visible = false


func _create_summary_screen() -> void:
	summary_screen = PokemonSummary.new()
	summary_screen.name = "SummaryScreen"
	summary_screen.closed.connect(_on_summary_closed)
	add_child(summary_screen)


func _create_ui() -> void:
	"""Create party menu UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.15, 0.15, 0.25)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Title
	var title := Label.new()
	title.text = "POKEMON"
	title.position = Vector2(56, 2)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)
	
	# Create 6 party slots
	for i in range(6):
		var slot := _create_party_slot(i)
		slot.position = Vector2(4, 14 + i * SLOT_HEIGHT)
		add_child(slot)
		slots.append(slot)
	
	# Cancel button at bottom
	var cancel_bg := ColorRect.new()
	cancel_bg.color = Color(0.3, 0.3, 0.4)
	cancel_bg.size = Vector2(40, 14)
	cancel_bg.position = Vector2(116, 128)
	add_child(cancel_bg)
	
	var cancel_lbl := Label.new()
	cancel_lbl.name = "CancelLabel"
	cancel_lbl.text = "CANCEL"
	cancel_lbl.position = Vector2(120, 130)
	cancel_lbl.add_theme_font_size_override("font_size", 7)
	cancel_lbl.add_theme_color_override("font_color", Color.WHITE)
	add_child(cancel_lbl)
	
	# Submenu (hidden by default)
	submenu = _create_submenu()
	submenu.visible = false
	add_child(submenu)
	
	# Cursor
	cursor = Sprite2D.new()
	cursor.texture = _create_cursor_texture()
	add_child(cursor)


func _create_party_slot(index: int) -> Control:
	"""Create a single party slot"""
	var slot := Control.new()
	slot.name = "Slot" + str(index)
	
	# Background
	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0.25, 0.25, 0.35)
	bg.size = Vector2(152, 20)
	slot.add_child(bg)
	
	# Pokemon icon placeholder
	var icon := ColorRect.new()
	icon.name = "Icon"
	icon.color = Color(0.4, 0.4, 0.5)
	icon.size = Vector2(16, 16)
	icon.position = Vector2(2, 2)
	slot.add_child(icon)
	
	# Name
	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = "---"
	name_lbl.position = Vector2(22, 1)
	name_lbl.add_theme_font_size_override("font_size", 8)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	slot.add_child(name_lbl)
	
	# Level
	var level_lbl := Label.new()
	level_lbl.name = "Level"
	level_lbl.text = ""
	level_lbl.position = Vector2(80, 1)
	level_lbl.add_theme_font_size_override("font_size", 8)
	level_lbl.add_theme_color_override("font_color", Color.WHITE)
	slot.add_child(level_lbl)
	
	# HP bar background
	var hp_bg := ColorRect.new()
	hp_bg.color = Color(0.2, 0.2, 0.2)
	hp_bg.size = Vector2(60, 4)
	hp_bg.position = Vector2(22, 12)
	slot.add_child(hp_bg)
	
	# HP bar fill
	var hp_bar := ColorRect.new()
	hp_bar.name = "HPBar"
	hp_bar.color = Color(0.2, 0.8, 0.2)
	hp_bar.size = Vector2(60, 4)
	hp_bar.position = Vector2(22, 12)
	slot.add_child(hp_bar)
	
	# HP text
	var hp_lbl := Label.new()
	hp_lbl.name = "HP"
	hp_lbl.text = ""
	hp_lbl.position = Vector2(88, 9)
	hp_lbl.add_theme_font_size_override("font_size", 7)
	hp_lbl.add_theme_color_override("font_color", Color.WHITE)
	slot.add_child(hp_lbl)
	
	# Status icon placeholder
	var status := Label.new()
	status.name = "Status"
	status.text = ""
	status.position = Vector2(136, 6)
	status.add_theme_font_size_override("font_size", 6)
	status.add_theme_color_override("font_color", Color.YELLOW)
	slot.add_child(status)
	
	return slot


func _create_submenu() -> Control:
	"""Create the submenu for Pokemon options"""
	var menu := Control.new()
	menu.name = "Submenu"
	
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.2, 0.3)
	bg.size = Vector2(60, 56)
	menu.add_child(bg)
	
	var border := ColorRect.new()
	border.color = Color.WHITE
	border.size = Vector2(60, 2)
	menu.add_child(border)
	
	var border_l := ColorRect.new()
	border_l.color = Color.WHITE
	border_l.size = Vector2(2, 56)
	menu.add_child(border_l)
	
	for i in range(submenu_options.size()):
		var lbl := Label.new()
		lbl.name = "Option" + str(i)
		lbl.text = submenu_options[i]
		lbl.position = Vector2(12, 4 + i * 12)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		menu.add_child(lbl)
	
	return menu


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(4):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.WHITE)
	return ImageTexture.create_from_image(image)


func open(for_item: String = "") -> void:
	"""Open the party menu"""
	pending_item_id = for_item
	if pending_item_id != "":
		current_state = State.ITEM_USE
	else:
		current_state = State.SELECTING
	
	selected_index = 0
	submenu_index = 0
	visible = true
	_refresh_display()
	_update_cursor()


func close() -> void:
	"""Close the party menu"""
	visible = false
	menu_closed.emit()


func _refresh_display() -> void:
	"""Update all slot displays"""
	var party := GameManager.player_party
	
	for i in range(6):
		var slot := slots[i]
		var name_lbl: Label = slot.get_node("Name")
		var level_lbl: Label = slot.get_node("Level")
		var hp_bar: ColorRect = slot.get_node("HPBar")
		var hp_lbl: Label = slot.get_node("HP")
		var status_lbl: Label = slot.get_node("Status")
		var bg: ColorRect = slot.get_node("BG")
		
		if i < party.size() and party[i] != null:
			var pokemon: Pokemon = party[i]
			name_lbl.text = pokemon.get_display_name()
			level_lbl.text = "Lv" + str(pokemon.level)
			hp_lbl.text = str(pokemon.current_hp) + "/" + str(pokemon.max_hp)
			
			# HP bar
			var hp_percent := float(pokemon.current_hp) / float(pokemon.max_hp)
			hp_bar.size.x = 60 * hp_percent
			if hp_percent > 0.5:
				hp_bar.color = Color(0.2, 0.8, 0.2)
			elif hp_percent > 0.2:
				hp_bar.color = Color(0.8, 0.8, 0.2)
			else:
				hp_bar.color = Color(0.8, 0.2, 0.2)
			
			# Status
			status_lbl.text = _get_status_text(pokemon.status)
			
			# Background color
			if pokemon.is_fainted():
				bg.color = Color(0.35, 0.2, 0.2)
			elif i == selected_index and current_state == State.SWITCHING:
				bg.color = Color(0.35, 0.35, 0.2)
			else:
				bg.color = Color(0.25, 0.25, 0.35)
		else:
			name_lbl.text = "---"
			level_lbl.text = ""
			hp_lbl.text = ""
			hp_bar.size.x = 0
			status_lbl.text = ""
			bg.color = Color(0.18, 0.18, 0.25)


func _get_status_text(status: Pokemon.Status) -> String:
	match status:
		Pokemon.Status.BURN: return "BRN"
		Pokemon.Status.FREEZE: return "FRZ"
		Pokemon.Status.PARALYSIS: return "PAR"
		Pokemon.Status.POISON, Pokemon.Status.BADLY_POISONED: return "PSN"
		Pokemon.Status.SLEEP: return "SLP"
		_: return ""


func _update_cursor() -> void:
	cursor.visible = true
	
	match current_state:
		State.SELECTING, State.SWITCHING, State.ITEM_USE:
			if selected_index < 6:
				cursor.position = Vector2(2, 24 + selected_index * SLOT_HEIGHT)
			else:
				cursor.position = Vector2(114, 134)
		
		State.SUBMENU:
			cursor.position = submenu.position + Vector2(4, 8 + submenu_index * 12)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_a"):
		_handle_confirm()
	elif event.is_action_pressed("button_b"):
		_handle_cancel()
	elif event.is_action_pressed("move_up"):
		_navigate(Vector2i.UP)
	elif event.is_action_pressed("move_down"):
		_navigate(Vector2i.DOWN)


func _navigate(dir: Vector2i) -> void:
	match current_state:
		State.SELECTING, State.SWITCHING, State.ITEM_USE:
			var party_size := GameManager.player_party.size()
			var max_index := party_size  # +1 for cancel
			
			if dir == Vector2i.UP and selected_index > 0:
				selected_index -= 1
			elif dir == Vector2i.DOWN and selected_index < max_index:
				selected_index += 1
			
			_update_cursor()
		
		State.SUBMENU:
			if dir == Vector2i.UP and submenu_index > 0:
				submenu_index -= 1
			elif dir == Vector2i.DOWN and submenu_index < submenu_options.size() - 1:
				submenu_index += 1
			
			_update_cursor()


func _handle_confirm() -> void:
	match current_state:
		State.SELECTING:
			if selected_index >= GameManager.player_party.size():
				close()
			else:
				_show_submenu()
		
		State.SUBMENU:
			_select_submenu_option()
		
		State.SWITCHING:
			if selected_index != switch_from_index and selected_index < GameManager.player_party.size():
				_do_switch()
			current_state = State.SELECTING
			switch_from_index = -1
			_refresh_display()
			_update_cursor()
		
		State.ITEM_USE:
			if selected_index < GameManager.player_party.size():
				var pokemon: Pokemon = GameManager.player_party[selected_index]
				var item := ItemDatabase.get_item(pending_item_id)
				if item and item.can_use_on_pokemon(pokemon, false):
					var result := GameManager.player_inventory.use_item_on_pokemon(pending_item_id, pokemon, false)
					if result.success:
						_refresh_display()
						# Could show message here
					close()
				else:
					# Item can't be used on this Pokemon
					pass
			else:
				close()


func _handle_cancel() -> void:
	match current_state:
		State.SELECTING:
			close()
		State.SUBMENU:
			submenu.visible = false
			current_state = State.SELECTING
			_update_cursor()
		State.SWITCHING:
			current_state = State.SELECTING
			switch_from_index = -1
			_refresh_display()
			_update_cursor()
		State.ITEM_USE:
			close()


func _show_submenu() -> void:
	# Build submenu options for this Pokemon
	_build_submenu_options()
	_refresh_submenu_display()
	
	submenu.position = Vector2(96, 14 + selected_index * SLOT_HEIGHT)
	submenu.visible = true
	submenu_index = 0
	current_state = State.SUBMENU
	_update_cursor()


func _build_submenu_options() -> void:
	"""Build submenu options including field moves for selected Pokemon"""
	submenu_options.clear()
	_field_move_options.clear()
	
	# Always have SUMMARY first
	submenu_options.append("SUMMARY")
	
	# Add field moves if Pokemon has them
	if selected_index < GameManager.player_party.size():
		var pokemon: Pokemon = GameManager.player_party[selected_index]
		if pokemon and not pokemon.is_fainted():
			var moves := FieldMoveManager.get_available_moves(pokemon)
			for move in moves:
				var move_name := FieldMoveManager.get_move_name(move)
				submenu_options.append(move_name)
				_field_move_options.append(move_name)
	
	# Standard options at end
	submenu_options.append("SWITCH")
	submenu_options.append("ITEM")
	submenu_options.append("CANCEL")


func _refresh_submenu_display() -> void:
	"""Update submenu labels to match current options"""
	# Remove old option labels (keep background)
	for child in submenu.get_children():
		if child is Label and child.name.begins_with("Option"):
			child.queue_free()
	
	# Resize background
	var bg: ColorRect = submenu.get_child(0)
	if bg:
		bg.size.y = 8 + submenu_options.size() * 12
	
	# Create new labels
	for i in range(submenu_options.size()):
		var lbl := Label.new()
		lbl.name = "Option" + str(i)
		lbl.text = submenu_options[i]
		lbl.position = Vector2(12, 4 + i * 12)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		submenu.add_child(lbl)


func _select_submenu_option() -> void:
	var option := submenu_options[submenu_index]
	
	# Check if this is a field move option
	if option in _field_move_options:
		submenu.visible = false
		var pokemon: Pokemon = GameManager.player_party[selected_index]
		field_move_requested.emit(pokemon, option)
		close()
		return
	
	match option:
		"SUMMARY":
			submenu.visible = false
			current_state = State.SUMMARY
			summary_screen.open(GameManager.player_party[selected_index])
			pokemon_selected.emit(selected_index, GameManager.player_party[selected_index])
		
		"SWITCH":
			submenu.visible = false
			switch_from_index = selected_index
			current_state = State.SWITCHING
			_refresh_display()
			_update_cursor()
		
		"ITEM":
			item_use_requested.emit(selected_index)
			submenu.visible = false
			current_state = State.SELECTING
		
		"CANCEL":
			submenu.visible = false
			current_state = State.SELECTING
	
	_update_cursor()


func _on_summary_closed() -> void:
	current_state = State.SELECTING
	_update_cursor()


func _do_switch() -> void:
	"""Switch two Pokemon in the party"""
	if switch_from_index < 0 or switch_from_index >= GameManager.player_party.size():
		return
	if selected_index < 0 or selected_index >= GameManager.player_party.size():
		return
	
	var temp: Pokemon = GameManager.player_party[switch_from_index]
	GameManager.player_party[switch_from_index] = GameManager.player_party[selected_index]
	GameManager.player_party[selected_index] = temp
	
	switch_requested.emit(switch_from_index, selected_index)
