extends Control

# New-game creation flow (title-flow slice; spec: docs/product-specs/bootstrap-and-overworld.md).
# Five steps in the faithful i18n order (strings.properties: shiny_rate, name, player, go):
# SEED -> SHINY RATE -> NAME -> AVATAR -> GO!. Hosts three sceneless overlays built in
# _ready — a SECOND SeedPrompt instantiation (seed_prompt.gd UNCHANGED; start_menu keeps its
# own instance), NameEntry (grid keyboard) and AvatarPicker (24-set grid) — drawn OVER the
# panel. <-/-> edits the current step (SEED opens the prompt, SHINY cycles the odds ladder),
# Z activates/advances, X backs up one step; X on SEED cancels the whole flow back to the
# title screen. NAME/AVATAR open their overlay ONCE per step visit (cancelled keeps it
# re-openable); after a confirm the next Z advances. GO shows the summary, then the faithful
# "Generating... please wait..." beat (0.6s GenTimer — FLAGGED: string faithful, wait invented)
# before creation_confirmed. closed (argless) is emitted on EVERY hide — the input-router
# latch contract; main.gd binds this screen into bind_ui_consumers.

const SessionState := preload("res://scripts/runtime/session_state.gd")
const SeedPrompt := preload("res://scripts/ui/seed_prompt.gd")
const NameEntry := preload("res://scripts/ui/name_entry.gd")
const AvatarPicker := preload("res://scripts/ui/avatar_picker.gd")

signal creation_confirmed(creation: Dictionary)
signal cancelled # X on the SEED step: back to the title screen
signal closed # argless, on EVERY hide — the latch contract (input_router bind_ui_consumers)

const STEP_SEED := 0
const STEP_SHINY := 1
const STEP_NAME := 2
const STEP_AVATAR := 3
const STEP_GO := 4
const GENERATING_TEXT := "Generating... please wait..." # i18n generating_please_wait, verbatim (FLAGGED: hardcoded)

@onready var _title: Label = $Panel/Margin/VBox/Title
@onready var _value: Label = $Panel/Margin/VBox/Value
@onready var _hint: Label = $Panel/Margin/VBox/Hint
@onready var _gen_timer: Timer = $GenTimer

var _runtime: Node = null
var _seed_prompt: Control
var _name_entry: Control
var _avatar_picker: Control
var _step := STEP_SEED
var _seed := -1 # RANDOM default: the runtime's world-seed draw stays in charge (-1 contract)
var _shiny_index := 3 # SessionState.SHINY_ODDS_CHOICES index of the 256 default
var _name := "" # empty until edited; the commit payload falls back to DEFAULT_PLAYER_NAME
var _avatar := SessionState.DEFAULT_PLAYER_AVATAR
var _overlay_done := false # this visit's overlay confirmed — the step's Z advances
var _generating := false

func _ready() -> void:
	visible = false
	_gen_timer.timeout.connect(_on_gen_timer_timeout)
	_seed_prompt = SeedPrompt.new(); add_child(_seed_prompt) # sceneless children, built + wired here (start_menu precedent)
	_name_entry = NameEntry.new(); add_child(_name_entry)
	_avatar_picker = AvatarPicker.new(); add_child(_avatar_picker)
	_seed_prompt.seed_confirmed.connect(_on_seed_confirmed)
	_seed_prompt.cancelled.connect(_render) # just closes; the step keeps its RANDOM/typed seed
	_name_entry.name_confirmed.connect(_on_name_confirmed)
	_name_entry.cancelled.connect(_render)
	_avatar_picker.avatar_confirmed.connect(_on_avatar_confirmed)
	_avatar_picker.cancelled.connect(_render)

# The creation choices persist across re-opens within a session (encounter_settings
# precedent), so open resets ONLY the step/labels, not seed/shiny/name/avatar.
func open_screen() -> void:
	_runtime = get_node_or_null("/root/GameRuntime") # self-wire (options_screen precedent)
	_generating = false
	_step = STEP_SEED
	_enter_step()
	visible = true

