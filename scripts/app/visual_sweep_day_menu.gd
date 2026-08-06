extends Node

# Day/night + menu state shots of the main visual sweep (24-25 day_night group,
# 28-29 menu group; extracted from visual_sweep.gd for the app line budget).
# 24_dusk pins ~18:00; 25_night_boundary pins tod=269, the minute the night band
# releases. 28 stages the bag STONE-USE party picker over an EEVEE/MAGIKARP party
# with worst-case name lengths through the REAL bag branch (fire_stone never
# consumed: the shot is the picker, not a confirm). 29 opens the party summary on
# a crafted Egg. Every crafted state is restored (tod, party, bag, menus) before
# returning, so later captures see the sweep's canonical state.

const UiRenderFixtures := preload("res://scripts/app/ui_render_fixtures.gd")

const SHOT_DUSK := "24_dusk.png"
const SHOT_NIGHT_BOUNDARY := "25_night_boundary.png"
const SHOT_STONE_PICKER := "28_stone_picker.png"
const SHOT_EGG_SUMMARY := "29_party_egg_summary.png"
const DUSK_TOD := 1080 # ~18:00
const NIGHT_BOUNDARY_TOD := 269 # 04:29: the pinned tod just inside the night band's edge
const EGG_SPECIES := "CHIKORITA"

var _ctx: Dictionary = {}
var _crafted: Dictionary = {}
var _capture: Callable = Callable()
var _failures: Array = []


func craft_day_menu(ctx: Dictionary, crafted: Dictionary, capture: Callable, failures: Array) -> void:
	_ctx = ctx
	_crafted = crafted
	_capture = capture
	_failures = failures
	await _day_night_shots()
	await _stone_picker_shot()
	await _egg_summary_shot()


func _day_night_shots() -> void:
	var noon: int = int(_crafted["time_of_day"])
	_world().set_time_of_day(DUSK_TOD)
	await _capture.call(SHOT_DUSK)
	_world().set_time_of_day(NIGHT_BOUNDARY_TOD)
	await _capture.call(SHOT_NIGHT_BOUNDARY)
	_world().set_time_of_day(noon)


# Bag -> FIRE STONE -> the real use branch opens the party picker over a crafted
# EEVEE/MAGIKARP pair renamed to the catalog's longest species name (worst-case
# row length, ui_render_fixtures convention). No confirm: the stone is not spent.
func _stone_picker_shot() -> void:
	var runtime := _runtime()
	var session = runtime.session
	var bag_screen: Node = null
	runtime.session.add_item("fire_stone", 1)
	var saved_party: Array = session.party.duplicate(true)
	var picker_party := _crafted_picker_party(runtime)
	if picker_party.size() != saved_party.size():
		_failures.append("%s: could not craft the EEVEE/MAGIKARP picker party (catalog incomplete)" % SHOT_STONE_PICKER)
	else:
		for i in range(picker_party.size()):
			session.set_party_member(i, picker_party[i])
		_call("toggle_menu")
		_start_menu()._activate_entry(1) # BAG entry; opens the bag screen
		bag_screen = _start_menu().get_node_or_null("BagScreen")
		if bag_screen == null or not _select_bag_item(bag_screen, "fire_stone"):
			_failures.append("%s: fire_stone is not selectable in the bag" % SHOT_STONE_PICKER)
		else:
			bag_screen._confirm() # the real use branch: stone -> party picker (egg-refusing)
			await _capture.call(SHOT_STONE_PICKER)
			bag_screen._back() # close the picker WITHOUT confirming (stone stays unspent)
	if bag_screen != null:
		bag_screen._back() # close the bag screen; reshow the menu panel
		_call("toggle_menu")
	for i in range(saved_party.size()):
		session.set_party_member(i, saved_party[i])
	runtime.session.remove_item("fire_stone", runtime.get_item_count("fire_stone"))


# Party screen with a crafted Egg in slot 0, its summary panel open (PartyRows'
# pre-hatch status). The egg overlays a real mon instance so every base field the
# row/summary renderers read exists; both are restored afterwards.
func _egg_summary_shot() -> void:
	var runtime := _runtime()
	var session = runtime.session
	var party_screen: Node = null
	if session.party.is_empty():
		_failures.append("%s: the crafted party is empty; no slot for the Egg" % SHOT_EGG_SUMMARY)
		return
	var saved_lead: Dictionary = session.party[0].duplicate(true)
	var egg := _crafted_egg(runtime)
	if egg.is_empty():
		_failures.append("%s: could not craft the party Egg (catalog incomplete)" % SHOT_EGG_SUMMARY)
		return
	session.set_party_member(0, egg)
	_crafted["egg"] = egg.get("egg", {})
	_call("toggle_menu")
	_start_menu()._activate_entry(0) # POKEMON entry; opens the party screen
	party_screen = _start_menu().get_node_or_null("PartyScreen")
	if party_screen == null or not _open_summary(party_screen):
		_failures.append("%s: could not open the Egg summary panel" % SHOT_EGG_SUMMARY)
	else:
		await _capture.call(SHOT_EGG_SUMMARY)
		party_screen._back() # summary -> action
		party_screen._back() # action -> list
	if party_screen != null:
		party_screen._back() # close the party screen; reshow the menu panel
	_call("toggle_menu")
	session.set_party_member(0, saved_lead)


func _crafted_picker_party(runtime) -> Array:
	var worst_name := str(UiRenderFixtures.worst_entry(runtime.catalog.species.values(), "display_name").get("display_name", "Pokemon"))
	var party := []
	for species_id in ["EEVEE", "MAGIKARP"]:
		var entry: Dictionary = runtime.catalog.get_species(species_id)
		if entry.is_empty():
			return []
		var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, 21, Callable(runtime.catalog, "get_move"))
		mon["name"] = worst_name # worst-case row length
		party.append(mon)
	return party


func _crafted_egg(runtime) -> Dictionary:
	var entry: Dictionary = runtime.catalog.get_species(EGG_SPECIES)
	if entry.is_empty():
		return {}
	var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, 5, Callable(runtime.catalog, "get_move"))
	mon["is_egg"] = true
	mon["egg"] = {"display_name": str(entry.get("display_name", EGG_SPECIES)), "is_shiny": false,
		"gender": "female", "steps_to_hatch": 2560}
	return mon


# The party screen's SUMMARY action (id "summary"): confirm -> action panel -> the
# summary action -> summary panel. False when the action is absent (loud upstream).
func _open_summary(party_screen: Node) -> bool:
	party_screen._selected = 0
	party_screen._confirm() # list -> action panel (builds the action entries)
	var actions: Array = party_screen._actions
	for i in range(actions.size()):
		if str((actions[i] as Dictionary).get("id", "")) == "summary":
			party_screen._action_selected = i
			party_screen._confirm() # action -> summary panel
			return true
	return false


func _select_bag_item(bag_screen: Node, item_id: String) -> bool:
	var entries: Array = bag_screen._entries
	for i in range(entries.size()):
		if str((entries[i] as Dictionary).get("item_id", "")) == item_id:
			bag_screen.select_item(i) # restyle seam: absolute-index selection scrolls the visible window
			return true
	return false


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _runtime() -> Node: return _ctx["runtime"]
func _start_menu() -> Node: return _ctx["start_menu"]
