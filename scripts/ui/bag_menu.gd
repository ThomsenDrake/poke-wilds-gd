extends Control
class_name BagMenu
## BagMenu - UI for viewing and using items from the player's bag
## Shows categories, item list, info panel, and use/give/toss options

signal menu_closed()
signal item_used(item_id: String, target_pokemon: Pokemon)

# UI States
enum State {
	CATEGORY_SELECT,
	ITEM_SELECT,
	ACTION_SELECT,
	POKEMON_SELECT
}

var current_state: State = State.CATEGORY_SELECT
var selected_category_index: int = 0
var selected_item_index: int = 0
var selected_action_index: int = 0
var scroll_offset: int = 0

# Get viewport dimensions from GameManager
var SCREEN_WIDTH: int:
	get: return GameManager.BASE_VIEWPORT_WIDTH
var SCREEN_HEIGHT: int:
	get: return GameManager.BASE_VIEWPORT_HEIGHT
const ITEM_HEIGHT := 12
const MAX_VISIBLE_ITEMS := 10  # Increased for larger viewport

# Action menu options
var actions := ["USE", "GIVE", "TOSS"]
var selected_item_id: String = ""

# Current category items
var _current_items: Array[Dictionary] = []
var _categories: Array = []

# Node references
var category_list: Control
var item_list: Control
var info_panel: Control
var action_menu: Control
var cursor: Sprite2D


func _ready() -> void:
	_create_ui()
	visible = false


func _create_ui() -> void:
	"""Create the bag menu UI"""
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.18)
	bg.size = Vector2(SCREEN_WIDTH, SCREEN_HEIGHT)
	add_child(bg)
	
	# Title
	var title := Label.new()
	title.text = "BAG"
	title.position = Vector2(70, 2)
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)
	
	# Category tabs (top row)
	category_list = Control.new()
	category_list.name = "CategoryList"
	category_list.position = Vector2(4, 12)
	add_child(category_list)
	
	var cat_bg := ColorRect.new()
	cat_bg.color = Color(0.18, 0.18, 0.24)
	cat_bg.size = Vector2(152, 14)
	category_list.add_child(cat_bg)
	
	# Item list (main area)
	item_list = Control.new()
	item_list.name = "ItemList"
	item_list.position = Vector2(4, 28)
	add_child(item_list)
	
	var item_bg := ColorRect.new()
	item_bg.color = Color(0.15, 0.18, 0.22)
	item_bg.size = Vector2(100, 76)
	item_list.add_child(item_bg)
	
	# Info panel (right side)
	info_panel = Control.new()
	info_panel.name = "InfoPanel"
	info_panel.position = Vector2(108, 28)
	add_child(info_panel)
	
	var info_bg := ColorRect.new()
	info_bg.color = Color(0.2, 0.22, 0.28)
	info_bg.size = Vector2(48, 76)
	info_panel.add_child(info_bg)
	
	var info_label := Label.new()
	info_label.name = "InfoLabel"
	info_label.text = ""
	info_label.position = Vector2(2, 2)
	info_label.size = Vector2(44, 72)
	info_label.add_theme_font_size_override("font_size", 6)
	info_label.add_theme_color_override("font_color", Color.WHITE)
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	info_panel.add_child(info_label)
	
	# Description panel (bottom)
	var desc_panel := Control.new()
	desc_panel.name = "DescPanel"
	desc_panel.position = Vector2(4, 108)
	add_child(desc_panel)
	
	var desc_bg := ColorRect.new()
	desc_bg.color = Color(0.2, 0.22, 0.28)
	desc_bg.size = Vector2(152, 32)
	desc_panel.add_child(desc_bg)
	
	var desc_label := Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = "Select an item."
	desc_label.position = Vector2(4, 2)
	desc_label.size = Vector2(144, 28)
	desc_label.add_theme_font_size_override("font_size", 7)
	desc_label.add_theme_color_override("font_color", Color.WHITE)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_panel.add_child(desc_label)
	
	# Action menu (popup)
	action_menu = Control.new()
	action_menu.name = "ActionMenu"
	action_menu.position = Vector2(100, 40)
	action_menu.visible = false
	add_child(action_menu)
	
	var action_bg := ColorRect.new()
	action_bg.color = Color(0.95, 0.95, 0.95)
	action_bg.size = Vector2(50, 44)
	action_menu.add_child(action_bg)
	
	# Action menu border
	_add_border(action_menu, 50, 44)
	
	for i in range(actions.size()):
		var lbl := Label.new()
		lbl.name = "Action" + str(i)
		lbl.text = actions[i]
		lbl.position = Vector2(12, 4 + i * 12)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.BLACK)
		action_menu.add_child(lbl)
	
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