func close_screen() -> void:
	if not visible:
		return
	_gen_timer.stop()
	_generating = false
	_seed_prompt.close_prompt()
	_name_entry.close_entry()
	_avatar_picker.close_picker()
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _generating or _overlay_open(): # a visible overlay owns the input
		return
	if event.is_action_pressed("action_b"):
		if _step == STEP_SEED:
			visible = false
			closed.emit()
			cancelled.emit()
		else:
			_step -= 1
			_enter_step()
	elif event.is_action_pressed("action_a"):
		_activate()
	elif event.is_action_pressed("move_left"):
		_sideways(-1)
	elif event.is_action_pressed("move_right"):
		_sideways(1)
	else:
		return
	get_viewport().set_input_as_handled()

func _sideways(direction: int) -> void:
	match _step:
		STEP_SEED:
			_seed_prompt.open_prompt() # <-/-> is the custom-seed gesture (seed_prompt precedent)
		STEP_SHINY:
			_shiny_index = wrapi(_shiny_index + direction, 0, SessionState.SHINY_ODDS_CHOICES.size())
			_render()
		# NAME/AVATAR are edited through their overlays; GO has nothing to nudge.

func _activate() -> void:
	match _step:
		STEP_GO:
			_begin()
		STEP_NAME:
			if _overlay_done: _advance()
			else: _name_entry.open_entry()
		STEP_AVATAR:
			if _overlay_done: _advance()
			else: _avatar_picker.open_picker()
		_:
			_advance() # SEED (prompt closed — gated above) and SHINY

func _begin() -> void:
	_generating = true # input locked for the beat; the timer releases it with the confirm
	_value.text = GENERATING_TEXT
	_gen_timer.start(0.6) # FLAGGED beat: world gen is instant; the duration is invented theater

func _on_gen_timer_timeout() -> void:
	if not visible or not _generating: # close_screen stopped the timer mid-beat
		return
	var creation := {"player_name": _committed_name(), "player_avatar": _avatar,
		"shiny_odds": int(SessionState.SHINY_ODDS_CHOICES[_shiny_index]), "world_seed": _seed}
	if _runtime != null:
		_runtime.emit_trace("creation_confirmed", "CreationScreen", creation) # frozen contract, same moment as the signal
	creation_confirmed.emit(creation)
	_generating = false
	visible = false
	closed.emit()

func _on_seed_confirmed(seed_value: int) -> void:
	_seed = seed_value
	_render()

func _on_name_confirmed(text: String) -> void:
	_name = text
	_overlay_done = true # the next Z advances (an empty confirm keeps the payload fallback live)
	_render()

func _on_avatar_confirmed(avatar_name: String) -> void:
	_avatar = avatar_name
	_overlay_done = true
	_render()

func _enter_step() -> void:
	_overlay_done = false
	_render()

func _advance() -> void:
	_step += 1
	_enter_step()

func _overlay_open() -> bool:
	return _seed_prompt.visible or _name_entry.visible or _avatar_picker.visible

func _committed_name() -> String:
	return SessionState.DEFAULT_PLAYER_NAME if _name.is_empty() else _name

func _seed_line() -> String:
	return "RANDOM" if _seed < 0 else str(_seed)

func _render() -> void:
	match _step:
		STEP_SEED:
			_title.text = "WORLD SEED"
			_value.text = _seed_line()
			_hint.text = "(←/→: enter a custom seed   Z: next)"
		STEP_SHINY:
			var odds := int(SessionState.SHINY_ODDS_CHOICES[_shiny_index])
			_title.text = "SHINY RATE"
			_value.text = "1/%d (DEFAULT)" % odds if odds == SessionState.SHINY_ODDS_DEFAULT else "1/%d" % odds
			_hint.text = "(←/→: change  Z: next)"
		STEP_NAME:
			_title.text = "NAME"
			_value.text = _name if not _name.is_empty() else "(none — Z to enter)"
			_hint.text = "(Z: enter name   X: back)"
		STEP_AVATAR:
			_title.text = "PLAYER"
			_value.text = _avatar
			_hint.text = "(Z: choose avatar   X: back)"
		STEP_GO:
			_title.text = "Go!" # i18n go, verbatim (FLAGGED: hardcoded)
			_value.text = "NAME — %s\nPLAYER — %s\nSHINY RATE — 1/%d\nWORLD SEED — %s" % [_committed_name(), _avatar, int(SessionState.SHINY_ODDS_CHOICES[_shiny_index]), _seed_line()]
			_hint.text = "(Z: begin   X: back)"
