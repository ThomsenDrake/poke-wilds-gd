extends Control

signal battle_finished(outcome: String, message: String)

@onready var _background: TextureRect = $Backdrop/BattleBackground
@onready var _enemy_sprite: TextureRect = $Backdrop/EnemySprite
@onready var _player_sprite: TextureRect = $Backdrop/PlayerSprite

@onready var _enemy_name: Label = $HUD/EnemyInfo/Name
@onready var _enemy_hp: Label = $HUD/EnemyInfo/HP
@onready var _player_name: Label = $HUD/PlayerInfo/Name
@onready var _player_hp: Label = $HUD/PlayerInfo/HP
@onready var _message_label: Label = $HUD/BottomPanel/Margin/Message

@onready var _action_menu: HBoxContainer = $HUD/BottomPanel/Margin/ActionMenu
@onready var _move_menu: GridContainer = $HUD/BottomPanel/Margin/MoveMenu
@onready var _bag_menu: HBoxContainer = $HUD/BottomPanel/Margin/BagMenu

@onready var _fight_button: Button = $HUD/BottomPanel/Margin/ActionMenu/FightButton
@onready var _bag_button: Button = $HUD/BottomPanel/Margin/ActionMenu/BagButton
@onready var _run_button: Button = $HUD/BottomPanel/Margin/ActionMenu/RunButton

@onready var _move_button_0: Button = $HUD/BottomPanel/Margin/MoveMenu/MoveButton0
@onready var _move_button_1: Button = $HUD/BottomPanel/Margin/MoveMenu/MoveButton1
@onready var _move_button_2: Button = $HUD/BottomPanel/Margin/MoveMenu/MoveButton2
@onready var _move_button_3: Button = $HUD/BottomPanel/Margin/MoveMenu/MoveButton3
@onready var _move_back_button: Button = $HUD/BottomPanel/Margin/MoveMenu/MoveBackButton

@onready var _pokeball_button: Button = $HUD/BottomPanel/Margin/BagMenu/PokeballButton
@onready var _potion_button: Button = $HUD/BottomPanel/Margin/BagMenu/PotionButton
@onready var _bag_back_button: Button = $HUD/BottomPanel/Margin/BagMenu/BagBackButton

var _rng = RandomNumberGenerator.new()
var _active = false
var _player_party_index = -1
var _player_mon: Dictionary = {}
var _enemy_mon: Dictionary = {}


func _ready() -> void:
	visible = false
	_rng.randomize()
	_background.texture = load("res://pokewilds/battle/battle_bg1.png")

	_fight_button.pressed.connect(_on_fight_pressed)
	_bag_button.pressed.connect(_on_bag_pressed)
	_run_button.pressed.connect(_on_run_pressed)

	_move_button_0.pressed.connect(func() -> void: _on_move_pressed(0))
	_move_button_1.pressed.connect(func() -> void: _on_move_pressed(1))
	_move_button_2.pressed.connect(func() -> void: _on_move_pressed(2))
	_move_button_3.pressed.connect(func() -> void: _on_move_pressed(3))
	_move_back_button.pressed.connect(_show_action_menu)

	_pokeball_button.pressed.connect(_on_pokeball_pressed)
	_potion_button.pressed.connect(_on_potion_pressed)
	_bag_back_button.pressed.connect(_show_action_menu)


func start_wild_battle(wild_mon: Dictionary) -> void:
	var state: Node = _state()
	_player_party_index = int(state.call("get_active_party_index"))
	if _player_party_index < 0:
		state.call("heal_party_full")
		_player_party_index = int(state.call("get_active_party_index"))
	if _player_party_index < 0:
		_end_battle("defeat", "Your party has no usable Pokémon.")
		return

	var current_player = state.call("get_party_member", _player_party_index)
	if current_player is not Dictionary:
		_end_battle("defeat", "Could not load active party member.")
		return

	_player_mon = (current_player as Dictionary).duplicate(true)
	_enemy_mon = wild_mon.duplicate(true)
	_active = true
	visible = true

	_setup_battle_visuals()
	_refresh_ui()
	_set_message("A wild %s appeared!" % str(_enemy_mon.get("name", "Pokémon")))
	_show_action_menu()


