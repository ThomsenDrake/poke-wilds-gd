extends RefCounted

# App-layer input routing extracted from main.gd so the scene script stays
# under its line budget. Owns the InputMap action set — movement, confirm/
# cancel (action_a/action_b), run modifier, and the start/menu toggle — plus
# the per-frame polls that forward "start" to Main's menu handler and
# "action_a" to Main's context action. Movement and confirm/cancel reach
# their other consumers (player avatar, UI screens) directly through these
# actions; only the menu toggle and context action are routed here. The polls
# also honor a same-frame latch that EVERY input-phase UI close/confirm sets
# (see bind_ui_consumers) AND that Main._on_battle_finished sets when a press
# ENDS A BATTLE (note_press_consumed), so a press that closed/confirmed an
# overlay or ended a battle there cannot re-fire them. CALL-ORDER CONTRACT:
# Main._process calls poll_menu_toggle() FIRST and poll_context_action()
# SECOND, every frame — the context poll is the second and last poll, and it
# resets the latch (a toggle-only frame strands it for one harmless frame).

const ACTION_BINDINGS := {
	"move_up": [Key.KEY_UP, Key.KEY_W],
	"move_down": [Key.KEY_DOWN, Key.KEY_S],
	"move_left": [Key.KEY_LEFT, Key.KEY_A],
	"move_right": [Key.KEY_RIGHT, Key.KEY_D],
	"action_a": [Key.KEY_Z],
	# X is deliberately shared between two actions in mutually exclusive input
	# contexts: `action_b` (cancel) is consumed ONLY by UI screens (start menu,
	# party/bag, battle) through _unhandled_input + set_input_as_handled, and
	# only while a screen is visible; `run` is polled ONLY during overworld
	# movement (player_avatar reads is_action_pressed while input_enabled). In
	# the overworld no UI consumes action_b (hidden screens return early); in
	# menus/battles the avatar is not moving (input_enabled = false). UI screens
	# read action_b via is_action_just_pressed, so holding X to run cannot
	# spuriously cancel a freshly opened menu. The shared physical key never
	# collides, so no rebind is needed.
	"action_b": [Key.KEY_X],
	"run": [Key.KEY_X],
	"start": [Key.KEY_ENTER],
}

var _on_menu_toggle: Callable
var _on_context_action: Callable
# The "a UI consumed this press this frame" latch. Every overlay owns Z/X/Enter
# via _unhandled_input during the INPUT PHASE, which runs BEFORE Main._process
# polls; a press that closes or confirms an overlay there must not also fire
# the same-frame polls. The camp menu was the first case (Enter -> start menu
# under a closing camp menu; Z-on-Demolish -> harvest/build re-fire on the bare
# former campfire tile); the Phase 3 final review found the camp-only latch
# leaked every OTHER input-phase close/confirm the same way: a MessageBox NEW
# GAME confirm harvested the spawn-facing tile on the BRAND-NEW world and
# superseded the "New game started." toast, a start-menu CLOSE re-harvested the
# faced tile, and a party FIELD MOVE on an inert move harvested the faced
# cut-tile the capability message had just declined. One latch, set by every
# producer, consumed by both polls — NOT a per-menu patch.
var _ui_ate_press := false


# The context action callable is optional so single-argument construction
# (menu toggle only) keeps working.
func _init(on_menu_toggle: Callable, on_context_action: Callable = Callable()) -> void:
	_on_menu_toggle = on_menu_toggle
	_on_context_action = on_context_action


# Idempotent: existing actions and key events are left untouched.
func configure_input_map() -> void:
	for action_name in ACTION_BINDINGS:
		_ensure_action(action_name, ACTION_BINDINGS[action_name])


# Wires the same-frame latch to every input-phase UI that can close or confirm
# an overlay: CampMenu.closed (X/Enter close, Z-Demolish close), StartMenu.
# closed (CLOSE entry, action_b, the NEW GAME confirm's hide_menu, a FIELD
# MOVE's hide_menu), MessageBox.confirmed/cancelled (the NEW GAME + RELEASE
# answer keys), StorageScreen.closed (X close). THE ARGLESS CONTRACT IS LOAD-
# BEARING: connect() binds nothing, so every producer must emit its signal with
# no arguments (all four UIs do) — a producer that grew an argument would
# silently stop setting the latch. Presses that leave a menu OPEN need no latch
# (submenu X-close, camp craft Z): the overlay stays visible, so Main's
# overworld-idle state and field_action_router's _overlay_open early-return
# already neutralize both polls. QUIRK: MessageBox.show_message while
# confirming emits cancelled; if that ever fires during _process (after the
# latch reset) the NEXT frame's first press dies once — post-fix no toast can
# interrupt a confirm (avatar disabled, polls guarded), so the quirk is latent.
func bind_ui_consumers(ui_nodes: Array) -> void:
	for ui_node in ui_nodes:
		if not (ui_node is Node):
			continue
		for signal_name in ["closed", "confirmed", "cancelled"]:
			if (ui_node as Node).has_signal(signal_name) and not (ui_node as Node).is_connected(signal_name, _on_ui_ate_press):
				(ui_node as Node).connect(signal_name, _on_ui_ate_press)


func _on_ui_ate_press() -> void:
	_ui_ate_press = true


# The battle-end producer (Main._on_battle_finished, same-line call): the two
# SYNCHRONOUS end paths resolve in the input phase — Z on RUN (run_from_battle)
# and a ball-select Z (use_pokeball capture) — emitting battle_finished there,
# so Main re-enables the overworld (_in_battle = false) WITHIN the input phase;
# without this latch the same-frame poll_context_action would harvest/build the
# faced tile and the harvest toast would supersede "Got away safely!". Set
# UNCONDITIONALLY at the single battle_finished endpoint, so any FUTURE press-
# driven end (a message advance, if one lands) is covered with no new wiring.
# The press-less ends (animated victory/defeat) set it AFTER that frame's polls
# ran, so the NEXT frame's BOTH polls early-return once — a coincidental Enter
# loses one menu toggle, a Z one context action — and poll_context_action's
# reset lands that same frame, so every later press fires (why battle_end_input
# part B and the menu paths stay live).
func note_press_consumed() -> void:
	_ui_ate_press = true


# Called from Main._process so the menu toggle keeps its original polling
# order relative to the rest of the scene tree.
func poll_menu_toggle() -> void:
	if _ui_ate_press:
		return
	if Input.is_action_just_pressed("start"):
		_on_menu_toggle.call()


# Called from Main._process with Main's overworld-idle state (not in a menu,
# battle, or step animation) so the context route can only fire while the
# player is free to act in the overworld. Captures + resets the latch
# unconditionally FIRST — it is the second and last poll each frame (the order
# contract above), so it owns the reset even on frames the toggle early-
# returned.
func poll_context_action(overworld_idle: bool) -> void:
	var ui_ate_press := _ui_ate_press
	_ui_ate_press = false
	if not overworld_idle or not _on_context_action.is_valid() or ui_ate_press:
		return
	if Input.is_action_just_pressed("action_a"):
		_on_context_action.call()


func _ensure_action(action_name: StringName, keys: Array) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	var existing_events = InputMap.action_get_events(action_name)
	for keycode in keys:
		if _has_key_event(existing_events, keycode):
			continue
		var key_event = InputEventKey.new()
		key_event.physical_keycode = keycode
		InputMap.action_add_event(action_name, key_event)


func _has_key_event(events: Array, keycode: Key) -> bool:
	for event in events:
		if event is InputEventKey and event.physical_keycode == keycode:
			return true
	return false
