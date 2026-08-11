extends RefCounted

# Legendary-dungeon CHECKS, extracted from legendary_dungeon_scenario.gd at the app-220
# budget wall (check_architecture.gd SCRIPT_LIMITS; the legendary_spawn_checks.gd
# precedent). The scenario keeps the driver + the entrance/round-trip/suppression lanes;
# this owns the five hardened proofs:
#   (1) catch_persists_proof — (d)+(f): catch REGIROCK through the DIRECT seam (the
#       catch_rate catalog patch + 1hp/SLP force catch_value >= 255 -> p == 1.0, NO rng
#       dependence), tablet_claimed fires EXACTLY once (the once-per-save grant), the
#       removal key rides legendary_removals, and two re-entries find the chamber empty
#       forever;
#   (2) ko_valve_proof — (e): KO REGICE -> NO tablet (KO grants nothing), the key logs to
#       session.legendary_kos at the KO's total_steps (NEVER legendary_removals), re-entry
#       suppresses while the cooldown runs, and after total_steps advances
#       REGI_RESTAND_STEPS (synthetically) the chamber re-stands FRESH (the KO mark lapses,
#       the whittle erases). Leaves the session INSIDE the re-stood dungeon for the
#       suppression/refusal/roundtrip lanes;
#   (3) seal_ladder_proof — (g): the Regigigas warp refuses at 0..4 held tablets with
#       dungeon_entry_refused{dungeon_id, missing} (the missing list shrinks rung by rung),
#       opens at all five, and NEVER consumes them. Runs LAST (it strips + re-grants the
#       five tablets, so the catch lane's tablet asserts run before it);
#   (4) in_dungeon_refusals — (i): teleport/fly trace field_move_refused{reason:
#       in_dungeon}, build traces structure_refused{reason: in_dungeon}, the harvest
#       path (cut/dig/smash share the one in_dungeon gate) refuses message-only ("The cave
#       walls resist the move." — that route's refusals never trace, by design), and the
#       camping rest refuses message-only with the campsite anchor unmoved (a dungeon-local
#       campsite_tile would strand the blackout return in the overworld);
#   (5) save_roundtrip_proof — (j): legendary_kos + active_area survive to_save_payload ->
#       apply_loaded_state into a FRESH session (the roundtrip_removal precedent).
# Battles ride the DIRECT seam (the scenario holds the set_battle latch). NO rng here —
# the battle path consumes the runtime's pinned streams exactly as the live game does.

const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table)
const SessionState := preload("res://scripts/runtime/session_state.gd")
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd") # the shared ensure/damaging_move_index home (app -> app; the layer table)
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const DungeonMaps := DungeonRuntime.DungeonMaps
const DungeonLayouts := DungeonRuntime.DungeonLayouts

const UNKILLABLE_HP := 9999 # the lead survives any counter so the forced outcome always lands


