extends Control

# Startup splash + title menu as PHASES of one scene, rebuilt on the GBC stage
# idiom (restyle slice wave 0; spec: docs/product-specs/bootstrap-and-overworld.md):
# a native 160x144 stage via scripts/ui/gbc_stage.gd (the BattleView SubViewport
# idiom), integer-scaled into the window. PHASE SPLASH: opaque black stage + two
# centered WHITE-ink fonts.ttf@7 lines (white ink is legal ONLY here, on the
# pure-black backing) shown 2.0s or until ANY action press skips them. PHASE
# TITLE: gsc/background1.png full-stage art (load-guarded, black fallback) + a
# white wordmark plate (black ink) + the textbox_bg2.png bottom entry band with
# a black-ink gbc_widgets row list (CONTINUE only when a save loaded) and the
# black arrow cursor. The opaque Backing hides the unsynced boot world (main.gd
# syncs only in _enter_world). Stage art lives in the viewport, so the scenario's
# visibility witnesses ride two contentless root children that KEEP THEIR NAMES:
# "Splash" and "EntryPanel". Stage composition lives in title_screen_stage.gd
# (the 220-wall extraction; menu_context.gd precedent).
#
# Traces ride the runtime's emit_trace seam, self-wired through
# /root/GameRuntime (the options_screen/storage_screen precedent); the names
# and payloads are a FROZEN CONTRACT with the new_game_flow gate scenario:
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
# handlers gate on _awaiting_confirm before acting (start_menu precedent).

signal continue_chosen
signal new_game_chosen
signal closed # argless latch — emits on EVERY hide (the bind_ui_consumers contract)

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const TitleStage := preload("res://scripts/ui/title_screen_stage.gd")

const ENTRY_CONTINUE := "CONTINUE"
const ENTRY_NEW_GAME := "NEW GAME"
const CONFIRM_TEXT := "Start a new game? Your current save will be erased."
const SPLASH_SKIP_ACTIONS: PackedStringArray = ["move_up", "move_down", "move_left", "move_right", "action_a", "action_b", "start"]

@onready var _splash_timer: Timer = $SplashTimer

var _splash: Control # contentless visibility witness (scenario: get_node("Splash").visible)
var _entry_panel: Control # contentless visibility witness (get_node("EntryPanel").visible)
var _splash_card: Control # stage group: the two white-ink splash labels
var _title_card: Control # stage group: background + wordmark plate + entry band
var _rows # GbcWidgets.RowList over the entry band (black ink + black arrow cursor)
var _has_save := false
var _in_splash := false
var _awaiting_confirm := false

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # {viewport, stage, display, backing}
	GbcStage.on_resized(self, parts.display)
	var built := TitleStage.build(parts.stage)
	_splash_card = built.splash_card
	_title_card = built.title_card
	_rows = built.rows
	_splash = TitleStage.witness(self, "Splash")
	_entry_panel = TitleStage.witness(self, "EntryPanel")
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
	_splash_card.visible = true
	_title_card.visible = false
	_splash.visible = true
	_entry_panel.visible = false
	visible = true
	_splash_timer.start()
	_trace("splash_shown", {})

# Title phase; also the back-from-creation-cancel path (title_shown re-emits).
func show_title() -> void:
	_in_splash = false
	_splash.visible = false
	_splash_card.visible = false
	_title_card.visible = true
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

# --- Scenario seams (restyle design §2.1; the old EntryPanel/Entries ItemList reads) ---
func entry_labels() -> Array: return _entry_labels()
func selected_entry() -> int: return _rows.selected()
func select_entry(index: int) -> void: _rows.select(index)
func entry_row_text(index: int) -> String: return _rows.row_text(index)

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
		_rows.move(-1)
	elif event.is_action_pressed("move_down"):
		_rows.move(1)
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
	_rows.set_rows(_entry_labels()) # resets the cursor to row 0 (the CONTINUE start)
	TitleStage.center_rows(_rows)

func _entry_labels() -> Array:
	return [ENTRY_CONTINUE, ENTRY_NEW_GAME] if _has_save else [ENTRY_NEW_GAME]

func _activate_selected() -> void:
	if _rows.row_count() == 0:
		return
	if _rows.row_text(_rows.selected()) == ENTRY_CONTINUE:
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