func _setup_battle_visuals() -> void:
	_enemy_sprite.texture = _load_pokemon_frame(str(_enemy_mon.get("front_path", "")))
	_player_sprite.texture = _load_pokemon_frame(str(_player_mon.get("back_path", "")))


func _refresh_ui() -> void:
	_enemy_name.text = "%s Lv.%d" % [str(_enemy_mon.get("name", "?")), int(_enemy_mon.get("level", 1))]
	_enemy_hp.text = "HP %d/%d" % [int(_enemy_mon.get("current_hp", 0)), int(_enemy_mon.get("max_hp", 1))]
	_player_name.text = "%s Lv.%d" % [str(_player_mon.get("name", "?")), int(_player_mon.get("level", 1))]
	_player_hp.text = "HP %d/%d" % [int(_player_mon.get("current_hp", 0)), int(_player_mon.get("max_hp", 1))]
	_refresh_move_buttons()
	_refresh_bag_buttons()


func _refresh_move_buttons() -> void:
	var move_buttons: Array = [_move_button_0, _move_button_1, _move_button_2, _move_button_3]
	var moves = _player_mon.get("moves", [])
	for i in range(move_buttons.size()):
		var button: Button = move_buttons[i]
		if i < moves.size():
			var move = moves[i]
			var move_name = str(move.get("name", move.get("move_id", "Move")))
			var pp = int(move.get("pp", 0))
			var max_pp = int(move.get("max_pp", 0))
			button.text = "%s (%d/%d)" % [move_name, pp, max_pp]
			button.disabled = pp <= 0
			button.visible = true
		else:
			button.text = "-"
			button.disabled = true
			button.visible = true


func _refresh_bag_buttons() -> void:
	var state: Node = _state()
	var pokeballs = int(state.call("get_item_count", "pokeball"))
	var potions = int(state.call("get_item_count", "potion"))
	_pokeball_button.text = "Poké Ball x%d" % pokeballs
	_potion_button.text = "Potion x%d" % potions
	_pokeball_button.disabled = pokeballs <= 0
	_potion_button.disabled = potions <= 0


func _on_fight_pressed() -> void:
	if not _active:
		return
	_show_move_menu()


func _on_bag_pressed() -> void:
	if not _active:
		return
	_show_bag_menu()


func _on_run_pressed() -> void:
	if not _active:
		return
	_end_battle("escaped", "Got away safely!")


func _on_move_pressed(index: int) -> void:
	if not _active:
		return
	var moves = _player_mon.get("moves", [])
	if index < 0 or index >= moves.size():
		return

	var move: Dictionary = moves[index]
	var pp = int(move.get("pp", 0))
	if pp <= 0:
		_set_message("No PP left for that move.")
		_show_action_menu()
		return

	move["pp"] = pp - 1
	moves[index] = move
	_player_mon["moves"] = moves

	var turn_text = _apply_attack(_player_mon, _enemy_mon, move)
	if int(_enemy_mon.get("current_hp", 0)) <= 0:
		_set_message("%s\nWild %s fainted!" % [turn_text, str(_enemy_mon.get("name", "Pokémon"))])
		_handle_victory("victory", "You won the battle.")
		return

	turn_text += "\n" + _enemy_take_turn()
	_refresh_ui()
	_set_message(turn_text)

	if int(_player_mon.get("current_hp", 0)) <= 0:
		_handle_player_faint()
		return
	_show_action_menu()


