extends Control

signal closed
signal game_reset

@onready var _party_list: ItemList = $Panel/Margin/VBox/PartyLabel/PartyList
@onready var _bag_label: Label = $Panel/Margin/VBox/BagLabel
@onready var _set_lead_button: Button = $Panel/Margin/VBox/Buttons/SetLeadButton
@onready var _save_button: Button = $Panel/Margin/VBox/Buttons/SaveButton
@onready var _new_game_button: Button = $Panel/Margin/VBox/Buttons/NewGameButton
@onready var _close_button: Button = $Panel/Margin/VBox/Buttons/CloseButton


func _ready() -> void:
	visible = false
	_party_list.select_mode = ItemList.SELECT_SINGLE
	_set_lead_button.pressed.connect(_on_set_lead_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_close_button.pressed.connect(_on_close_pressed)


func show_menu() -> void:
	visible = true
	_refresh()


func hide_menu() -> void:
	visible = false
	closed.emit()


func _refresh() -> void:
	var state: Node = _state()
	var party = state.get("party")
	_party_list.clear()

	if party is Array:
		for i in range(party.size()):
			var mon_variant = party[i]
			if mon_variant is not Dictionary:
				continue
			var mon: Dictionary = mon_variant
			var line = "%d. %s Lv.%d HP %d/%d" % [
				i + 1,
				str(mon.get("name", "Pokémon")),
				int(mon.get("level", 1)),
				int(mon.get("current_hp", 0)),
				int(mon.get("max_hp", 1))
			]
			if i == 0:
				line += "  [LEAD]"
			_party_list.add_item(line)

	var pokeballs = int(state.call("get_item_count", "pokeball"))
	var potions = int(state.call("get_item_count", "potion"))
	_bag_label.text = "Bag: Poké Balls x%d, Potions x%d" % [pokeballs, potions]


func _on_set_lead_pressed() -> void:
	var selected = _party_list.get_selected_items()
	if selected.is_empty():
		return
	var index = int(selected[0])
	_state().call("set_party_lead", index)
	_refresh()


func _on_save_pressed() -> void:
	_state().call("save_game")
	_refresh()


func _on_new_game_pressed() -> void:
	_state().call("new_game")
	_refresh()
	game_reset.emit()


func _on_close_pressed() -> void:
	hide_menu()


func _state() -> Node:
	return get_node("/root/GameState")
