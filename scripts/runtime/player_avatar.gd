extends Node2D

signal tile_changed(tile_position: Vector2i)
signal encounter_requested(tile_position: Vector2i)
signal blocked(step_direction: Vector2i)

const TILE_SIZE := 16
const ACTION_MOVE_UP := "move_up"
const ACTION_MOVE_DOWN := "move_down"
const ACTION_MOVE_LEFT := "move_left"
const ACTION_MOVE_RIGHT := "move_right"
const ACTION_RUN := "run"

@export var start_tile = Vector2i(0, 0)
@export var walk_step_seconds = 0.16
@export var run_step_seconds = 0.09
@export var encounter_chance = 0.12
@export var run_encounter_modifier = 0.65

@onready var _sprite: AnimatedSprite2D = $AnimatedSprite2D

var world = null
var tile_position = Vector2i.ZERO
var input_enabled = true

var _moving = false
var _move_running = false
var _move_elapsed = 0.0
var _move_duration = 0.16
var _move_from = Vector2.ZERO
var _move_to = Vector2.ZERO
var _target_tile = Vector2i.ZERO
var _facing = Vector2i.DOWN
var _rng = RandomNumberGenerator.new()


func _ready() -> void:
	_setup_sprite_frames()
	_rng.randomize()
	tile_position = start_tile
	position = Vector2(tile_position.x * TILE_SIZE, tile_position.y * TILE_SIZE)
	_set_sprite_state(_facing, false)


func setup(world_renderer) -> void:
	world = world_renderer
	position = world.map_to_world(tile_position)


func set_tile_position(new_tile_position: Vector2i) -> void:
	tile_position = new_tile_position
	if world == null:
		position = Vector2(tile_position.x * TILE_SIZE, tile_position.y * TILE_SIZE)
	else:
		position = world.map_to_world(tile_position)


func smoke_step(step_direction: Vector2i) -> bool:
	if world == null or _moving:
		return false
	_try_start_step(step_direction)
	return _moving


func _process(delta: float) -> void:
	if not input_enabled:
		_set_sprite_state(_facing, false)
		return
	if world == null:
		return
	if _moving:
		_update_movement(delta)
		return
	_try_start_step(_read_step_direction())


func _read_step_direction() -> Vector2i:
	var x = 0
	var y = 0
	if Input.is_action_pressed(ACTION_MOVE_LEFT):
		x -= 1
	if Input.is_action_pressed(ACTION_MOVE_RIGHT):
		x += 1
	if Input.is_action_pressed(ACTION_MOVE_UP):
		y -= 1
	if Input.is_action_pressed(ACTION_MOVE_DOWN):
		y += 1
	if x != 0 and y != 0:
		y = 0
	return Vector2i(x, y)


func _try_start_step(step_direction: Vector2i) -> void:
	if step_direction == Vector2i.ZERO:
		_set_sprite_state(_facing, false)
		return

	_facing = step_direction
	var next_tile = tile_position + step_direction
	if not world.is_tile_walkable(next_tile):
		blocked.emit(step_direction)
		_set_sprite_state(_facing, false)
		return

	_move_running = Input.is_action_pressed(ACTION_RUN)
	_move_duration = run_step_seconds if _move_running else walk_step_seconds
	_move_elapsed = 0.0
	_move_from = position
	_move_to = world.map_to_world(next_tile)
	_target_tile = next_tile
	_moving = true
	_set_sprite_state(_facing, true)


func _update_movement(delta: float) -> void:
	_move_elapsed += delta
	var t: float = minf(_move_elapsed / _move_duration, 1.0)
	position = _move_from.lerp(_move_to, t)
	if t < 1.0:
		return

	position = _move_to
	tile_position = _target_tile
	_moving = false
	_set_sprite_state(_facing, false)
	tile_changed.emit(tile_position)
	_try_trigger_encounter()


func _try_trigger_encounter() -> void:
	if not world.is_encounter_tile(tile_position):
		return
	var trigger_chance = encounter_chance
	if _move_running:
		trigger_chance *= run_encounter_modifier
	if _rng.randf() <= trigger_chance:
		encounter_requested.emit(tile_position)


func _set_sprite_state(direction: Vector2i, moving: bool) -> void:
	var animation_name = _direction_to_animation(direction)
	if _sprite.animation != animation_name:
		_sprite.animation = animation_name
	if moving:
		_sprite.speed_scale = 1.8 if _move_running else 1.0
		_sprite.play(animation_name)
	else:
		_sprite.stop()
		_sprite.frame = 0


func _direction_to_animation(direction: Vector2i) -> StringName:
	if direction == Vector2i.UP:
		return &"up"
	if direction == Vector2i.LEFT:
		return &"left"
	if direction == Vector2i.RIGHT:
		return &"right"
	return &"down"


func _setup_sprite_frames() -> void:
	var sheet: Texture2D = load("res://pokewilds/player/kris-walking.png")
	var frames = SpriteFrames.new()
	var frame_map = {
		"down": [0, 4],
		"up": [1, 5],
		"left": [2, 3],
		"right": [6, 7]
	}

	for animation_name in frame_map.keys():
		frames.add_animation(animation_name)
		frames.set_animation_speed(animation_name, 8.0)
		frames.set_animation_loop(animation_name, true)
		for frame_index in frame_map[animation_name]:
			var frame = AtlasTexture.new()
			frame.atlas = sheet
			frame.region = Rect2(frame_index * TILE_SIZE, 0, TILE_SIZE, TILE_SIZE)
			frames.add_frame(animation_name, frame)

	_sprite.sprite_frames = frames
