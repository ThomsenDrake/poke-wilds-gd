extends Control
class_name BuildMenu
## BuildMenu - UI for selecting structures to build
## Shows categories and available structures with material requirements

signal menu_closed()
signal structure_selected(structure_id: String)

# UI States
enum State {
	CATEGORY_SELECT,
	STRUCTURE_SELECT
}

var current_state: State = State.CATEGORY_SELECT
var selected_category_index: int = 0
var selected_structure_index: int = 0

# Constants
const SCREEN_WIDTH := 160
const SCREEN_HEIGHT := 144
const ITEM_HEIGHT := 12

# Current category structures
var _current_structures: Array = []
var _categories: Array = []

# Node references
var category_list: Control
var structure_list: Control
var info_panel: Control
var cursor: Sprite2D


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create the build menu UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.15, 0.2)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Title
	var title := Label.new()
	title.text = "BUILD"
	title.position = Vector2(64, 2)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)
	
	# Category list (left side)
	category_list = Control.new()
	category_list.name = "CategoryList"
	category_list.position = Vector2(4, 14)
	add_child(category_list)
	
	var cat_bg := ColorRect.new()
	cat_bg.color = Color(0.15, 0.2, 0.25)
	cat_bg.size = Vector2(50, 90)
	category_list.add_child(cat_bg)
	
	# Structure list (right side)
	structure_list = Control.new()
	structure_list.name = "StructureList"
	structure_list.position = Vector2(58, 14)
	structure_list.visible = false
	add_child(structure_list)
	
	var struct_bg := ColorRect.new()
	struct_bg.color = Color(0.15, 0.2, 0.25)
	struct_bg.size = Vector2(98, 90)
	structure_list.add_child(struct_bg)
	
	# Info panel (bottom)
	info_panel = Control.new()
	info_panel.name = "InfoPanel"
	info_panel.position = Vector2(4, 108)
	add_child(info_panel)
	
	var info_bg := ColorRect.new()
	info_bg.color = Color(0.2, 0.25, 0.3)
	info_bg.size = Vector2(152, 32)
	info_panel.add_child(info_bg)
	
	var info_label := Label.new()
	info_label.name = "InfoLabel"
	info_label.text = ""
	info_label.position = Vector2(4, 2)
	info_label.size = Vector2(144, 28)
	info_label.add_theme_font_size_override("font_size", 7)
	info_label.add_theme_color_override("font_color", Color.WHITE)
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	info_panel.add_child(info_label)
	
	# Cursor
	cursor = Sprite2D.new()
	cursor.texture = _create_cursor_texture()
	add_child(cursor)
	
	# Cancel label
	var cancel := Label.new()
	cancel.text = "B:Back"
	cancel.position = Vector2(120, 2)
	cancel.add_theme_font_size_override("font_size", 7)
	cancel.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(cancel)


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(6, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(3):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.WHITE)
	return ImageTexture.create_from_image(image)


func open() -> void:
	"""Open the build menu"""
	_build_category_list()
	current_state = State.CATEGORY_SELECT
	selected_category_index = 0
	selected_structure_index = 0
	structure_list.visible = false
	visible = true
	_update_cursor()
	_update_info()
	GameManager.change_state(GameManager.GameState.MENU)


func close() -> void:
	"""Close the build menu"""
	visible = false
	menu_closed.emit()


func _build_category_list() -> void:
	"""Build the category list"""
	# Clear old labels
	for child in category_list.get_children():
		if child is Label:
			child.queue_free()
	
	_categories.clear()
	
	# Get categories that have structures
	for cat in StructureData.Category.values():
		var structures := StructureDatabase.get_structures_by_category(cat)
		if structures.size() > 0:
			_categories.append(cat)
	
	# Create labels
	for i in range(_categories.size()):
		var cat: StructureData.Category = _categories[i]
		var lbl := Label.new()
		lbl.name = "Cat" + str(i)
		lbl.text = StructureData.get_category_name(cat)
		lbl.position = Vector2(8, 4 + i * ITEM_HEIGHT)
		lbl.add_theme_font_size_override("font_size", 7)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		category_list.add_child(lbl)


