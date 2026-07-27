extends RefCounted

# The breeding / drops / fishing soak band for the playtest bot (Phase 5,
# Workstream L.6 — the bot gains capabilities as phases land). playtest_bot.gd
# is AT its 320 budget, so the band lives in this sibling module (the bot's
# one-owner-per-file rule is untouched; playtest_breed_soak_scenario.gd drives
# both). Invariants: the 7-egg self-trap cap, pasture happiness bounds + shape
# on the ONE shared pasture store (read twice — breeding_runtime's snapshot +
# the raw session key; defense in depth since the store unification), and the
# witnessed drop-economy invariant (never log/hard_stone — the region-seal escape).

const HabitatDrops := preload("res://scripts/domain/habitat_drops.gd")

const EGG_GROUND_CAP := 7 # breeding_runtime's faithful cap


# "" while every Phase 5 pasture + the drop witness stay within bounds.
func check_breeding_invariants(runtime) -> String:
	if runtime.get("breeding_runtime") != null:
		var snapshot: Dictionary = runtime.breeding_runtime.pasture_snapshot()
		for pen_key in snapshot.keys():
			var pasture: Dictionary = snapshot[pen_key]
			var eggs: Variant = pasture.get("eggs", [])
			if eggs is Array and (eggs as Array).size() > EGG_GROUND_CAP:
				return "pen %s holds %d ground eggs (cap %d)" % [str(pen_key), (eggs as Array).size(), EGG_GROUND_CAP]
			var mons: Variant = pasture.get("mons", [])
			if mons is Array:
				for mon_variant in mons:
					if not (mon_variant is Dictionary):
						return "pen %s holds a non-dict pasture mon" % str(pen_key)
					if bool((mon_variant as Dictionary).get("is_egg", false)):
						return "pen %s holds an egg in its mons list" % str(pen_key)
					var problem := _mon_bounds(mon_variant as Dictionary)
					if not problem.is_empty():
						return "pen %s: %s" % [str(pen_key), problem]
	var raw_pastures: Variant = runtime.session.get("pastures")
	if raw_pastures is Dictionary:
		for anchor in (raw_pastures as Dictionary).keys():
			var entry: Variant = (raw_pastures as Dictionary)[anchor]
			if not (entry is Dictionary):
				return "pasture %s is not a dict" % str(anchor)
			var mons: Variant = (entry as Dictionary).get("mons", [])
			if not (mons is Array):
				return "pasture %s mons is not an array" % str(anchor)
			for mon_variant in mons:
				if not (mon_variant is Dictionary):
					return "pasture %s holds a non-dict mon" % str(anchor)
				var problem := _mon_bounds(mon_variant as Dictionary)
				if not problem.is_empty():
					return "pasture %s: %s" % [str(anchor), problem]
	if not HabitatDrops.witness_clean():
		return "the habitat drop table yields log or hard_stone (witness breach)"
	return ""


# Per-iteration pen clock: the wired note_player_step seam (habitat day tick +
# breeding lay/hatch cadence), pure session work, safe at soak depth.
func tick_pen(runtime, steps: int) -> void:
	for _i in range(steps):
		runtime.note_player_step()


# A single shore cast (old rod granted once by the soak); returns "" or the
# hook failure's named reason for the stats ("hooked" / "no_bite" / ...).
func try_fish_cast(runtime, water_tile: Vector2i) -> String:
	var fishing = runtime.get("fishing_runtime")
	if fishing == null or not (fishing as Object).has_method("try_fish"):
		return "no_fishing_runtime"
	var result = (fishing as Object).call("try_fish", water_tile)
	if not (result is Dictionary):
		return "bad_cast_result"
	if bool((result as Dictionary).get("ok", false)):
		return "hooked"
	return str((result as Dictionary).get("reason", "unknown"))


func _mon_bounds(mon: Dictionary) -> String:
	var happiness := int(mon.get("happiness", 70))
	if happiness < 0 or happiness > 255:
		return "%s happiness %d outside [0, 255]" % [str(mon.get("species_id", "?")), happiness]
	if int(mon.get("level", 1)) < 1:
		return "%s has a sub-1 level" % str(mon.get("species_id", "?"))
	return ""
