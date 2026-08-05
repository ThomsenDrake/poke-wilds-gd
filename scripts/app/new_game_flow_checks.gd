extends Node

# Creation end-to-end + world/persistence witnesses for new_game_flow_scenario
# (title_flow slice; the input_gate_menu_checks extraction precedent — the
# scenario file stays the driver; these are design §7 parts 4-6). Everything
# drives the REAL screens through input-phase injection (SmokeTap + the
# caller-owned Input.use_accumulated_input, the input_gate precedent); every
# driving tap carries an injection WITNESS — state only real delivery can
# produce — so degraded delivery fails red, never vacuous.
# Part 4 rides the real player-boot seam: TitleScreen.begin_boot(true) ->
# MessageBox save-wipe confirm -> CreationScreen; WORLD_SEED rides the in-stage
# seed digit row as unicode digit events (no InputMap action exists for digits);
# the NameEntry grid walks A->S->H->OK (cells 0->18->7->27) and the
# AvatarPicker grid walks ben(0)->kris(11); the part ends on the EXACT
# creation_confirmed payload. Part 5 re-derives the beach spawn off the PURE
# generator (the seed_choice _prove_beach_spawn shape). Part 6 proves the
# three additive save keys + the load-path odds re-apply.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const Geo := preload("res://scripts/app/new_game_flow_geo.gd")

# The scenario's pins, mirrored here (single pin set per file, the menu_checks precedent).
const WORLD_SEED := 2026080602 # probed beach spawn (the scenario's WORLD_SEED)
const NAME := "ASH"
const AVATAR := "kris" # sorted AVATARS index 11
const ODDS := 64

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = [] # shared with the parent scenario
var _oks: Dictionary = {} # shared pass-payload witness bools
var _go_cursor := 0 # trace cursor before the GO press: scopes session_created + shiny_rolled

func run(ctx: Dictionary, runner, failures: Array, oks: Dictionary) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _oks = oks
	if _failures.is_empty(): await _part_4_creation()
	else: _failures.append("skipped: creation (cascaded from a title-flow red)")
	if _failures.is_empty(): _part_5_world()
	else: _failures.append("skipped: world witnesses (cascaded from a creation red)")
	if _failures.is_empty(): _part_6_persistence()
	else: _failures.append("skipped: persistence (cascaded from an earlier red)")

