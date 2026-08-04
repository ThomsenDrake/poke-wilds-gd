extends Control

# Startup splash + title menu as PHASES of one scene (title_flow slice; spec:
# docs/product-specs/bootstrap-and-overworld.md). PHASE SPLASH: a black card
# ("POKÉWILDS" + credit line — FLAGGED invention text; the strings are pinned)
# shown for 2.0s or until ANY action press skips it; PHASE TITLE: the
# title_bg1 art + the CONTINUE/NEW GAME entry list (CONTINUE only when a save
# loaded). main.gd calls begin_boot() on PLAYER boots only — scenario boots
# bypass this screen entirely.
#
# Traces ride the runtime's emit_trace seam, self-wired through
# /root/GameRuntime (the options_screen/storage_screen precedent); the names
# and payloads are a FROZEN contract with the new_game_flow gate scenario:
# splash_shown, splash_closed{reason: key|timeout}, title_shown{has_save,
# entries} (re-emitted on back-from-creation), title_continued{party_size},
# title_new_game_chosen.
#
# LATCH CONTRACT: `closed` is ARGLESS and emits on EVERY hide — main.gd binds
# it into input_router.bind_ui_consumers so the press that left the screen
# cannot re-fire poll_menu_toggle/poll_context_action the same frame.
#
# The save-wipe confirm reuses the MessageBox SIBLING (both screens are $UI
# children — Main.tscn wiring guarantees it; start_menu precedent). MessageBox
# confirmed/cancelled are SHARED with StartMenu + StorageScreen, so the
# handlers gate on _awaiting_confirm before acting (start_menu :165 precedent).

signal continue_chosen
signal new_game_chosen
signal closed # argless latch — emits on EVERY hide (the bind_ui_consumers contract)

const ENTRY_CONTINUE := "CONTINUE"
const ENTRY_NEW_GAME := "NEW GAME"
const CONFIRM_TEXT := "Start a new game? Your current save will be erased."
const SPLASH_SKIP_ACTIONS: PackedStringArray = ["move_up", "move_down", "move_left", "move_right", "action_a", "action_b", "start"]

@onready var _art: TextureRect = $Art
@onready var _splash: ColorRect = $Splash
@onready var _entry_panel: PanelContainer = $EntryPanel
@onready var _entries: ItemList = $EntryPanel/Entries
@onready var _splash_timer: Timer = $SplashTimer

var _has_save := false
var _in_splash := false
var _awaiting_confirm := false

func _ready() -> void:
	visible = false
	_splash_timer.timeout.connect(_on_splash_timeout)
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box != null and confirm_box.has_signal("confirmed"):
		confirm_box.connect("confirmed", _on_new_game_confirmed)
		confirm_box.connect("cancelled", _on_new_game_cancelled)

# Player-boot entrypoint (main.gd after ensure_initialized(false)): the splash
# card comes up and the 2.0s timer starts; any action press skips to the title.
func begin_boot(has_save: bool) -> void:
	_has_save = has_save
	_in_splash = true
	_awaiting_confirm = false
	_art.visible = false
	_entry_panel.visible = false
	_splash.visible = true
	visible = true
	_splash_timer.start()
	_trace("splash_shown", {})

# Title phase; also the back-from-creation-cancel path (title_shown re-emits).
func show_title() -> void:
	_in_splash = false
	_splash.visible = false
	_art.visible = true
	_rebuild_entries()
	_entry_panel.visible = true
	visible = true
	_trace("title_shown", {"has_save": _has_save, "entries": _entry_labels()})

# Every exit path hides through here: visible=false FIRST, then the latch.
func hide_screen() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _in_splash: # the splash phase flag gates the skip so title-phase input is never eaten
		if _is_any_action_pressed(event):
			_finish_splash("key")
			get_viewport().set_input_as_handled()
		return
	if _awaiting_confirm: # the MessageBox sibling owns Z/X while the save-wipe confirm is open
		return
	if event.is_action_pressed("move_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
	elif event.is_action_pressed("action_a"):
		_activate_selected()
	else:
		return
	get_viewport().set_input_as_handled()

func _finish_splash(reason: String) -> void:
	if not _in_splash: # key and timer race the same transition; the first one wins
		return
	_in_splash = false
	_splash_timer.stop()
	_trace("splash_closed", {"reason": reason})
	show_title()

func _on_splash_timeout() -> void:
	_finish_splash("timeout")

func _is_any_action_pressed(event: InputEvent) -> bool:
	for action in SPLASH_SKIP_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false

func _rebuild_entries() -> void:
	_entries.clear()
	for label in _entry_labels():
		_entries.add_item(label)
	_entries.select(0)

func _entry_labels() -> Array:
	return [ENTRY_CONTINUE, ENTRY_NEW_GAME] if _has_save else [ENTRY_NEW_GAME]

func _move_selection(direction: int) -> void:
	if _entries.item_count == 0:
		return
	_entries.select(wrapi(_selected_entry() + direction, 0, _entries.item_count))
	_entries.ensure_current_is_visible()

func _selected_entry() -> int:
	var selected := _entries.get_selected_items()
	return int(selected[0]) if not selected.is_empty() else 0

func _activate_selected() -> void:
	if _entries.item_count == 0:
		return
	if _entries.get_item_text(_selected_entry()) == ENTRY_CONTINUE:
		_trace("title_continued", {"party_size": _party_size()})
		hide_screen()
		continue_chosen.emit()
	else:
		_begin_new_game()

# NEW GAME erases the loaded save, so with a save it first asks through the
# MessageBox sibling's confirm; without one there is nothing to erase and the
# emit sequence runs directly (the original asked nothing either).
func _begin_new_game() -> void:
	if not _has_save:
		_choose_new_game()
		return
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box == null or not confirm_box.has_method("show_confirm"):
		var runtime := _runtime()
		if runtime != null:
			runtime.warn("TitleScreen", "Confirm box is missing; NEW GAME was refused.", {})
		return
	_awaiting_confirm = true
	confirm_box.call("show_confirm", CONFIRM_TEXT)

func _choose_new_game() -> void:
	hide_screen()
	_trace("title_new_game_chosen", {})
	new_game_chosen.emit()

# The confirmed signal is SHARED (StartMenu's NEW GAME + StorageScreen's
# RELEASE ride it too): a confirm this screen did not open chooses nothing.
func _on_new_game_confirmed() -> void:
	if not _awaiting_confirm:
		return
	_awaiting_confirm = false
	_choose_new_game()

func _on_new_game_cancelled() -> void: _awaiting_confirm = false # cancel stays on the title

func _party_size() -> int:
	var runtime := _runtime()
	var session = runtime.get("session") if runtime != null else null
	return int(session.party.size()) if session != null else 0

func _trace(event_name: String, payload: Dictionary) -> void:
	var runtime := _runtime()
	if runtime != null:
		runtime.emit_trace(event_name, "TitleScreen", payload)

func _runtime() -> Node:
	return get_node_or_null("/root/GameRuntime")