# (d)+(f): the catch -> tablet -> gone-forever proof. "" payloads on failure ride the caller's array.
static func catch_persists_proof(runtime, species_id: String, player, world, runner, failures: Array) -> bool:
	var start: int = failures.size()
	var mons = runtime.overworld_mons_runtime; var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id)
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "catch: the warp into %s refused" % dungeon_id, failures): return false
	var id := "legendary_%s" % dungeon_id; var entity: Dictionary = mons._entities.get(id, {})
	if not LegendarySpawnChecks.ensure(not entity.is_empty(), "catch: no chamber entity for %s" % species_id, failures): return false
	var tile: Vector2i = entity.get("tile", Vector2i.MAX); var key := LegendaryPlacement.removal_key(entity.get("anchor", tile), species_id)
	if not LegendarySpawnChecks.ensure(bool(mons.attack_entity(tile).get("ok", false)), "catch: the attack on %s refused" % species_id, failures): return false
	var cursor: int = runner.trace_log_line_count()
	var battle_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if not LegendarySpawnChecks.ensure(str(battle_mon.get("species_id", "")) == species_id, "catch: the pending seam returned %s, expected %s" % [str(battle_mon.get("species_id", "")), species_id], failures): return false
	var tablet := str(DungeonLayouts.TABLET_FOR_SPECIES.get(species_id, ""))
	# The guaranteed catch: patch the species' catalog catch_rate to 255 and set 1hp/SLP on
	# the pending payload, so catch_value >= 255 -> probability 1.0 (battle_rules
	# ._catch_context) — the outcome is deterministic REGARDLESS of the roll.
	var species_entry: Dictionary = runtime.catalog.species[species_id]
	var saved_rate: int = int(species_entry.get("catch_rate", 45))
	species_entry["catch_rate"] = 255
	battle_mon["current_hp"] = 1; battle_mon["status"] = "SLP"
	runtime.session.add_item("poke_ball", 1) # battle_runtime.use_pokeball consumes one BALL_ID
	runtime.start_wild_battle(battle_mon)
	var result: Dictionary = runtime.use_pokeball()
	species_entry["catch_rate"] = saved_rate
	if not LegendarySpawnChecks.ensure(str(result.get("outcome", "")).begins_with("caught"), "catch: outcome %s != caught*" % str(result.get("outcome", "")), failures): return false
	LegendarySpawnChecks.ensure(_trace_count_since(runner, "tablet_claimed", cursor, {"species_id": species_id, "item_id": tablet}) == 1, "catch: tablet_claimed did not fire EXACTLY once for %s/%s" % [species_id, tablet], failures)
	LegendarySpawnChecks.ensure(tablet != "" and runtime.session.get_item_count(tablet) == 1, "catch: the bag holds %d %s (the once-per-save grant)" % [runtime.session.get_item_count(tablet), tablet], failures)
	LegendarySpawnChecks.ensure((runtime.session.legendary_removals as Array).has(key), "catch: the removal key %s never reached legendary_removals" % key, failures)
	LegendarySpawnChecks.ensure(str(mons.attack_entity(tile).get("reason", "")) == "no_target", "catch: the caught legendary stayed attackable", failures)
	runtime.dungeon_runtime.exit_dungeon()
	for _i in range(2): # empty FOREVER: two independent re-entries re-derive suppression off the persistent removal set
		if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "catch: a post-catch re-entry refused", failures): return false
		LegendarySpawnChecks.ensure(not mons._entities.has(id), "catch: the chamber re-stamped after the catch (suppression not re-derived)", failures)
		runtime.dungeon_runtime.exit_dungeon()
	return failures.size() == start


# (e): the tablet-Regi KO re-stand valve. Leaves the session INSIDE the re-stood dungeon.
static func ko_valve_proof(runtime, species_id: String, player, world, runner, failures: Array) -> bool:
	var start: int = failures.size()
	var mons = runtime.overworld_mons_runtime; var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id)
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "ko: the warp into %s refused" % dungeon_id, failures): return false
	var id := "legendary_%s" % dungeon_id; var entity: Dictionary = mons._entities.get(id, {})
	if not LegendarySpawnChecks.ensure(not entity.is_empty(), "ko: no chamber entity for %s" % species_id, failures): return false
	var tile: Vector2i = entity.get("tile", Vector2i.MAX); var key := LegendaryPlacement.removal_key(entity.get("anchor", tile), species_id)
	if not LegendarySpawnChecks.ensure(bool(mons.attack_entity(tile).get("ok", false)), "ko: the attack on %s refused" % species_id, failures): return false
	var cursor: int = runner.trace_log_line_count()
	var battle_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if not LegendarySpawnChecks.ensure(str(battle_mon.get("species_id", "")) == species_id, "ko: the pending seam returned %s, expected %s" % [str(battle_mon.get("species_id", "")), species_id], failures): return false
	battle_mon["current_hp"] = 1 # any damaging hit KOs
	var started: Dictionary = runtime.start_wild_battle(battle_mon)
	if not LegendarySpawnChecks.ensure(runtime.battle_runtime._active, "ko: start_wild_battle did not activate (%s)" % str(started), failures): return false
	runtime.battle_runtime._player_mon["max_hp"] = UNKILLABLE_HP; runtime.battle_runtime._player_mon["current_hp"] = UNKILLABLE_HP
	var steps_at_ko: int = int(runtime.session.total_steps)
	# Accuracy-pinned retry: Stone Edge (80 acc) CAN roll a miss at this seed-locked rng
	# position — loop until the round FINISHES (the unkillable lead never loses; PP covers it).
	var victory: Dictionary = {}
	for _turn in range(12):
		victory = runtime.perform_battle_move(LegendarySpawnChecks.damaging_move_index(runtime.battle_runtime._player_mon))
		if bool(victory.get("finished", false)):
			break
	if not LegendarySpawnChecks.ensure(str(victory.get("outcome", "")) == "victory", "ko: outcome %s != victory (%s)" % [str(victory.get("outcome", "")), str(victory.get("message", victory))], failures): return false
	var tablet := str(DungeonLayouts.TABLET_FOR_SPECIES.get(species_id, ""))
	LegendarySpawnChecks.ensure(_trace_count_since(runner, "tablet_claimed", cursor, {"species_id": species_id}) == 0, "ko: a KO granted a tablet (the tablets are catch-only)", failures)
	LegendarySpawnChecks.ensure(runtime.session.get_item_count(tablet) == 0, "ko: the bag holds %s after a KO" % tablet, failures)
	LegendarySpawnChecks.ensure(int((runtime.session.legendary_kos as Dictionary).get(key, -1)) == steps_at_ko, "ko: legendary_kos[%s] = %s, expected the KO's total_steps %d" % [key, str((runtime.session.legendary_kos as Dictionary).get(key, "?")), steps_at_ko], failures)
	LegendarySpawnChecks.ensure(not (runtime.session.legendary_removals as Array).has(key), "ko: a tablet Regi's KO reached legendary_removals (the valve rides legendary_kos ONLY)", failures)
	LegendarySpawnChecks.ensure(not mons._entities.has(id) and mons.has_removed_mark(id), "ko: the KO'd Regi lost its session KO mark", failures)
	runtime.dungeon_runtime.exit_dungeon()
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "ko: the in-cooldown re-entry refused", failures): return false
	LegendarySpawnChecks.ensure(not mons._entities.has(id), "ko: the KO'd Regi re-stamped INSIDE the cooldown (the valve must suppress)", failures)
	runtime.session.total_steps += LegendaryPlacement.REGI_RESTAND_STEPS # the synthetic advance: the cooldown lapses
	runtime.dungeon_runtime.exit_dungeon()
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "ko: the post-cooldown re-entry refused", failures): return false
	var stood: Dictionary = mons._entities.get(id, {})
	LegendarySpawnChecks.ensure(not stood.is_empty(), "ko: the chamber did not re-stand after REGI_RESTAND_STEPS", failures)
	LegendarySpawnChecks.ensure(int(stood.get("current_hp", 1)) == 0 and int(stood.get("attack_stages", 1)) == 0, "ko: the re-stood Regi carried whittled hp/stages (a lapsed KO re-stands FRESH)", failures)
	return failures.size() == start # the caller's suppression/refusal/roundtrip lanes ride this open dungeon


