extends RefCounted

# BagScreen item-use behavior (extracted from bag_screen.gd at the 220 ui
# wall, restyle slice wave 2; the screen keeps thin delegates). POTION heals
# the party-picked member; EVOLUTION STONES confirm through GameRuntime's
# use_stone_on_mon; SLEEPING BAG routes to camping_runtime.rest("bag"). The
# potion id/heal amount mirror bag_screen.gd's frozen consts.

const POTION_ITEM_ID := "potion" # bag_screen.gd POTION_ITEM_ID
const POTION_HEAL_AMOUNT := 20 # bag_screen.gd POTION_HEAL_AMOUNT


static func apply_potion(screen: Control) -> void:
	if screen._party.is_empty() or screen._party_selected >= screen._party.size():
		return
	var mon: Dictionary = (screen._party[screen._party_selected] as Dictionary).duplicate(true)
	if bool(mon.get("is_egg", false)): # eggs_stay_with_you: a healed egg would be a battle-active empty-moveset lead
		screen._message_box.show_message("You keep the Egg with you.", 1.4)
		return
	var max_hp := maxi(1, int(mon.get("max_hp", 1)))
	var current_hp := int(mon.get("current_hp", 0))
	if current_hp >= max_hp:
		screen._message_box.show_message("It would have no effect.", 1.4)
		return
	mon["current_hp"] = mini(max_hp, current_hp + POTION_HEAL_AMOUNT)
	screen._call_context("set_party_member", [screen._party_selected, mon])
	screen._call_context("remove_item", [POTION_ITEM_ID, 1])
	screen._message_box.show_message("Used Potion on %s." % str(mon.get("name", "Pokemon")), 1.6)
	screen._close_party_pick()
	screen._refresh_items()


static func apply_stone(screen: Control) -> void: # confirms through /root/GameRuntime (sleeping-bag convention); picker stays open on no-effect (like Potion), closes on success
	if screen._party_selected >= screen._party.size():
		return
	var runtime := screen.get_node_or_null("/root/GameRuntime")
	var result: Variant = runtime.call("use_stone_on_mon", screen._pending_item, screen._party_selected) if runtime != null and runtime.has_method("use_stone_on_mon") else {}
	var response: Dictionary = result if result is Dictionary else {}
	screen._message_box.show_message(str(response.get("message", "Can't use that here.")), 1.6)
	if bool(response.get("ok", false)):
		screen._close_party_pick()
		screen._refresh_items()


# Sleeping bag (Phase 2): a reusable key item (count never decrements). camping_runtime.rest("bag")
# owns the heal/time/campsite; the screen surfaces the message, resyncs the tint, saves.
static func use_sleeping_bag(screen: Control) -> void:
	var runtime := screen.get_node_or_null("/root/GameRuntime")
	var camping: Variant = runtime.get("camping_runtime") if runtime != null else null
	if camping == null or not camping.has_method("rest"):
		screen._message_box.show_message("Can't use that here.", 1.4)
		return
	var result: Variant = camping.call("rest", "bag")
	var response: Dictionary = result if result is Dictionary else {}
	screen._message_box.show_message("You rested for a while." if str(response.get("message", "")).is_empty() else str(response.get("message", "")), 2.2)
	if bool(response.get("ok", false)) and runtime != null:
		var world := screen.get_node_or_null("/root/Main/World")
		if world != null and world.has_method("set_time_of_day"):
			world.set_time_of_day(int(runtime.get_time_of_day_minutes()))
		runtime.save_game()
