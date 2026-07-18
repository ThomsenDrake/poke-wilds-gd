extends Control

const BattleSurfaceLayout := preload("res://scripts/ui/battle_surface_layout.gd")
const ACTION_BG_PATH := "res://pokewilds/battle/battle_screen2.png"
const MOVE_BG_PATH := "res://pokewilds/menu/attack_screen1.png"
const BLANK_BG_PATH := "res://pokewilds/battle/battle_bg1.png"
const ARROW_PATH := "res://pokewilds/battle/arrow_right1.png"
const BATTLE_FONT_PATH := "res://pokewilds/fonts.ttf"
const BATTLE_FONT_SIZE := 7
const ENEMY_HP_BAR_WIDTH := 48.0
const PLAYER_HP_BAR_WIDTH := 48.0

@onready var _background: TextureRect = $BattleBackground
@onready var _overlay: TextureRect = $BattleOverlay
@onready var _enemy_sprite: TextureRect = $EnemySprite
@onready var _player_sprite: TextureRect = $PlayerSprite
@onready var _enemy_name: Label = $EnemyName
@onready var _enemy_level: Label = $EnemyLevel
@onready var _enemy_hp_fill: ColorRect = $EnemyHPBar/Fill
@onready var _player_name: Label = $PlayerHUD/PlayerName
@onready var _player_level: Label = $PlayerHUD/PlayerLevel
@onready var _player_hp_fill: ColorRect = $PlayerHUD/PlayerHPBar/Fill
@onready var _player_hp: Label = $PlayerHUD/PlayerHP
@onready var _player_hud: Control = $PlayerHUD
@onready var _message_label: Label = $MessageLabel
@onready var _move_type_value: Label = $MoveTypeValue
@onready var _move_pp_current: Label = $MovePPCurrent
@onready var _move_pp_max: Label = $MovePPMax
@onready var _cursor: TextureRect = $Cursor
@onready var _menu_labels := [$MenuLabel0, $MenuLabel1, $MenuLabel2, $MenuLabel3, $MenuLabel4]

var _action_bg: Texture2D
var _move_bg: Texture2D
var _blank_bg: Texture2D
var _action_labels: Dictionary = {}
var _enemy_status: Label
var _player_status: Label
var _glyph_covers: Control
var _layout := BattleSurfaceLayout.new()
var _battle_font: Font

func _ready() -> void:
	_action_bg = _build_stage_texture(ACTION_BG_PATH)
	_move_bg = _build_stage_texture(MOVE_BG_PATH)
	_blank_bg = _build_stage_texture(BLANK_BG_PATH)
	_battle_font = load(BATTLE_FONT_PATH)
	_action_labels = {
		"fight": $FightLabel,
		"pkmn": $PkmnLabel,
		"item": $ItemLabel,
		"run": $RunLabel,
	}
	_enemy_status = _layout.build_status_label(true)
	_player_status = _layout.build_status_label(false)
	add_child(_enemy_status)
	add_child(_player_status)
	_glyph_covers = _layout.build_glyph_covers()
	add_child(_glyph_covers)
	move_child(_glyph_covers, 2)
	_cursor.texture = load(ARROW_PATH)
	for node in [_background, _overlay, _enemy_sprite, _player_sprite, _cursor]:
		node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_configure_theme()
	_show_move_info(false)

func render(snapshot: Dictionary, menu_state: String, selection: String, message: String) -> void:
	_apply_snapshot(snapshot)
	_background.texture = _blank_bg
	_overlay.texture = _overlay_for(menu_state)
	_message_label.visible = menu_state == "action"
	_message_label.text = message
	_player_sprite.visible = menu_state != "moves"
	# Player HUD plate stays up in moves mode; name/level would clip under the side box.
	_player_hud.visible = true
	_player_name.visible = menu_state != "moves"
	_player_level.visible = menu_state != "moves"
	_glyph_covers.modulate = Color(0.973, 0.973, 0.973) if menu_state == "action" else Color(1.0, 0.996, 1.0)
	var model = _layout.model(menu_state, snapshot)
	match menu_state:
		"moves":
			_render_moves(model, selection)
		"item":
			_render_menu(model, selection)
		_:
			_render_actions(model, selection)

func first_selectable(menu_state: String, snapshot: Dictionary) -> String:
	return _layout.first_selectable(menu_state, snapshot)

func next_selection(menu_state: String, snapshot: Dictionary, current: String, direction: Vector2i) -> String:
	return _layout.next_selection(menu_state, snapshot, current, direction)

func option_from_point(menu_state: String, snapshot: Dictionary, point: Vector2) -> String:
	return _layout.option_from_point(menu_state, snapshot, point)

# Actor/layer handles for AttackAnimator playback: combatant sprites plus the
# HUD groups the source metadata hides per frame (*_gone/hide tokens).
func anim_actors() -> Dictionary:
	return {
		"player": _player_sprite,
		"enemy": _enemy_sprite,
		"layers": {
			"player_healthbar": [_player_hud, _player_status],
			"enemy_healthbar": [get_node("EnemyHPBar"), _enemy_name, _enemy_level, _enemy_status],
			"player_sprite": [_player_sprite],
			"enemy_sprite": [_enemy_sprite],
		},
	}

func _overlay_for(menu_state: String) -> Texture2D:
	var key := _layout.overlay_key(menu_state)
	return _action_bg if key == "action" else _move_bg if key == "moves" else null
func _render_actions(model: Array, selection: String) -> void:
	_show_move_info(false)
	_hide_menu_labels()
	_hide_action_labels()
	_place_cursor(_find_option(model, selection))