# (g): the Regigigas five-tablet seal ladder. Runs LAST (strips + re-grants every tablet).
static func seal_ladder_proof(runtime, runner, failures: Array) -> bool:
	var start: int = failures.size()
	# The prior lanes leave the session INSIDE the re-stood KO dungeon; try_enter_at refuses
	# in_dungeon WITHOUT tracing, so the ladder must start from the overworld.
	if runtime.dungeon_runtime.in_dungeon():
		runtime.dungeon_runtime.exit_dungeon()
	var tablets: Array = []
	for tablet in DungeonLayouts.TABLET_FOR_SPECIES.values(): tablets.append(str(tablet))
	for tablet in tablets: # a clean ladder: start from ZERO held (the catch lane's rock_tablet goes too)
		while runtime.session.get_item_count(tablet) > 0:
			runtime.session.consume_item(tablet, 1)
	var warp: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), "REGIGIGAS")
	if not LegendarySpawnChecks.ensure(warp != LegendaryPlacement.NO_ANCHOR, "seal: REGIGIGAS resolved NO_ANCHOR", failures): return false
	for held in range(DungeonLayouts.TABLET_FOR_SPECIES.size()): # 0..4 tablets: every rung refuses
		var cursor: int = runner.trace_log_line_count()
		LegendarySpawnChecks.ensure(not runtime.dungeon_runtime.try_enter_at(warp), "seal: the warp opened with only %d tablets held" % held, failures)
		var missing: Array = tablets.slice(held); missing.sort()
		LegendarySpawnChecks.ensure(runner.trace_log_has_since("dungeon_entry_refused", cursor, {"dungeon_id": DungeonLayouts.SEAL_DUNGEON, "missing": missing}), "seal: the refusal at %d held missed its missing list %s" % [held, str(missing)], failures)
		LegendarySpawnChecks.ensure(str(runtime.session.active_area) == "", "seal: a refusal still set active_area", failures)
		runtime.session.add_item(str(tablets[held]), 1)
	var cursor: int = runner.trace_log_line_count()
	LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "seal: the five-tablet bag refused entry", failures)
	LegendarySpawnChecks.ensure(not runner.trace_log_has_since("dungeon_entry_refused", cursor), "seal: the opened entry still traced a refusal", failures)
	for tablet in tablets:
		LegendarySpawnChecks.ensure(runtime.session.get_item_count(tablet) == 1, "seal: entry CONSUMED %s (the seal reads the bag, never takes)" % tablet, failures)
	runtime.dungeon_runtime.exit_dungeon()
	return failures.size() == start


