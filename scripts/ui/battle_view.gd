extends Control

signal battle_finished(outcome: String, message: String)

const RuntimePath := "/root/GameRuntime"

@onready var _background: TextureRect = $Backdrop/BattleBackground
@onready var _enemy_sprite: TextureRect = $Backdrop/EnemySprite
@onready var _player_sprite: TextureRect = $Backdrop/PlayerSprite
@onready var _enemy_name: Label = $HUD/EnemyInfo/Margin/Name
@onready var _enemy_hp: Label = $HUD/EnemyInfo/Margin/HP
@onready var _player_name: Label = $HUD/PlayerInfo/Margin/Name
@onready var _player_hp: Label = $HUD/PlayerInfo/Margin/HP
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


func _ready() -> void:
	visible = false
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
	visible = true
	_apply_response(_runtime().call("start_wild_battle", wild_mon))


func run_smoke_turn() -> void:
	for button_index in range(4):
		var button = _move_button(button_index)
		if button != null and not button.disabled:
			_on_move_pressed(button_index)
			return
	_on_run_pressed()


func run_smoke_escape() -> void:
	_on_run_pressed()


func _on_fight_pressed() -> void:
	_show_move_menu()


func _on_bag_pressed() -> void:
	_show_bag_menu()


func _on_run_pressed() -> void:
	_apply_response(_runtime().call("run_from_battle"))


func _on_move_pressed(index: int) -> void:
	_apply_response(_runtime().call("perform_battle_move", index))


func _on_pokeball_pressed() -> void:
	_apply_response(_runtime().call("use_pokeball"))


func _on_potion_pressed() -> void:
	_apply_response(_runtime().call("use_potion"))


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


func _set_message(text: String) -> void:
	_message_label.text = text


func _apply_response(response: Dictionary) -> void:
	if response.is_empty():
		return
	var snapshot = response.get("snapshot", {})
	if snapshot is Dictionary:
		_apply_snapshot(snapshot)
	_set_message(str(response.get("message", "")))

	if bool(response.get("finished", false)):
		visible = false
		battle_finished.emit(str(response.get("outcome", "")), str(response.get("message", "")))
		return

	visible = bool(response.get("active", false))
	match str(response.get("menu", "action")):
		"moves":
			_show_move_menu()
		"bag":
			_show_bag_menu()
		_:
			_show_action_menu()


func _apply_snapshot(snapshot: Dictionary) -> void:
	var player_mon = snapshot.get("player_mon", {})
	var enemy_mon = snapshot.get("enemy_mon", {})
	var bag = snapshot.get("bag", {})

	_enemy_name.text = "%s Lv.%d" % [str(enemy_mon.get("name", "?")), int(enemy_mon.get("level", 1))]
	_enemy_hp.text = "HP %d/%d" % [int(enemy_mon.get("current_hp", 0)), int(enemy_mon.get("max_hp", 1))]
	_player_name.text = "%s Lv.%d" % [str(player_mon.get("name", "?")), int(player_mon.get("level", 1))]
	_player_hp.text = "HP %d/%d" % [int(player_mon.get("current_hp", 0)), int(player_mon.get("max_hp", 1))]
	_enemy_sprite.texture = _load_pokemon_frame(str(enemy_mon.get("front_path", "")))
	_player_sprite.texture = _load_pokemon_frame(str(player_mon.get("back_path", "")))
	_refresh_move_buttons(player_mon.get("moves", []))
	_refresh_bag_buttons(bag)


func _refresh_move_buttons(moves: Array) -> void:
	for i in range(4):
		var button = _move_button(i)
		if i < moves.size():
			var move = moves[i]
			var move_name = str(move.get("name", move.get("move_id", "Move")))
			var pp = int(move.get("pp", 0))
			var max_pp = int(move.get("max_pp", 0))
			button.text = "%s (%d/%d)" % [move_name, pp, max_pp]
			button.disabled = pp <= 0
		else:
			button.text = "-"
			button.disabled = true


func _refresh_bag_buttons(bag: Dictionary) -> void:
	var pokeballs = int(bag.get("pokeball", 0))
	var potions = int(bag.get("potion", 0))
	_pokeball_button.text = "Poke Ball x%d" % pokeballs
	_potion_button.text = "Potion x%d" % potions
	_pokeball_button.disabled = pokeballs <= 0
	_potion_button.disabled = potions <= 0


func _move_button(index: int) -> Button:
	match index:
		0:
			return _move_button_0
		1:
			return _move_button_1
		2:
			return _move_button_2
		3:
			return _move_button_3
		_:
			return null


func _load_pokemon_frame(path: String) -> Texture2D:
	var fallback_path = "res://pokewilds/pokemon/not_found.png"
	if path.is_empty() or not ResourceLoader.exists(path):
		return load(fallback_path)
	var texture = load(path)
	if texture == null or texture is not Texture2D:
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


func _runtime() -> Node:
	return get_node(RuntimePath)
