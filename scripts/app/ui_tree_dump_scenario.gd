extends Node

# ui_tree_dump scenario (agent-neutral integration Phase 2 — the accessibility-
# snapshot analog): drives the five agent-facing screens (title, start menu,
# party, bag, battle) through the SAME scenario seams nav_audit/layout_audit
# use and writes each visible Control subtree to .godot-smoke/ui_tree/
# <screen>.json — per node: path relative to the screen root, type, label text
# when non-empty, global rect, disabled — plus the AccessKit annotations the
# GBC widget library sets (a11y_name/a11y_description/a11y_live, emitted only
# when non-default; every dumped node passed the full-chain _shown filter, so a
# constant "visible" field carries no information) — plus the screen id and the
# cursor/selection where the screen exposes one. Paths in the transcript,
# never binary payloads (the snapshot-sidecar convention).
#
# Determinism posture (the new_game_flow precedent; NOT a double-run consumer):
# SELF-PINNED — seed_for_smoke(PIN) BEFORE any drive, so the battle screen's
# crafted wild mon + its battle-start draws land on the pinned stream. The
# dump itself reads no rng. miss-002 total exit: a non-pass emits
# ui_tree_dump_failed{failures} AND push_error; the pass emits
# ui_tree_dump_passed{screens, nodes, dir, pin}.

const OUT_DIR := "res://.godot-smoke/ui_tree"
const PIN := 2026080904 # seed_for_smoke pin: the battle dump's crafted mon rides this stream
const WILD_SPECIES := "GEODUDE" # the battle_anim fixture species (rock-typed, battle-viable)
const WILD_LEVEL := 12

var _ctx: Dictionary = {}
var _failures: Array = []
var _screens_dumped: Array = []
var _total_nodes := 0

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime: Node = _ctx["runtime"]
	runtime.seed_for_smoke(PIN) # BEFORE any drive: every battle draw lands on the pinned stream
	await _dump_title()
	await _dump_menus()
	await _dump_battle()
	_restore()
	if _failures.is_empty():
		runtime.emit_trace("ui_tree_dump_passed", "SmokeScenarios", {"screens": _screens_dumped, "nodes": _total_nodes, "dir": OUT_DIR, "pin": PIN})
	else:
		runtime.emit_trace("ui_tree_dump_failed", "SmokeScenarios", {"failures": _failures, "screens": _screens_dumped})
		push_error("ui_tree_dump scenario failed: %s" % "; ".join(PackedStringArray(_failures)))

# Title: the player-boot seam raises the splash; the public creation-cancel path
# (show_title) lands the entry phase deterministically (the 2.0s SplashTimer
# no-ops afterwards on _in_splash == false).
func _dump_title() -> void:
	var title: Control = _ctx["title_screen"]
	title.begin_boot(_runtime().has_loaded_save())
	title.show_title()
	await _settle(2)
	if not _reach(title.visible and title.get_node("EntryPanel").visible, "title: the entry phase did not come up"):
		return
	_dump_screen("title", title, {"index": title.selected_entry(), "label": title.entry_row_text(title.selected_entry()), "entries": title.entry_labels()})
	title.hide_screen() # TitleScreen.visible gates main._toggle_menu — hide before the menu phase
	await _settle(1)

# Start menu + its two submenu children, dumped as THREE screens (the menu root
# stays visible behind a submenu; each dump roots at the screen being captured).
func _dump_menus() -> void:
	_call("toggle_menu")
	await _settle(2)
	var menu: Node = _ctx["start_menu"]
	if not _reach(menu.visible, "menu: toggle did not open the start menu"):
		return
	_dump_screen("menu", menu, {"index": menu._selected_entry(), "label": menu.selected_row_text(), "entries": Array(menu.ENTRIES)})
	menu._activate_entry(menu.ENTRY_POKEMON)
	await _settle(2)
	var party: Control = menu.get_node("PartyScreen")
	if _reach(party.visible, "party: the POKEMON entry did not open the party screen"):
		_dump_screen("party", party, {"index": party._selected, "label": party.selected_row_text()})
		party.close_screen()
		await _settle(2)
	menu._activate_entry(menu.ENTRY_BAG)
	await _settle(2)
	var bag: Control = menu.get_node("BagScreen")
	if _reach(bag.visible, "bag: the BAG entry did not open the bag screen"):
		_dump_screen("bag", bag, {"index": bag._selected, "label": bag.selected_row_text()})
		bag.close_screen()
		await _settle(2)
	_call("toggle_menu")
	await _settle(2)