# Part 4 — creation end-to-end off the real player-boot seam.
func _part_4_creation() -> void:
	var title := _title()
	var creation := _creation()
	title.begin_boot(true) # has_save: NEW GAME must ride the real save-wipe confirm gate
	await _tap("action_a") # splash skip
	if not _expect(not title.get_node("Splash").visible and title.entry_labels().size() == 2, "4: injection witness: the splash skip did not raise the with-save title"):
		return
	await _tap("move_down") # CONTINUE -> NEW GAME
	if not _expect(title.entry_row_text(title.selected_entry()) == "NEW GAME", "4: precondition witness: the cursor did not land on NEW GAME"):
		return
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # NEW GAME: the MessageBox sibling confirm must open first
	if not _expect(_message_box().is_confirming(), "4: injection witness: NEW GAME did not open the save-wipe confirm"):
		return
	await _tap("action_a") # the confirm answer runs the title -> creation swap
	_expect(_runner.trace_log_has_since("title_new_game_chosen", cursor), "4: no title_new_game_chosen trace after the confirmed NEW GAME")
	if not _expect(creation.visible and not title.visible, "4: injection witness: the confirm did not swap title -> creation"):
		return
	var title_label: Label = creation.step_title_label() # restyle seam (design §3.1; the old Panel/Margin/VBox reads)
	var value_label: Label = creation.step_value_label()
	# SEED step: RANDOM is the one-press default; move_left is the custom-seed gesture.
	if not _expect(title_label.text == "WORLD SEED" and value_label.text == "RANDOM", "4: the seed step opened on '%s'/'%s', not WORLD SEED/RANDOM" % [title_label.text, value_label.text]):
		return
	await _tap("move_left")
	if not _expect(creation.seed_edit_active(), "4: injection witness: move_left did not open the seed digit row"):
		return
	for character in str(WORLD_SEED): # digits ride unicode key events (the digit row's typed-digit branch reads unicode 48-57)
		await _tap_digit(int(character))
	await _tap("action_a") # the digit row's Z commit stores the typed seed
	_expect(not creation.seed_edit_active(), "4: injection witness: Z did not commit the seed digit row")
	if not _expect(value_label.text == str(WORLD_SEED), "4: the seed step shows '%s', not the typed %d" % [value_label.text, WORLD_SEED]):
		return
	await _tap("action_a") # advance
	# SHINY step: two lefts walk the ladder 256 -> 128 -> 64 (the non-default pin).
	if not _expect(title_label.text == "SHINY RATE", "4: the shiny step title is '%s', not SHINY RATE" % title_label.text):
		return
	await _tap("move_left")
	await _tap("move_left")
	if not _expect(value_label.text.contains("1/%d" % ODDS), "4: the shiny step shows '%s', not 1/%d" % [value_label.text, ODDS]):
		return
	await _tap("action_a") # advance
	# NAME step: Z opens the grid keyboard; the cursor starts on A (cell 0).
	if not _expect(title_label.text == "NAME", "4: the name step title is '%s', not NAME" % title_label.text):
		return
	await _tap("action_a")
	var entry: Control = creation._name_entry
	if not _expect(entry.visible, "4: injection witness: Z did not open the NameEntry grid"):
		return
	Geo.new().check(entry, "name grid", _failures)
	var name_label: Label = entry._name_label
	await _tap("action_a") # A (cell 0)
	if not _expect(name_label.text == "NAME — A_", "4: the grid press shows '%s', not 'NAME — A_' (the cursor missed cell 0)" % name_label.text):
		return
	await _flush("move_down", 2); await _flush("move_right", 4) # A(0) +14 -> 14 -> S(18)
	await _tap("action_a")
	await _flush("move_up", 1); await _flush("move_left", 4) # S(18) -7 -> 11 -> H(7)
	await _tap("action_a")
	await _flush("move_right", 20) # H(7) +20 -> OK(27) — the wrap nav carries the long flush
	await _tap("action_a") # OK confirms back to the step
	_expect(not entry.visible, "4: injection witness: OK did not close the NameEntry grid")
	if not _expect(value_label.text == NAME, "4: the name step shows '%s', not %s" % [value_label.text, NAME]):
		return
	_oks["name_ok"] = true
	await _tap("action_a") # advance
	# AVATAR step: Z opens the picker; kris sits at sorted AVATARS index 11.
	if not _expect(title_label.text == "PLAYER", "4: the avatar step title is '%s', not PLAYER" % title_label.text):
		return
	await _tap("action_a")
	var picker: Control = creation._avatar_picker
	if not _expect(picker.visible, "4: injection witness: Z did not open the AvatarPicker grid"):
		return
	Geo.new().check(picker, "avatar grid", _failures)
	await _flush("move_right", 11) # ben(0) -> kris(11)
	var picker_label: Label = picker._name_label
	if not _expect(picker_label.text == AVATAR, "4: the picker cursor is '%s', not %s (the index math drifted)" % [picker_label.text, AVATAR]):
		return
	await _tap("action_a") # Z confirms kris
	_expect(not picker.visible, "4: injection witness: Z did not close the AvatarPicker")
	if not _expect(value_label.text == AVATAR, "4: the avatar step shows '%s', not %s" % [value_label.text, AVATAR]):
		return
	_oks["avatar_ok"] = true
	await _tap("action_a") # advance
	# GO step: the summary must carry the identity + the seed; Z starts the beat.
	if not _expect(title_label.text == "Go!", "4: the GO step title is '%s', not Go!" % title_label.text):
		return
	if not _expect(value_label.text.contains(NAME) and value_label.text.contains(str(WORLD_SEED)), "4: the GO summary '%s' is missing the name or the seed" % value_label.text):
		return
	_go_cursor = _runner.trace_log_line_count()
	await _tap("action_a")
	if not _expect(value_label.text == creation.GENERATING_TEXT, "4: the GO press did not raise the faithful generating beat ('%s')" % value_label.text):
		return
	await get_tree().create_timer(0.9).timeout # the 0.6s GenTimer beat + headroom
	_expect(_runner.trace_log_has_since("creation_confirmed", _go_cursor, {"player_name": NAME, "player_avatar": AVATAR, "shiny_odds": ODDS, "world_seed": WORLD_SEED}), "4: no creation_confirmed with the EXACT pinned payload since the GO press")