func _on_pokeball_pressed() -> void:
	if not _active:
		return
	var state: Node = _state()
	if not bool(state.call("consume_item", "pokeball", 1)):
		_set_message("No Poké Balls left.")
		_show_action_menu()
		return

	var enemy_hp = int(_enemy_mon.get("current_hp", 1))
	var enemy_max_hp = max(1, int(_enemy_mon.get("max_hp", 1)))
	var hp_ratio = float(enemy_hp) / float(enemy_max_hp)
	var catch_chance = clampf(0.15 + ((1.0 - hp_ratio) * 0.75), 0.15, 0.9)

	if _rng.randf() <= catch_chance:
		var caught = bool(state.call("add_pokemon_to_party", _enemy_mon.duplicate(true)))
		_refresh_bag_buttons()
		if caught:
			_handle_victory("caught", "Gotcha! %s was caught." % str(_enemy_mon.get("name", "Pokémon")))
		else:
			_handle_victory("caught_box_full", "Caught %s, but your party is full." % str(_enemy_mon.get("name", "Pokémon")))
		return

	var text = "The wild %s broke free!" % str(_enemy_mon.get("name", "Pokémon"))
	text += "\n" + _enemy_take_turn()
	_refresh_ui()
	_set_message(text)
	if int(_player_mon.get("current_hp", 0)) <= 0:
		_handle_player_faint()
		return
	_show_action_menu()


func _on_potion_pressed() -> void:
	if not _active:
		return
	var state: Node = _state()
	if not bool(state.call("consume_item", "potion", 1)):
		_set_message("No Potions left.")
		_show_action_menu()
		return

	var max_hp = int(_player_mon.get("max_hp", 1))
	var current_hp = int(_player_mon.get("current_hp", 1))
	if current_hp >= max_hp:
		state.call("add_item", "potion", 1)
		_set_message("HP is already full.")
		_show_action_menu()
		return

	var healed = min(20, max_hp - current_hp)
	_player_mon["current_hp"] = current_hp + healed
	var text = "%s recovered %d HP." % [str(_player_mon.get("name", "Pokémon")), healed]
	text += "\n" + _enemy_take_turn()
	_refresh_ui()
	_set_message(text)
	if int(_player_mon.get("current_hp", 0)) <= 0:
		_handle_player_faint()
		return
	_show_action_menu()


func _enemy_take_turn() -> String:
	var moves = _enemy_mon.get("moves", [])
	var usable_indexes: Array = []
	for i in range(moves.size()):
		var move = moves[i]
		if int(move.get("pp", 0)) > 0:
			usable_indexes.append(i)

	if usable_indexes.is_empty():
		return "%s has no moves left." % str(_enemy_mon.get("name", "Wild Pokémon"))

	var pick = int(usable_indexes[_rng.randi_range(0, usable_indexes.size() - 1)])
	var chosen_move: Dictionary = moves[pick]
	chosen_move["pp"] = int(chosen_move.get("pp", 0)) - 1
	moves[pick] = chosen_move
	_enemy_mon["moves"] = moves

	return _apply_attack(_enemy_mon, _player_mon, chosen_move)


func _apply_attack(attacker: Dictionary, defender: Dictionary, move: Dictionary) -> String:
	var attacker_name = str(attacker.get("name", "Pokémon"))
	var defender_name = str(defender.get("name", "Pokémon"))
	var move_name = str(move.get("name", move.get("move_id", "move")))
	var power = int(move.get("power", 0))
	var accuracy = int(move.get("accuracy", 100))

	if _rng.randi_range(1, 100) > accuracy:
		return "%s used %s.\nBut it missed!" % [attacker_name, move_name]

	if power <= 0:
		return "%s used %s.\nBut nothing happened." % [attacker_name, move_name]

	var level = int(attacker.get("level", 1))
	var attacker_stats = attacker.get("stats", {})
	var defender_stats = defender.get("stats", {})
	var category = str(move.get("category", "PHYSICAL"))

	var attack_stat = int(attacker_stats.get("atk", 5))
	var defense_stat = int(defender_stats.get("def", 5))
	if category == "SPECIAL":
		attack_stat = int(attacker_stats.get("sat", 5))
		defense_stat = int(defender_stats.get("sdf", 5))

	var base_damage = (((2.0 * level / 5.0 + 2.0) * power * max(1, attack_stat) / max(1, defense_stat)) / 50.0) + 2.0
	var random_roll = _rng.randf_range(0.85, 1.0)
	var damage = maxi(1, int(floor(base_damage * random_roll)))

	var current_hp = int(defender.get("current_hp", 1))
	defender["current_hp"] = maxi(0, current_hp - damage)

	var text = "%s used %s!\n%s took %d damage." % [attacker_name, move_name, defender_name, damage]
	if int(defender["current_hp"]) <= 0:
		text += "\n%s fainted!" % defender_name
	return text