func _build_structure_list() -> void:
	"""Build the structure list for current category"""
	# Clear old labels
	for child in structure_list.get_children():
		if child is Label:
			child.queue_free()
	
	if selected_category_index >= _categories.size():
		return
	
	var cat: StructureData.Category = _categories[selected_category_index]
	_current_structures = StructureDatabase.get_structures_by_category(cat)
	
	# Create labels
	for i in range(mini(_current_structures.size(), 7)):  # Max 7 visible
		var structure: StructureData = _current_structures[i]
		var lbl := Label.new()
		lbl.name = "Struct" + str(i)
		lbl.text = structure.display_name
		lbl.position = Vector2(8, 4 + i * ITEM_HEIGHT)
		lbl.add_theme_font_size_override("font_size", 7)
		
		# Color based on affordability
		if structure.can_afford(GameManager.player_inventory):
			lbl.add_theme_color_override("font_color", Color.WHITE)
		else:
			lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		
		structure_list.add_child(lbl)


func _update_cursor() -> void:
	"""Update cursor position"""
	match current_state:
		State.CATEGORY_SELECT:
			cursor.position = category_list.position + Vector2(2, 8 + selected_category_index * ITEM_HEIGHT)
		State.STRUCTURE_SELECT:
			cursor.position = structure_list.position + Vector2(2, 8 + selected_structure_index * ITEM_HEIGHT)


func _update_info() -> void:
	"""Update info panel"""
	var info_label: Label = info_panel.get_node("InfoLabel")
	if info_label == null:
		return
	
	match current_state:
		State.CATEGORY_SELECT:
			if selected_category_index < _categories.size():
				var cat: StructureData.Category = _categories[selected_category_index]
				var count := StructureDatabase.get_structures_by_category(cat).size()
				info_label.text = StructureData.get_category_name(cat) + "\n" + str(count) + " structures"
			else:
				info_label.text = ""
		
		State.STRUCTURE_SELECT:
			if selected_structure_index < _current_structures.size():
				var structure: StructureData = _current_structures[selected_structure_index]
				var recipe_str := structure.get_recipe_string()
				info_label.text = structure.description + "\nNeeds: " + recipe_str


func _input(event: InputEvent) -> void:
	if not visible:
		return
	
	if event.is_action_pressed("button_a"):
		_handle_confirm()
	elif event.is_action_pressed("button_b"):
		_handle_cancel()
	elif event.is_action_pressed("move_up"):
		_navigate(-1)
	elif event.is_action_pressed("move_down"):
		_navigate(1)


func _navigate(dir: int) -> void:
	"""Navigate the menu"""
	match current_state:
		State.CATEGORY_SELECT:
			selected_category_index = clampi(selected_category_index + dir, 0, _categories.size() - 1)
		State.STRUCTURE_SELECT:
			selected_structure_index = clampi(selected_structure_index + dir, 0, _current_structures.size() - 1)
	
	_update_cursor()
	_update_info()


func _handle_confirm() -> void:
	"""Handle A button press"""
	match current_state:
		State.CATEGORY_SELECT:
			# Enter structure select
			_build_structure_list()
			structure_list.visible = true
			current_state = State.STRUCTURE_SELECT
			selected_structure_index = 0
			_update_cursor()
			_update_info()
		
		State.STRUCTURE_SELECT:
			# Select structure to build
			if selected_structure_index < _current_structures.size():
				var structure: StructureData = _current_structures[selected_structure_index]
				if structure.can_afford(GameManager.player_inventory):
					structure_selected.emit(structure.id)
					close()
				else:
					# Show "not enough materials" message
					var info_label: Label = info_panel.get_node("InfoLabel")
					if info_label:
						info_label.text = "Not enough materials!"


func _handle_cancel() -> void:
	"""Handle B button press"""
	match current_state:
		State.CATEGORY_SELECT:
			close()
		State.STRUCTURE_SELECT:
			structure_list.visible = false
			current_state = State.CATEGORY_SELECT
			_update_cursor()
			_update_info()
