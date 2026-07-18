extends Control

signal battle_finished(outcome: String, message: String)

const RuntimePath := "/root/GameRuntime"
const AttackAnimator := preload("res://scripts/ui/attack_animator.gd")
const BattleTurnPlayer := preload("res://scripts/ui/battle_turn_player.gd")
const STAGE_SIZE := Vector2(160.0, 144.0)
const STAGE_PADDING := 16.0

@onready var _display: TextureRect = $BattleDisplay
@onready var _viewport: SubViewport = $BattleViewport
@onready var _surface = $BattleViewport/BattleStage

var _snapshot: Dictionary = {}
var _message := ""
var _menu_state := "action"
var _selection := ""
var _animator := AttackAnimator.new()
var _turn_player := BattleTurnPlayer.new()
var _animating := false

func _ready() -> void:
	visible = false
	_viewport.size = Vector2i(160, 144)
	_viewport.handle_input_locally = false
	_display.texture = _viewport.get_texture()
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_layout_display()
	_render()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_layout_display()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _animating:
		return
	if event.is_action_pressed("move_up"):
		_move_selection(Vector2i.UP)
	elif event.is_action_pressed("move_down"):
		_move_selection(Vector2i.DOWN)
	elif event.is_action_pressed("move_left"):
		_move_selection(Vector2i.LEFT)
	elif event.is_action_pressed("move_right"):
		_move_selection(Vector2i.RIGHT)
	elif event.is_action_pressed("action_a"):
		_activate_selection()
	elif event.is_action_pressed("action_b"):
		_cancel_selection()
	else:
		return
	get_viewport().set_input_as_handled()

func _gui_input(event: InputEvent) -> void:
	if not visible or _animating:
		return
	if event is not InputEventMouseButton:
		return
	var button_event: InputEventMouseButton = event
	if not button_event.pressed or button_event.button_index != MOUSE_BUTTON_LEFT:
		return
	var stage_point = _stage_point(button_event.position)
	if stage_point == null:
		return
	var option = _surface.option_from_point(_menu_state, _snapshot, stage_point)
	if option.is_empty():
		# Clicking outside any option backs out of a submenu (no BACK row on the moves screen).
		_cancel_selection()
		accept_event()
		return
	_selection = option
	_activate_selection()
	accept_event()

func start_wild_battle(wild_mon: Dictionary) -> void:
	visible = true
	_apply_response(_runtime().call("start_wild_battle", wild_mon))

func run_smoke_turn() -> void:
	if not visible:
		return
	_set_menu_state("action")
	_selection = "fight"
	_activate_selection()
	if visible:
		_activate_selection()

func run_smoke_escape() -> void:
	if not visible:
		return
	_set_menu_state("action")
	_selection = "run"
	_render()
	_activate_selection()

func _move_selection(direction: Vector2i) -> void:
	var next = _surface.next_selection(_menu_state, _snapshot, _selection, direction)
	if _menu_state == "moves" and (next.is_empty() or next == _selection) and direction.x != 0:
		var vertical_fallback = Vector2i.DOWN if direction.x > 0 else Vector2i.UP
		next = _surface.next_selection(_menu_state, _snapshot, _selection, vertical_fallback)
	if not next.is_empty() and next != _selection:
		_selection = next
		_render()

func _activate_selection() -> void:
	match _menu_state:
		"moves":
			_activate_move()
		"item":
			_activate_item()
		_:
			_activate_action()

func _activate_action() -> void:
	match _selection:
		"fight":
			_set_menu_state("moves")
		"item":
			_set_menu_state("item")
		"run":
			_apply_response(_runtime().call("run_from_battle"))

func _activate_move() -> void:
	if _selection == "back":
		_set_menu_state("action")
		return
	if not _selection.begins_with("move_"):
		return
	_apply_response(_runtime().call("perform_battle_move", int(_selection.trim_prefix("move_"))))

func _activate_item() -> void:
	match _selection:
		"poke_ball":
			_apply_response(_runtime().call("use_pokeball"))
		"potion":
			_apply_response(_runtime().call("use_potion"))
		"back":
			_set_menu_state("action")

func _cancel_selection() -> void:
	if _menu_state != "action":
		_set_menu_state("action")

func _apply_response(response: Dictionary) -> void:
	if response.is_empty():
		return
	var previous_snapshot := _snapshot
	var snapshot = response.get("snapshot", {})
	if snapshot is Dictionary:
		_snapshot = snapshot
	_message = str(response.get("message", ""))
	if bool(response.get("finished", false)):
		var finished_turns: Array = response.get("turns", [])
		if finished_turns.is_empty():
			_turn_player.generation += 1  # cancel any in-flight turn playback
			_set_animating(false)
			visible = false
			battle_finished.emit(str(response.get("outcome", "")), _message)
		else:
			_turn_player.play(self, finished_turns, previous_snapshot, response)
		return
	visible = bool(response.get("active", false))
	var turns: Array = response.get("turns", [])
	if turns.is_empty():
		_set_menu_state(str(response.get("menu", "action")))
		return
	var menu := str(response.get("menu", "action"))
	_menu_state = menu if menu in ["action", "moves", "item"] else "action"
	_selection = _surface.first_selectable(_menu_state, _snapshot)
	_turn_player.play(self, turns, previous_snapshot)


func is_animating() -> bool: return _animating


func _set_animating(value: bool) -> void:
	_animating = value

func _set_menu_state(menu_state: String) -> void:
	_menu_state = menu_state if menu_state in ["action", "moves", "item"] else "action"
	_selection = _surface.first_selectable(_menu_state, _snapshot)
	_render()

func _render() -> void:
	_surface.render(_snapshot, _menu_state, _selection, _message)

func _layout_display() -> void:
	var viewport_size = get_viewport_rect().size
	var available = viewport_size - Vector2.ONE * STAGE_PADDING * 2.0
	var scale_factor = min(available.x / STAGE_SIZE.x, available.y / STAGE_SIZE.y)
	# Integer-snap when the stage fits: fractional scales alias the pixel font.
	scale_factor = maxf(floorf(scale_factor), 1.0) if scale_factor >= 1.0 else maxf(scale_factor, 0.1)
	var scaled_size = STAGE_SIZE * scale_factor
	_display.size = scaled_size
	_display.position = ((viewport_size - scaled_size) * 0.5).floor()

func _stage_point(screen_point: Vector2):
	var display_rect = Rect2(_display.position, _display.size)
	if not display_rect.has_point(screen_point):
		return null
	var local_point = screen_point - display_rect.position
	return Vector2(
		STAGE_SIZE.x * (local_point.x / maxf(display_rect.size.x, 1.0)),
		STAGE_SIZE.y * (local_point.y / maxf(display_rect.size.y, 1.0))
	)

func _runtime() -> Node:
	return get_node(RuntimePath)