func _add_border(parent: Control, width: float, height: float) -> void:
	"""Add border lines to a control"""
	var colors := [Color.BLACK]
	for c in colors:
		var top := ColorRect.new()
		top.color = c
		top.size = Vector2(width, 2)
		parent.add_child(top)
		
		var bottom := ColorRect.new()
		bottom.color = c
		bottom.size = Vector2(width, 2)
		bottom.position = Vector2(0, height - 2)
		parent.add_child(bottom)
		
		var left := ColorRect.new()
		left.color = c
		left.size = Vector2(2, height)
		parent.add_child(left)
		
		var right := ColorRect.new()
		right.color = c
		right.size = Vector2(2, height)
		right.position = Vector2(width - 2, 0)
		parent.add_child(right)


func _create_cursor_texture() -> ImageTexture:
	var image := Image.create(6, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for i in range(3):
		for j in range(-i, i + 1):
			if 3 + j >= 0 and 3 + j < 8:
				image.set_pixel(i, 3 + j, Color.WHITE)
	return ImageTexture.create_from_image(image)


func open() -> void:
	"""Open the bag menu"""
	_build_category_list()
	current_state = State.CATEGORY_SELECT
	selected_category_index = 0
	selected_item_index = 0
	scroll_offset = 0
	action_menu.visible = false
	visible = true
	_update_item_list()
	_update_cursor()
	_update_info()


func close() -> void:
	"""Close the bag menu"""
	visible = false
	menu_closed.emit()


func _build_category_list() -> void:
	"""Build the category tabs"""
	# Clear old labels
	for child in category_list.get_children():
		if child is Label:
			child.queue_free()
	
	_categories.clear()
	
	# Categories to display (order matters)
	var all_cats := [
		ItemData.Category.MEDICINE,
		ItemData.Category.POKEBALL,
		ItemData.Category.BATTLE,
		ItemData.Category.BERRY,
		ItemData.Category.KEY_ITEM,
		ItemData.Category.MATERIAL
	]
	
	# Only show categories that have items or are standard
	for cat in all_cats:
		_categories.append(cat)
	
	# Create category tab labels
	var x_pos := 4
	for i in range(_categories.size()):
		var cat: ItemData.Category = _categories[i]
		var short_name := _get_category_short_name(cat)
		var lbl := Label.new()
		lbl.name = "Cat" + str(i)
		lbl.text = short_name
		lbl.position = Vector2(x_pos, 2)
		lbl.add_theme_font_size_override("font_size", 6)
		
		if i == selected_category_index:
			lbl.add_theme_color_override("font_color", Color.YELLOW)
		else:
			lbl.add_theme_color_override("font_color", Color.WHITE)
		
		category_list.add_child(lbl)
		x_pos += short_name.length() * 5 + 6


func _get_category_short_name(cat: ItemData.Category) -> String:
	"""Get abbreviated category name for tabs"""
	match cat:
		ItemData.Category.MEDICINE: return "MED"
		ItemData.Category.POKEBALL: return "BALL"
		ItemData.Category.BATTLE: return "BTL"
		ItemData.Category.BERRY: return "BRY"
		ItemData.Category.KEY_ITEM: return "KEY"
		ItemData.Category.MATERIAL: return "MAT"
		_: return "???"


func _update_item_list() -> void:
	"""Update the item list for current category"""
	# Clear old labels
	for child in item_list.get_children():
		if child is Label:
			child.queue_free()
	
	if selected_category_index >= _categories.size():
		_current_items.clear()
		return
	
	var cat: ItemData.Category = _categories[selected_category_index]
	_current_items = GameManager.player_inventory.get_items_by_category(cat)
	
	if _current_items.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.name = "Empty"
		empty_lbl.text = "No items"
		empty_lbl.position = Vector2(8, 4)
		empty_lbl.add_theme_font_size_override("font_size", 7)
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		item_list.add_child(empty_lbl)
		return
	
	# Create labels for visible items
	for i in range(mini(_current_items.size() - scroll_offset, MAX_VISIBLE_ITEMS)):
		var item_idx := scroll_offset + i
		if item_idx >= _current_items.size():
			break
		
		var item_data: Dictionary = _current_items[item_idx]
		var item: ItemData = item_data.item
		var qty: int = item_data.quantity
		
		# Item name
		var name_lbl := Label.new()
		name_lbl.name = "Item" + str(i)
		name_lbl.text = item.display_name
		name_lbl.position = Vector2(10, 4 + i * ITEM_HEIGHT)
		name_lbl.add_theme_font_size_override("font_size", 7)
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
		item_list.add_child(name_lbl)
		
		# Quantity
		var qty_lbl := Label.new()
		qty_lbl.name = "Qty" + str(i)
		qty_lbl.text = "x" + str(qty)
		qty_lbl.position = Vector2(75, 4 + i * ITEM_HEIGHT)
		qty_lbl.add_theme_font_size_override("font_size", 7)
		qty_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		item_list.add_child(qty_lbl)
	
	# Scroll indicators
	if scroll_offset > 0:
		var up_lbl := Label.new()
		up_lbl.text = "^"
		up_lbl.position = Vector2(90, 2)
		up_lbl.add_theme_font_size_override("font_size", 7)
		up_lbl.add_theme_color_override("font_color", Color.WHITE)
		item_list.add_child(up_lbl)
	
	if scroll_offset + MAX_VISIBLE_ITEMS < _current_items.size():
		var down_lbl := Label.new()
		down_lbl.text = "v"
		down_lbl.position = Vector2(90, 66)
		down_lbl.add_theme_font_size_override("font_size", 7)
		down_lbl.add_theme_color_override("font_color", Color.WHITE)
		item_list.add_child(down_lbl)


func _update_cursor() -> void:
	"""Update cursor position"""
	cursor.modulate = Color.WHITE
	
	match current_state:
		State.CATEGORY_SELECT:
			# Hide cursor in category mode (we highlight the text instead)
			cursor.visible = false
		
		State.ITEM_SELECT:
			cursor.visible = true
			if _current_items.is_empty():
				cursor.visible = false
			else:
				var visual_index := selected_item_index - scroll_offset
				cursor.position = item_list.position + Vector2(4, 8 + visual_index * ITEM_HEIGHT)
		
		State.ACTION_SELECT:
			cursor.visible = true
			cursor.modulate = Color.BLACK
			cursor.position = action_menu.position + Vector2(4, 8 + selected_action_index * 12)
		
		State.POKEMON_SELECT:
			cursor.visible = false


func _update_info() -> void:
	"""Update info and description panels"""
	var info_label: Label = info_panel.get_node("InfoLabel")
	var desc_label: Label = get_node("DescPanel/DescLabel")
	
	if current_state == State.CATEGORY_SELECT:
		if info_label:
			var cat: ItemData.Category = _categories[selected_category_index]
			var count := GameManager.player_inventory.get_items_by_category(cat).size()
			info_label.text = str(count) + " types"
		if desc_label:
			var cat: ItemData.Category = _categories[selected_category_index]
			desc_label.text = ItemData.get_category_name(cat)
		return
	
	if _current_items.is_empty() or selected_item_index >= _current_items.size():
		if info_label:
			info_label.text = ""
		if desc_label:
			desc_label.text = "No items in this pocket."
		return
	
	var item_data: Dictionary = _current_items[selected_item_index]
	var item: ItemData = item_data.item
	
	if info_label:
		var lines := []
		if item.buy_price > 0:
			lines.append("Buy: $" + str(item.buy_price))
		if item.sell_price > 0:
			lines.append("Sell: $" + str(item.sell_price))
		info_label.text = "\n".join(lines)
	
	if desc_label:
		desc_label.text = item.description


func _update_category_highlights() -> void:
	"""Update category tab highlights"""
	for i in range(_categories.size()):
		var lbl: Label = category_list.get_node_or_null("Cat" + str(i))
		if lbl:
			if i == selected_category_index:
				lbl.add_theme_color_override("font_color", Color.YELLOW)
			else:
				lbl.add_theme_color_override("font_color", Color.WHITE)


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
	elif event.is_action_pressed("move_left"):
		_navigate_category(-1)
	elif event.is_action_pressed("move_right"):
		_navigate_category(1)


func _navigate(dir: int) -> void:
	"""Navigate up/down in current list"""
	match current_state:
		State.CATEGORY_SELECT:
			# In category mode, up/down enters item list
			if dir > 0 and not _current_items.is_empty():
				current_state = State.ITEM_SELECT
				selected_item_index = 0
				scroll_offset = 0
		
		State.ITEM_SELECT:
			if _current_items.is_empty():
				return
			
			selected_item_index = clampi(selected_item_index + dir, 0, _current_items.size() - 1)
			
			# Handle scrolling
			if selected_item_index < scroll_offset:
				scroll_offset = selected_item_index
				_update_item_list()
			elif selected_item_index >= scroll_offset + MAX_VISIBLE_ITEMS:
				scroll_offset = selected_item_index - MAX_VISIBLE_ITEMS + 1
				_update_item_list()
		
		State.ACTION_SELECT:
			selected_action_index = clampi(selected_action_index + dir, 0, actions.size() - 1)
	
	_update_cursor()
	_update_info()


func _navigate_category(dir: int) -> void:
	"""Navigate between categories"""
	if current_state != State.CATEGORY_SELECT and current_state != State.ITEM_SELECT:
		return
	
	selected_category_index = clampi(selected_category_index + dir, 0, _categories.size() - 1)
	selected_item_index = 0
	scroll_offset = 0
	
	# Stay in category select when navigating
	current_state = State.CATEGORY_SELECT
	
	_update_category_highlights()
	_update_item_list()
	_update_cursor()
	_update_info()


func _handle_confirm() -> void:
	"""Handle A button press"""
	match current_state:
		State.CATEGORY_SELECT:
			# Enter item select
			if not _current_items.is_empty():
				current_state = State.ITEM_SELECT
				selected_item_index = 0
				_update_cursor()
		
		State.ITEM_SELECT:
			# Open action menu
			if selected_item_index < _current_items.size():
				var item_data: Dictionary = _current_items[selected_item_index]
				selected_item_id = item_data.item_id
				
				# Update available actions based on item
				_update_actions_for_item(item_data.item)
				
				action_menu.visible = true
				current_state = State.ACTION_SELECT
				selected_action_index = 0
				_update_cursor()
		
		State.ACTION_SELECT:
			_execute_action()


func _update_actions_for_item(item: ItemData) -> void:
	"""Update available actions based on item type"""
	actions.clear()
	
	# Can use?
	if item.usable_outside_battle:
		actions.append("USE")
	
	# Can give to Pokemon?
	if item.holdable:
		actions.append("GIVE")
	
	# Can toss? (not key items)
	if item.category != ItemData.Category.KEY_ITEM:
		actions.append("TOSS")
	
	# Update action menu labels
	for child in action_menu.get_children():
		if child is Label and child.name.begins_with("Action"):
			child.queue_free()
	
	# Resize action menu
	var action_bg: ColorRect = action_menu.get_child(0)
	action_bg.size.y = 8 + actions.size() * 12
	
	for i in range(actions.size()):
		var lbl := Label.new()
		lbl.name = "Action" + str(i)
		lbl.text = actions[i]
		lbl.position = Vector2(12, 4 + i * 12)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", Color.BLACK)
		action_menu.add_child(lbl)


func _execute_action() -> void:
	"""Execute the selected action"""
	if selected_action_index >= actions.size():
		return
	
	var action: String = actions[selected_action_index]
	
	match action:
		"USE":
			_use_item()
		"GIVE":
			_give_item()
		"TOSS":
			_toss_item()
	
	action_menu.visible = false
	current_state = State.ITEM_SELECT
	_update_item_list()
	_update_cursor()
	_update_info()


func _use_item() -> void:
	"""Use the selected item"""
	var item := ItemDatabase.get_item(selected_item_id)
	if item == null:
		return
	
	# For healing items, need to select Pokemon
	match item.effect:
		ItemData.Effect.HEAL_HP, ItemData.Effect.HEAL_STATUS, ItemData.Effect.HEAL_ALL, \
		ItemData.Effect.HEAL_PP, ItemData.Effect.REVIVE, ItemData.Effect.MAX_REVIVE:
			# Need Pokemon selection - emit signal for parent to handle
			item_used.emit(selected_item_id, null)
			close()
		
		_:
			# Item can't be used directly
			var desc_label: Label = get_node("DescPanel/DescLabel")
			if desc_label:
				desc_label.text = "Can't use that here."


func _give_item() -> void:
	"""Give item to a Pokemon"""
	# Would open Pokemon selection
	# For now, just show message
	var desc_label: Label = get_node("DescPanel/DescLabel")
	if desc_label:
		desc_label.text = "Select a Pokemon to hold this item."
	
	# TODO: Implement Pokemon selection for giving items
	item_used.emit(selected_item_id, null)
	close()


func _toss_item() -> void:
	"""Toss the selected item"""
	if GameManager.player_inventory.remove_item(selected_item_id, 1):
		var desc_label: Label = get_node("DescPanel/DescLabel")
		if desc_label:
			desc_label.text = "Threw away 1 item."
		
		# Refresh the list
		_current_items = GameManager.player_inventory.get_items_by_category(_categories[selected_category_index])
		
		# Adjust selection if needed
		if selected_item_index >= _current_items.size():
			selected_item_index = maxi(0, _current_items.size() - 1)
		if scroll_offset > 0 and scroll_offset >= _current_items.size():
			scroll_offset = maxi(0, _current_items.size() - MAX_VISIBLE_ITEMS)


func _handle_cancel() -> void:
	"""Handle B button press"""
	match current_state:
		State.CATEGORY_SELECT:
			close()
		
		State.ITEM_SELECT:
			current_state = State.CATEGORY_SELECT
			_update_cursor()
			_update_info()
		
		State.ACTION_SELECT:
			action_menu.visible = false
			current_state = State.ITEM_SELECT
			_update_cursor()
		
		State.POKEMON_SELECT:
			current_state = State.ACTION_SELECT
			_update_cursor()
