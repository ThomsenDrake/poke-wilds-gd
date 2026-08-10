extends Node

# legibility_soak scenario (agent-surface completion sprint, Workstream F): the
# ONE gate that actively uses the Phase-2 agent-legibility surfaces — it drives
# the five agent-facing screens (title, start menu, party, bag, battle) through
# the SAME seams as ui_tree_dump_scenario.gd (begin_boot + the public
# show_title creation-cancel path for the title, toggle_menu + _activate_entry
# for menu/party/bag, the battle_anim crafted pinned-GEODUDE presentation
# drive), writes the ui_tree dumps ITSELF (SELF-CONTAINED: no dependency on a
# prior ui_tree_dump run having left artifacts), and asserts the three
# legibility surfaces AGREE — dump shape + the a11y widget contract, the
# game/* Performance monitors (current_screen read WHILE each screen is up,
# closing the "MANUALLY kept in sync" gap flagged on performance_monitors.gd),
# and the trace lifecycle of the driven transitions. The assertions live in
# legibility_soak_checks.gd (the app 220-wall split; the new_game_flow_checks
# precedent); the dumps delegate to ui_tree_dump_writer.gd — the SINGLE
# contract-artifact writer both dump scenarios share (strict-review F1), so
# both emit the identical artifact bytes by construction.
#
# Determinism posture (the ui_tree_dump precedent; NOT a double-run consumer):
# SELF-PINNED — seed_for_smoke(PIN) BEFORE any drive, so the battle screen's
# crafted wild mon + its battle-start draws land on the pinned stream. The
# dump itself reads no rng. miss-002 total exit: a non-pass emits
# legibility_soak_failed{failures} AND push_error; the pass emits
# legibility_soak_passed{screens, checks, pin}.

const LegibilitySoakChecks := preload("res://scripts/app/legibility_soak_checks.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const UiTreeDumpWriter := preload("res://scripts/app/ui_tree_dump_writer.gd")

const PIN := 2026080905 # seed_for_smoke pin: next in the 20260809xx series (01-04 taken by the Phase-2 slice)
const WILD_SPECIES := "GEODUDE" # the battle_anim fixture species (rock-typed, battle-viable)
const WILD_LEVEL := 12

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _checks: Node = null
var _screens_dumped: Array = []

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime: Node = _ctx["runtime"]
	runtime.seed_for_smoke(PIN) # BEFORE any drive: every battle draw lands on the pinned stream
	_checks = LegibilitySoakChecks.new()
	add_child(_checks)
	_checks.run(_ctx, _runner, _failures)
	var cursor := _runner.trace_log_line_count() # pre-drive: every lifecycle event lands after it
	await _drive_title()
	await _drive_menus()
	await _drive_battle()
	_restore()
	_checks.scalars_readable()
	for screen in ["title", "menu", "party", "bag", "battle"]:
		_checks.dump_file_ok(screen)
	_checks.lifecycle_traces_ok(cursor)
	if _failures.is_empty():
		runtime.emit_trace("legibility_soak_passed", "SmokeScenarios", {"screens": _screens_dumped, "checks": _checks.checks_run(), "pin": PIN})
	else:
		runtime.emit_trace("legibility_soak_failed", "SmokeScenarios", {"failures": _failures, "screens": _screens_dumped})
		push_error("legibility_soak scenario failed: %s" % "; ".join(PackedStringArray(_failures)))

# Title: the player-boot seam raises the splash; the public creation-cancel path
# (show_title) lands the entry phase deterministically (the 2.0s SplashTimer
# no-ops afterwards on _in_splash == false). The monitor read happens WHILE the
# entry phase is up.
func _drive_title() -> void:
	var title: Control = _ctx["title_screen"]
	title.begin_boot(_runtime().has_loaded_save())
	title.show_title()
	await _settle(2)
	if not _checks.expect(title.visible and title.get_node("EntryPanel").visible, "title: the entry phase did not come up"):
		return
	_checks.monitor_agrees("title")
	_dump_screen("title", title, {"index": title.selected_entry(), "label": title.entry_row_text(title.selected_entry()), "entries": title.entry_labels()})
	title.hide_screen() # TitleScreen.visible gates main._toggle_menu — hide before the menu phase
	await _settle(1)

# Start menu + its two submenu children, dumped as THREE screens (the menu root
# stays visible behind a submenu; each dump roots at the screen being captured).
func _drive_menus() -> void:
	_call("toggle_menu")
	await _settle(2)
	var menu: Node = _ctx["start_menu"]
	if not _checks.expect(menu.visible, "menu: toggle did not open the start menu"):
		return
	_checks.monitor_agrees("menu")
	_dump_screen("menu", menu, {"index": menu._selected_entry(), "label": menu.selected_row_text(), "entries": Array(menu.ENTRIES)})
	menu._activate_entry(menu.ENTRY_POKEMON)
	await _settle(2)
	var party: Control = menu.get_node("PartyScreen")
	if _checks.expect(party.visible, "party: the POKEMON entry did not open the party screen"):
		_checks.monitor_agrees("party")
		_dump_screen("party", party, {"index": party._selected, "label": party.selected_row_text()})
		party.close_screen()
		await _settle(2)
	menu._activate_entry(menu.ENTRY_BAG)
	await _settle(2)
	var bag: Control = menu.get_node("BagScreen")
	if _checks.expect(bag.visible, "bag: the BAG entry did not open the bag screen"):
		_checks.monitor_agrees("bag")
		_dump_screen("bag", bag, {"index": bag._selected, "label": bag.selected_row_text()})
		bag.close_screen()
		await _settle(2)
	_call("toggle_menu")
	await _settle(2)

# Battle: the battle_anim drive idiom (crafted mon through the live view's
# presentation seam), dumped at the action menu; escaped afterwards.
func _drive_battle() -> void:
	var runtime: Node = _ctx["runtime"]
	var catalog = runtime.get("catalog")
	var pokemon_rules = runtime.get("pokemon_rules")
	var wild_mon: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species(WILD_SPECIES), WILD_LEVEL, Callable(catalog, "get_move"))
	if not _checks.expect(not wild_mon.is_empty(), "battle: could not build the wild %s" % WILD_SPECIES):
		return
	var set_battle: Callable = _ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(true)
	_ctx["message_box"].hide_message()
	_ctx["music_router"].play_battle_track("wild")
	var view: Node = _ctx["battle_view"]
	view.start_wild_battle(wild_mon)
	await _settle(3)
	if _checks.expect(view.visible, "battle: the battle view did not open"):
		_checks.monitor_agrees("battle")
		_dump_screen("battle", view, {"menu_state": str(view._menu_state), "selection": str(view._selection)})
	if view.visible:
		view.run_smoke_escape()
		await get_tree().create_timer(0.2).timeout
	if set_battle.is_valid():
		set_battle.call(false)

func _dump_screen(screen_id: String, root: Control, cursor: Dictionary) -> void:
	if UiTreeDumpWriter.write_screen(screen_id, root, cursor) < 0:
		_checks.expect(false, "%s: could not write %s/%s.json" % [screen_id, UiTreeDumpWriter.OUT_DIR, screen_id])
		return
	_screens_dumped.append(screen_id)

func _restore() -> void: # EVERY exit path: screens hidden, no battle left open
	_ctx["title_screen"].hide_screen()
	_ctx["start_menu"].hide_menu()
	var view: Node = _ctx["battle_view"]
	if view.visible:
		view.run_smoke_escape()

func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame

func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)

func _runtime() -> Node: return _ctx["runtime"]