# (i): the in-dungeon field-action refusals. Runs inside the KO lane's open dungeon.
static func in_dungeon_refusals(runtime, runner, failures: Array) -> bool:
	var start: int = failures.size()
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.in_dungeon(), "refusals: the lane must run inside a dungeon", failures): return false
	var tile: Vector2i = runtime.session.player_tile
	var cursor: int = runner.trace_log_line_count()
	var teleport: Dictionary = runtime.field_move_runtime.use_teleport()
	LegendarySpawnChecks.ensure(str(teleport.get("reason", "")) == "in_dungeon", "refusals: teleport returned %s" % str(teleport), failures)
	var fly: Dictionary = runtime.field_move_runtime.use_fly(Vector2i.ZERO)
	LegendarySpawnChecks.ensure(str(fly.get("reason", "")) == "in_dungeon", "refusals: fly returned %s" % str(fly), failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "teleport", "reason": "in_dungeon"}), "refusals: no field_move_refused{teleport, in_dungeon} trace", failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "fly", "reason": "in_dungeon"}), "refusals: no field_move_refused{fly, in_dungeon} trace", failures)
	# dig/cut/smash share harvest_runtime's ONE in_dungeon gate (message-only by design —
	# "this route's refusals never trace", harvest_runtime.gd:39), so this call covers dig.
	var harvest: Dictionary = runtime.harvest_runtime.harvest_tile(tile, {})
	LegendarySpawnChecks.ensure(not bool(harvest.get("ok", true)) and str(harvest.get("message", "")) == "The cave walls resist the move.", "refusals: harvest/dig returned %s" % str(harvest), failures)
	var build: Dictionary = runtime.build_runtime.try_place(tile, "wall", {})
	LegendarySpawnChecks.ensure(str(build.get("reason", "")) == "in_dungeon", "refusals: build returned %s" % str(build), failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("structure_refused", cursor, {"structure_id": "wall", "reason": "in_dungeon"}), "refusals: no structure_refused{wall, in_dungeon} trace", failures)
	var campsite_before: Vector2i = runtime.session.campsite_tile
	var rest: Dictionary = runtime.camping_runtime.rest("bag") # message-only grammar (the harvest precedent: camping refusals never trace)
	LegendarySpawnChecks.ensure(not bool(rest.get("ok", true)) and str(rest.get("reason", "")) == "in_dungeon", "refusals: camping rest returned %s" % str(rest), failures)
	LegendarySpawnChecks.ensure(runtime.session.campsite_tile == campsite_before and runtime.session.campsite_tile != tile, "refusals: an in-dungeon rest moved the campsite anchor to %s" % str(runtime.session.campsite_tile), failures)
	return failures.size() == start


# (j): legendary_kos + active_area survive the save marshalling round-trip into a FRESH session.
static func save_roundtrip_proof(runtime, species_id: String, failures: Array) -> bool:
	var start: int = failures.size()
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	if not LegendarySpawnChecks.ensure(str(runtime.session.active_area) == dungeon_id, "roundtrip: the lane must run inside %s (active_area '%s')" % [dungeon_id, str(runtime.session.active_area)], failures): return false
	var payload: Dictionary = runtime.session.to_save_payload({}, {})
	var fresh = SessionState.new()
	fresh.apply_loaded_state(payload, runtime.session.get_party_snapshot())
	LegendarySpawnChecks.ensure(str(fresh.active_area) == dungeon_id, "roundtrip: active_area lost in marshalling (got '%s')" % str(fresh.active_area), failures)
	var key := LegendaryPlacement.removal_key(DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id), species_id)
	LegendarySpawnChecks.ensure(int((fresh.legendary_kos as Dictionary).get(key, -1)) == int((runtime.session.legendary_kos as Dictionary).get(key, -2)), "roundtrip: legendary_kos lost the %s mark (%s -> %s)" % [species_id, str(runtime.session.legendary_kos), str(fresh.legendary_kos)], failures)
	return failures.size() == start


# Counts matching trace events since `cursor` (the "exactly once"/"never" proofs; the runner
# only exposes a boolean has_since). A {} payload_match matches every emission.
static func _trace_count_since(runner, event_name: String, from_line: int, payload_match: Dictionary) -> int:
	var count := 0
	var lines: PackedStringArray = runner._trace_log_lines()
	for i in range(from_line, lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if not (parsed is Dictionary) or str(parsed.get("event", "")) != event_name:
			continue
		var payload: Dictionary = parsed.get("payload", {}) if parsed.get("payload", {}) is Dictionary else {}
		var matches := true
		for key in payload_match:
			if str(payload.get(key, "")) != str(payload_match[key]):
				matches = false
		if matches:
			count += 1
	return count