func _render_moves(model: Array, selection: String) -> void:
	_hide_action_labels()
	_render_menu_labels(model)
	var selected = _find_option(model, selection)
	_place_cursor(selected)
	_show_move_info(true, selected)

func _render_menu(model: Array, selection: String) -> void:
	_show_move_info(false)
	_hide_action_labels()
	_render_menu_labels(model)
	_place_cursor(_find_option(model, selection))

func _render_menu_labels(model: Array) -> void:
	for i in range(_menu_labels.size()):
		var label: Label = _menu_labels[i]
		if i >= model.size():
			label.visible = false
			continue
		var option = model[i]
		label.visible = true
		label.position = option.get("label_pos", Vector2.ZERO)
		label.size = option.get("label_size", label.size)
		label.text = str(option.get("text", ""))
		_set_label_state(label, bool(option.get("enabled", false)))

func _hide_menu_labels() -> void:
	for label in _menu_labels:
		label.visible = false

func _hide_action_labels() -> void:
	for label in _action_labels.values():
		label.visible = false

func _place_cursor(option: Dictionary) -> void:
	_cursor.visible = not option.is_empty()
	if not option.is_empty():
		_cursor.position = option.get("cursor_pos", Vector2.ZERO)

func _find_option(model: Array, option_id: String) -> Dictionary:
	return _layout.find_option(model, option_id)
func _apply_snapshot(snapshot: Dictionary) -> void:
	var player_mon: Dictionary = snapshot.get("player_mon", {})
	var enemy_mon: Dictionary = snapshot.get("enemy_mon", {})
	_enemy_name.text = _layout.hud_name(_battle_font, BATTLE_FONT_SIZE, str(enemy_mon.get("name", "?")), _enemy_name.size.x)
	_enemy_level.text = ":L " + str(int(enemy_mon.get("level", 1)))
	_player_name.text = _layout.hud_name(_battle_font, BATTLE_FONT_SIZE, str(player_mon.get("name", "?")), _player_name.size.x)
	_player_level.text = ":L " + str(int(player_mon.get("level", 1)))
	_enemy_status.text = str(enemy_mon.get("status", ""))
	_player_status.text = str(player_mon.get("status", ""))
	_layout.place_hud_levels(_enemy_name, _enemy_level, _player_name, _player_level, _enemy_status, _player_status)
	_player_hp.text = "%d/%d" % [int(player_mon.get("current_hp", 0)), int(player_mon.get("max_hp", 1))]
	_set_hp_bar(_enemy_hp_fill, enemy_mon, ENEMY_HP_BAR_WIDTH)
	_set_hp_bar(_player_hp_fill, player_mon, PLAYER_HP_BAR_WIDTH)
	_enemy_sprite.texture = _layout.pokemon_frame(str(enemy_mon.get("front_path", "")))
	_player_sprite.texture = _layout.pokemon_frame(str(player_mon.get("back_path", "")))

func _set_hp_bar(fill: ColorRect, mon: Dictionary, width: float) -> void:
	var max_hp = max(1, int(mon.get("max_hp", 1)))
	var ratio = clampf(float(int(mon.get("current_hp", 0))) / float(max_hp), 0.0, 1.0)
	fill.size.x = 0.0 if ratio <= 0.0 else maxf(1.0, floorf(width * ratio))
	fill.color = Color(0.227, 0.651, 0.247) if ratio > 0.5 else Color(0.929, 0.733, 0.118) if ratio > 0.2 else Color(0.816, 0.239, 0.204)

func _set_label_state(label: Label, enabled: bool) -> void:
	label.add_theme_color_override("font_color", Color.BLACK if enabled else Color(0.45, 0.45, 0.45))

func _show_move_info(visible: bool, option: Dictionary = {}) -> void:
	for label in [_move_type_value, _move_pp_current, _move_pp_max]:
		label.visible = visible
	var move_data = _layout.move_info(option) if visible else {}
	_move_type_value.text = str(move_data.get("type", "")).to_upper()
	_move_pp_current.text = str(move_data.get("pp", ""))
	_move_pp_max.text = str(move_data.get("max_pp", move_data.get("pp", "")))
	# A type name wider than the after-"TYPE/" space in the side box (35px at
	# the battle font, e.g. FIGHTING) drops to the box's empty second row
	# instead of bleeding over the box border.
	var type_width := _battle_font.get_string_size(_move_type_value.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BATTLE_FONT_SIZE).x
	_move_type_value.position = Vector2(46, 71) if type_width <= 35.0 else Vector2(8, 80)

func _build_stage_texture(path: String) -> Texture2D:
	var texture = load(path)
	if texture == null or texture is not Texture2D:
		return null
	var tex2d: Texture2D = texture
	if tex2d.get_width() == 160 and tex2d.get_height() == 144:
		return tex2d
	var frame = AtlasTexture.new()
	frame.atlas = tex2d
	frame.region = Rect2(0, 0, 160, 144)
	return frame

func _configure_theme() -> void:
	for label in [_enemy_name, _enemy_level, _player_name, _player_level, _player_hp,
			_message_label, _move_type_value, _move_pp_current, _move_pp_max, _enemy_status, _player_status]:
		_apply_battle_font(label)
	for label in _action_labels.values():
		_apply_battle_font(label)
	for label in _menu_labels:
		_apply_battle_font(label)

func _apply_battle_font(label: Label) -> void: label.add_theme_font_override("font", _battle_font); label.add_theme_font_size_override("font_size", BATTLE_FONT_SIZE); label.add_theme_color_override("font_color", Color.BLACK)
