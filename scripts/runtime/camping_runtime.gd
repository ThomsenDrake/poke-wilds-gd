extends RefCounted

# Camping runtime: the rest / heal model and the campsite anchor (spec:
# docs/product-specs/camping-crafting-survival.md). Two faithful rest paths:
#   * SLEEPING BAG (kind "bag", used from the bag): heal every member by 50% of max
#     HP, revive fainted to 50%, NO status cure (wiki status removal is bed / berries
#     / faint-then-bag — the bag revives but leaves live status).
#   * BED (kind "bed", interact facing a placed bed): full party heal + status cure,
#     reviving fainted — reuses session_state.heal_party_full semantics.
# Resting also advances the clock (a night rest lands at 07:00, a day rest passes
# 4h) and ESTABLISHES the campsite anchor the 0.1 overflow-mon relocation and the
# blackout return read (today only reset_for_new_game writes campsite_tile). Also
# owns the campsite-hold accessors moved out of the budget-full game_runtime.

const DayPhase := preload("res://scripts/domain/day_phase.gd")

const REST_BAG := "bag"
const REST_BED := "bed"
const HEAL_FRACTION_BAG := 0.5
const REST_DAY_MINUTES := 240 # a daytime rest passes four hours
const DAY_MINUTES := 1440

var _session = null
var _trace = null


func setup(session_state, trace_logger) -> void:
	_session = session_state
	_trace = trace_logger


# Rests the party by kind ("bag"|"bed"). Heals, advances time, establishes the
# campsite anchor, and traces campsite_established + rested (rested carries kind,
# tile, minutes_advanced, woke_at, healed, revived). Never silent on refusal.
func rest(kind: String) -> Dictionary:
	if kind != REST_BAG and kind != REST_BED:
		return {"ok": false, "kind": kind, "message": "You can't rest like that."}
	if _session.party.is_empty():
		return {"ok": false, "kind": kind, "message": "There is no one to rest."}
	var result: Dictionary = _rest_bed() if kind == REST_BED else _rest_bag()
	var advanced := _advance_for_rest()
	# Resting establishes the campsite anchor the overflow hold + blackout return use.
	_session.campsite_tile = _session.player_tile
	var tile := [_session.player_tile.x, _session.player_tile.y]
	_emit("campsite_established", {"tile": tile, "kind": kind})
	_emit("rested", {"kind": kind, "tile": tile, "minutes_advanced": advanced,
		"woke_at": int(_session.time_of_day_minutes),
		"healed": int(result.get("healed", 0)), "revived": int(result.get("revived", 0))})
	return {"ok": true, "kind": kind, "message": _rest_message(kind),
		"healed": int(result.get("healed", 0)), "revived": int(result.get("revived", 0)),
		"minutes_advanced": advanced, "woke_at": int(_session.time_of_day_minutes)}


# --- Campsite hold (moved from the budget-full game_runtime; it keeps 1-line
# forwarders so the party screen / start menu context callables keep working) ------

func get_campsite_pokemon() -> Array:
	return _session.get_campsite_pokemon()


# Pops the held mon at `index` back into the party (party-screen RETRIEVE caller).
func retrieve_campsite_mon(index: int) -> Dictionary:
	var mon: Dictionary = _session.retrieve_campsite_mon(index)
	if mon.is_empty():
		return mon
	_session.party.append(mon)
	_emit("mon_retrieved", {"species_id": str(mon.get("species_id", "")),
		"name": str(mon.get("name", "")), "level": int(mon.get("level", 1)),
		"campsite": [_session.campsite_tile.x, _session.campsite_tile.y], "party_size": _session.party.size()})
	return mon


# --- Heal model ------------------------------------------------------------------

func _rest_bed() -> Dictionary:
	var revived := 0
	for mon_variant in _session.party:
		if int((mon_variant as Dictionary).get("current_hp", 0)) <= 0:
			revived += 1
	# Full heal + status cure for ALL members, reviving fainted: the existing
	# blackout-heal semantics (HP=max, status="", sleep_turns=0).
	_session.heal_party_full()
	return {"healed": _session.party.size(), "revived": revived}


func _rest_bag() -> Dictionary:
	var healed := 0
	var revived := 0
	for i in range(_session.party.size()):
		var mon: Dictionary = _session.party[i]
		var max_hp := maxi(1, int(mon.get("max_hp", 1)))
		var restore := int(ceili(float(max_hp) * HEAL_FRACTION_BAG))
		if int(mon.get("current_hp", 0)) <= 0:
			mon["current_hp"] = clampi(restore, 1, max_hp) # revive fainted to 50%
			revived += 1
		else:
			mon["current_hp"] = mini(max_hp, int(mon.get("current_hp", 0)) + restore)
		# Faithful: the bag heals HP only — status is NOT cured. The indoor
		# effectiveness bonus is deferred (needs the Phase 1 enclosure flood-fill,
		# tech-debt-tracker.md:13); the bag is a flat 50% with a documented deviation.
		healed += 1
		_session.party[i] = mon
	return {"healed": healed, "revived": revived}


# Night rest advances to the next 07:00 (WAKE_MINUTES, inside the dawn band); a day
# rest passes REST_DAY_MINUTES. The wiki gives only "time advances; sleeping through
# the night lands you in morning", so the exact amounts are documented port constants.
func _advance_for_rest() -> int:
	var minutes := int(_session.time_of_day_minutes)
	var advanced := posmod(DayPhase.WAKE_MINUTES - minutes, DAY_MINUTES) if DayPhase.is_night(minutes) else REST_DAY_MINUTES
	_session.advance_time(advanced)
	return advanced


func _rest_message(kind: String) -> String:
	return "You slept in the bed and feel fully restored." if kind == REST_BED else "You rested in the sleeping bag."


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "CampingRuntime", payload)