# Battle: the battle_anim drive idiom (crafted mon through the live view's
# presentation seam), dumped at the action menu; escaped afterwards.
func _dump_battle() -> void:
	var runtime: Node = _ctx["runtime"]
	var catalog = runtime.get("catalog")
	var pokemon_rules = runtime.get("pokemon_rules")
	var wild_mon: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species(WILD_SPECIES), WILD_LEVEL, Callable(catalog, "get_move"))
	if not _reach(not wild_mon.is_empty(), "battle: could not build the wild %s" % WILD_SPECIES):
		return
	var set_battle: Callable = _ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(true)
	_ctx["message_box"].hide_message()
	_ctx["music_router"].play_battle_track("wild")
	var view: Node = _ctx["battle_view"]
	view.start_wild_battle(wild_mon)
	await _settle(3)
	if _reach(view.visible, "battle: the battle view did not open"):
		_dump_screen("battle", view, {"menu_state": str(view._menu_state), "selection": str(view._selection)})
	if view.visible:
		view.run_smoke_escape()
		await get_tree().create_timer(0.2).timeout
	if set_battle.is_valid():
		set_battle.call(false)

func _dump_screen(screen_id: String, root: Control, cursor: Dictionary) -> void:
	var all: Array = [root]
	all.append_array(root.find_children("*", "Control", true, false))
	var nodes: Array = []
	for node in all:
		var control := node as Control
		if control == null or not _shown(control):
			continue
		var entry := {
			"path": str(root.get_path_to(control)),
			"type": control.get_class(),
			"rect": _rect_payload(control.get_global_rect()),
			"disabled": control.get("disabled") == true,
		}
		var text = control.get("text")
		if text is String and not (text as String).is_empty():
			entry["text"] = text
		var a11y_name := str(control.get("accessibility_name"))
		if not a11y_name.is_empty():
			entry["a11y_name"] = a11y_name
		var a11y_desc := str(control.get("accessibility_description"))
		if not a11y_desc.is_empty():
			entry["a11y_description"] = a11y_desc
		var a11y_live := int(control.get("accessibility_live"))
		if a11y_live != 0: # LIVE_OFF default: only live regions carry the field
			entry["a11y_live"] = a11y_live
		nodes.append(entry)
	nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["path"]) < str(b["path"]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := "%s/%s.json" % [OUT_DIR, screen_id]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("%s: could not write %s" % [screen_id, path])
		return
	file.store_string(JSON.stringify({"screen": screen_id, "cursor": cursor, "node_count": nodes.size(), "nodes": nodes}, "  ") + "\n")
	file.close()
	_screens_dumped.append(screen_id)
	_total_nodes += nodes.size()

func _restore() -> void: # EVERY exit path: screens hidden, no battle left open
	_ctx["title_screen"].hide_screen()
	_ctx["start_menu"].hide_menu()
	var view: Node = _ctx["battle_view"]
	if view.visible:
		view.run_smoke_escape()

# Full-chain visibility to the window root (the accessibility-snapshot semantic):
# unlike layout_audit._shown — which stops at the owning Viewport so it can audit
# a HIDDEN BattleView's stage internals — this scenario opens every screen for
# real, so a hidden sibling screen root (e.g. OptionsScreen under the start menu)
# must mask its SubViewport children; stopping at the Viewport would leak them in
# as visible. SubViewport nodes themselves are not CanvasItems and skip cleanly.
func _shown(control: Control) -> bool:
	var node: Node = control
	while node != null:
		if node is CanvasItem and not (node as CanvasItem).visible:
			return false
		node = node.get_parent()
	return true

func _rect_payload(rect: Rect2) -> Array:
	return [int(roundf(rect.position.x)), int(roundf(rect.position.y)), int(roundf(rect.size.x)), int(roundf(rect.size.y))]

func _reach(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for reach-guard early returns
	if not ok:
		_failures.append(label)
	return ok

func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame

func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)

func _runtime() -> Node: return _ctx["runtime"]
