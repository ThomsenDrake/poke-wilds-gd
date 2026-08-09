extends Control

# New-game creation flow (title-flow slice; spec: docs/product-specs/bootstrap-and-overworld.md),
# rebuilt on the GBC stage idiom (restyle slice wave 0): a native 160x144 stage
# (scripts/ui/gbc_stage.gd, the BattleView idiom) with the step dialog inside
# menu/frame1.png and the hint in the textbox_bg1.png bottom band. Five steps in
# the faithful i18n order (strings.properties: shiny_rate, name, player, go):
# SEED -> SHINY RATE -> NAME -> AVATAR -> GO!. The SECOND SeedPrompt
# instantiation is GONE: the SEED step carries an in-stage gbc_digit_row — L/R
# toggles edit mode; while editing, typed digits/Backspace/arrows behave exactly
# like SeedPrompt (unicode 48-57, MAX_SEED cap); Z commits, X leaves edit (seed
# kept). NAME/AVATAR open their gbc stage widgets (NameEntry/AvatarPicker,
# parented INTO the stage) once per step visit; after a confirm the next Z
# advances. GO shows the summary, then the faithful "Generating... please wait..."
# beat (0.6s GenTimer — FLAGGED: string faithful, wait invented) before
# creation_confirmed. X on SEED cancels the whole flow back to the title screen.
# closed (argless) is emitted on EVERY hide — the input-router latch contract;
# main.gd binds this screen into bind_ui_consumers. Input stays on the screen
# ROOT (battle idiom): overlays receive delegated handle_input() calls.

const SessionState := preload("res://scripts/runtime/session_state.gd")
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcDigitRow := preload("res://scripts/ui/gbc_digit_row.gd")
const NameEntry := preload("res://scripts/ui/name_entry.gd")
const AvatarPicker := preload("res://scripts/ui/avatar_picker.gd")
const CreationStage := preload("res://scripts/ui/creation_screen_stage.gd")
const CreationRender := preload("res://scripts/ui/creation_screen_render.gd")

signal creation_confirmed(creation: Dictionary)
signal cancelled # X on the SEED step: back to the title screen
signal closed # argless, on EVERY hide — the latch contract (input_router bind_ui_consumers)

const STEP_SEED := 0
const STEP_SHINY := 1
const STEP_NAME := 2
const STEP_AVATAR := 3
const STEP_GO := 4
const GENERATING_TEXT := "Generating... please wait..." # i18n generating_please_wait, verbatim (FLAGGED: hardcoded)

@onready var _gen_timer: Timer = $GenTimer

var _stage: Control
var _title_label: Label # step title inside the frame1 interior
var _value_label: Label # step value inside the frame1 interior (autowrap)
var _hint_label: Label # hint inside the textbox_bg1 bottom band
var _digit_row = GbcDigitRow.new() # the in-stage seed digit row (replaces SeedPrompt #2)
var _name_entry: Control # the gbc name-grid widget (stage child)
var _avatar_picker: Control # the gbc avatar-grid widget (stage child)
var _runtime: Node = null
var _step := STEP_SEED
var _seed := -1 # RANDOM default: the runtime's world-seed draw stays in charge (-1 contract)
var _shiny_index := 3 # SessionState.SHINY_ODDS_CHOICES index of the 256 default
var _name := "" # empty until edited; the commit payload falls back to DEFAULT_PLAYER_NAME
var _avatar := SessionState.DEFAULT_PLAYER_AVATAR
var _overlay_done := false # this visit's overlay confirmed — the step's Z advances
var _generating := false

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self)
	GbcStage.on_resized(self, parts.display)
	_stage = parts.stage
	_gen_timer.timeout.connect(_on_gen_timer_timeout)
	var labels := CreationStage.build(_stage) # {title_label, value_label, hint_label}
	_title_label = labels.title_label
	_value_label = labels.value_label
	_hint_label = labels.hint_label
	_name_entry = NameEntry.new(); _stage.add_child(_name_entry)
	_avatar_picker = AvatarPicker.new(); _stage.add_child(_avatar_picker)
	_name_entry.name_confirmed.connect(_on_name_confirmed)
	_name_entry.cancelled.connect(_render) # just closes; the step keeps its typed name
	_avatar_picker.avatar_confirmed.connect(_on_avatar_confirmed)
	_avatar_picker.cancelled.connect(_render)

# The creation choices persist across re-opens within a session (encounter_settings
# precedent), so open resets ONLY the step/labels, not seed/shiny/name/avatar.
func open_screen() -> void:
	_runtime = get_node_or_null("/root/GameRuntime") # self-wire (options_screen precedent)
	_generating = false
	_step = STEP_SEED
	_digit_row.stop_edit()
	_enter_step()
	visible = true

func close_screen() -> void:
	if not visible:
		return
	_gen_timer.stop()
	_generating = false
	_digit_row.stop_edit()
	_name_entry.close_entry()
	_avatar_picker.close_picker()
	visible = false
	closed.emit()

# Scenario seams (restyle design §2.2; the old Panel/Margin/VBox node reads).
func step_title_label() -> Label: return _title_label
func step_value_label() -> Label: return _value_label
func seed_edit_active() -> bool: return _step == STEP_SEED and _digit_row.editing_active() # the old SeedPrompt-visible witness

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _generating: # input locked for the generating beat
		return
	if _name_entry.visible: # a visible overlay owns the input; the root delegates
		if _name_entry.handle_input(event):
			get_viewport().set_input_as_handled()
		return
	if _avatar_picker.visible:
		if _avatar_picker.handle_input(event):
			get_viewport().set_input_as_handled()
		return
	if _step == STEP_SEED and _digit_row.editing_active():
		_handle_seed_edit(event)
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

func _handle_seed_edit(event: InputEvent) -> void:
	if event.is_action_pressed("action_a"):
		_seed = _digit_row.seed() # Z commits the typed seed into the step (edit off)
		_digit_row.stop_edit()
	elif event.is_action_pressed("action_b"):
		_digit_row.stop_edit() # X leaves edit; the step keeps its RANDOM/typed seed
	elif _digit_row.handle(event):
		pass # arrows/typed digits/Backspace: SeedPrompt semantics, verbatim in the widget
	else:
		return # Enter and friends stay unhandled (the menu toggle keeps working)
	_render()
	get_viewport().set_input_as_handled()

func _sideways(direction: int) -> void:
	match _step:
		STEP_SEED:
			_digit_row.start_edit() # L/R toggles the in-stage digit row's edit mode
			_render()
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
			else:
				_name_entry.open_entry()
				_hint_label.visible = false # the overlay plate IS the screen now
		STEP_AVATAR:
			if _overlay_done: _advance()
			else:
				_avatar_picker.open_picker()
				_hint_label.visible = false
		_:
			_advance() # SEED (not editing — gated above) and SHINY

func _begin() -> void:
	_generating = true # input locked for the beat; the timer releases it with the confirm
	_value_label.text = GENERATING_TEXT
	call_deferred("_center_block_deferred")
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
	return _name_entry.visible or _avatar_picker.visible

func _committed_name() -> String:
	return SessionState.DEFAULT_PLAYER_NAME if _name.is_empty() else _name

func _seed_line() -> String:
	return "RANDOM" if _seed < 0 else str(_seed)

# Step strings live in creation_screen_render.gd (the 220-wall extraction);
# they are the SAME pinned strings as the pre-restyle screen (design §2.2).
func _render() -> void:
	CreationRender.render(self)
	call_deferred("_center_block_deferred") # get_line_count needs a layout pass first

func _center_block_deferred() -> void:
	if visible:
		CreationRender.center_block(self)