# Part 5 — world witnesses post-begin_created_game (the creation seam ran).
func _part_5_world() -> void:
	var runtime := _runtime()
	_expect(runtime.get_world_seed() == WORLD_SEED, "5: runtime world_seed %d != the created seed %d" % [runtime.get_world_seed(), WORLD_SEED])
	_expect(_runner.trace_log_has_since("session_created", _go_cursor), "5: no session_created trace since the GO confirm")
	var start := _failures.size()
	var party: Array = runtime.session.party
	var lead: Dictionary = party[0] if not party.is_empty() else {}
	_expect(party.size() == 1, "5: the party size %d != 1" % party.size())
	_expect(str(lead.get("species_id", "")) == "MACHOP", "5: the starter is '%s', not MACHOP" % str(lead.get("species_id", "")))
	_expect(int(lead.get("level", 0)) == 5, "5: the starter level is %d, not 5" % int(lead.get("level", 0)))
	_expect(runtime.field_move_capable("build"), "5: the starter cannot Build (MACHOP's FIGHTING auto-type is the faithful witness)")
	_oks["starter_ok"] = _failures.size() == start
	start = _failures.size()
	_expect(_runner.trace_log_has_since("shiny_rolled", _go_cursor, {"origin": "starter", "odds": ODDS}), "5: no shiny_rolled{origin:starter, odds:%d} — the creation knob did not ride into the roll" % ODDS)
	_oks["odds_ok"] = _failures.size() == start
	start = _failures.size()
	# Beach spawn, re-derived off the PURE generator (the seed_choice _prove_beach_spawn
	# shape: SAND + walkable + a cardinal surf neighbor — never the render cache).
	var spawn: Vector2i = runtime.get_player_tile()
	var logic: Dictionary = runtime._world_gen.get_tile_logic(spawn)
	_expect(str(logic.get("biome", "")) == "SAND", "5: the spawn tile %s biome '%s' != SAND (the beach pass missed for the pin)" % [str(spawn), str(logic.get("biome", ""))])
	_expect(bool(logic.get("walkable", false)), "5: the spawn tile %s is SAND but not walkable" % str(spawn))
	var surf := false
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if str(runtime._world_gen.get_tile_logic(spawn + direction).get("requires_field_move", "")) == "surf":
			surf = true
	_expect(surf, "5: the spawn tile %s has no cardinal surf neighbor (the beach-pass gate regressed)" % str(spawn))
	_oks["beach_ok"] = _failures.size() == start

# Part 6 — persistence: the three additive save keys + the load-path odds re-apply.
func _part_6_persistence() -> void:
	var runtime := _runtime()
	var start := _failures.size()
	var payload = runtime.save_store.load_payload()
	_expect(str(payload.get("player_name", "")) == NAME, "6: the save player_name '%s' != %s" % [str(payload.get("player_name", "")), NAME])
	_expect(str(payload.get("player_avatar", "")) == AVATAR, "6: the save player_avatar '%s' != %s" % [str(payload.get("player_avatar", "")), AVATAR])
	_expect(int(payload.get("shiny_rate", 0)) == ODDS, "6: the save shiny_rate %d != %d" % [int(payload.get("shiny_rate", 0)), ODDS])
	runtime.pokemon_rules.shiny_odds = SessionState.SHINY_ODDS_DEFAULT # scrub the live odds (the static rides instance access — the app layer may not preload domain): the load-path re-apply becomes the ONLY way back to ODDS
	_expect(runtime._apply_loaded_payload(payload), "6: _apply_loaded_payload refused the just-written save")
	_expect(str(runtime.session.player_name) == NAME and str(runtime.session.player_avatar) == AVATAR and int(runtime.session.shiny_odds_choice) == ODDS, "6: the load path did not restore the identity session vars")
	_expect(int(runtime.pokemon_rules.shiny_odds) == ODDS, "6: PokemonRules.shiny_odds %d != %d after the load-path re-apply" % [int(runtime.pokemon_rules.shiny_odds), ODDS])
	_oks["persist_ok"] = _failures.size() == start

# --- Real input-phase injection (SmokeTap; the caller owns use_accumulated_input) ---
func _tap(action: String) -> void:
	await SmokeTap.tap(get_tree(), action)

# N presses flush in ONE input phase -> N just_pressed dispatches (input_gate's
# camp-menu flush shape), one release afterwards.
func _flush(action: String, count: int) -> void:
	for _i in range(count):
		if not SmokeTap.inject_press(action):
			_failures.append("injection: no key event is bound to %s" % action)
			return
	SmokeTap.inject_release(action)
	await get_tree().process_frame

# One typed digit for the seed digit row: unicode + matching keycode/physical_keycode
# (gbc_digit_row's branch reads unicode 48-57), press -> frame -> release.
func _tap_digit(digit: int) -> void:
	var press := InputEventKey.new()
	press.unicode = 48 + digit; press.keycode = 48 + digit; press.physical_keycode = 48 + digit; press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	var release := InputEventKey.new()
	release.unicode = 48 + digit; release.keycode = 48 + digit; release.physical_keycode = 48 + digit; release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame

func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok

func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _message_box() -> Node: return _ctx["message_box"]
func _runtime() -> Node: return _ctx["runtime"]