func _handle_player_faint() -> void:
	var state: Node = _state()
	var next_index = int(state.call("get_next_healthy_party_index", _player_party_index))
	if next_index >= 0:
		state.call("set_party_member", _player_party_index, _player_mon)
		_player_party_index = next_index
		var replacement = state.call("get_party_member", _player_party_index)
		if replacement is Dictionary:
			_player_mon = (replacement as Dictionary).duplicate(true)
			_setup_battle_visuals()
			_refresh_ui()
			_set_message("%s, go!" % str(_player_mon.get("name", "Pokémon")))
			_show_action_menu()
			return

	_end_battle("defeat", "You blacked out.")


func _handle_victory(outcome: String, base_message: String) -> void:
	var state: Node = _state()
	var exp_reward = max(10, int(_enemy_mon.get("level", 1)) * 18)
	var summary = state.call("award_experience", _player_party_index, exp_reward)
	var updated_mon = state.call("get_party_member", _player_party_index)
	if updated_mon is Dictionary:
		_player_mon = (updated_mon as Dictionary).duplicate(true)

	var message = "%s +%d EXP." % [base_message, exp_reward]
	if summary is Dictionary:
		var data: Dictionary = summary
		var levels_gained = int(data.get("levels_gained", 0))
		if levels_gained > 0:
			message += " %s grew to Lv.%d." % [str(_player_mon.get("name", "Pokémon")), int(data.get("new_level", 1))]
			var learned = data.get("learned_moves", [])
			if learned is Array and not learned.is_empty():
				message += " Learned: %s." % ", ".join(learned)
	_end_battle(outcome, message)


func _end_battle(outcome: String, message: String) -> void:
	var state: Node = _state()
	if _player_party_index >= 0 and not _player_mon.is_empty():
		state.call("set_party_member", _player_party_index, _player_mon)

	if outcome == "defeat":
		state.call("heal_party_full")
		state.set("player_tile", Vector2i.ZERO)

	state.call("save_game")
	_active = false
	visible = false
	battle_finished.emit(outcome, message)


func _show_action_menu() -> void:
	_action_menu.visible = true
	_move_menu.visible = false
	_bag_menu.visible = false


func _show_move_menu() -> void:
	_action_menu.visible = false
	_move_menu.visible = true
	_bag_menu.visible = false


func _show_bag_menu() -> void:
	_action_menu.visible = false
	_move_menu.visible = false
	_bag_menu.visible = true
	_refresh_bag_buttons()


func _set_message(text: String) -> void:
	_message_label.text = text


func _load_pokemon_frame(path: String) -> Texture2D:
	var fallback_path = "res://pokewilds/pokemon/not_found.png"
	if path.is_empty() or not ResourceLoader.exists(path):
		return load(fallback_path)

	var texture = load(path)
	if texture == null:
		return load(fallback_path)
	if texture is not Texture2D:
		return load(fallback_path)

	var tex2d: Texture2D = texture
	var width = tex2d.get_width()
	var height = tex2d.get_height()
	if height > width:
		var frame = AtlasTexture.new()
		frame.atlas = tex2d
		frame.region = Rect2(0, 0, width, width)
		return frame
	return tex2d


func _state() -> Node:
	return get_node("/root/GameState")
