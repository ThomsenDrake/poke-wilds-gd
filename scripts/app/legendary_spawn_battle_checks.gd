extends RefCounted

# Legendary spawn BATTLE checks (the legendary-dungeon slice), extracted from
# legendary_spawn_scenario.gd at the app 220 budget wall (check_architecture.gd
# SCRIPT_LIMITS; the legendary_spawn_checks.gd precedent). The scenario keeps the
# anchor/exclusion FLOW + the driver; this owns the two chamber-battle proofs:
#   (1) whiteout_proof — the chamber legendary (MEWTWO's dungeon): warp in -> the
#       provoked chase-catch +3 (:284) -> the battle-start trace (dungeon_id on the
#       payload) -> a white-out dumps the player to the campsite OUTSIDE the dungeon,
#       the whittle (hp/stages) persists across the re-entry re-stamp, and the rematch
#       carries the PERSISTED +3 + a second legendary_encounter. The :280 no-buff
#       witness rides the KO case's FIRST engagement (stages 0).
#   (2) ko_proof — REGIGIGAS (both-outcomes-permanent; a tablet Regi's KO rides the
#       re-stand valve into session.legendary_kos instead): the five-tablet SEAL
#       refuses first (seal_refusal_pin), then overworld_mon_despawned{ko}, the
#       removal key rides legendary_removals, a second attempt finds NO target, the
#       re-entry re-stamp suppresses, an untouched dungeon still stamps, and the
#       payload round-trip keeps it gone. Leaves the session (and the lingering
#       save) OVERWORLD-clean for the harness tail.
# Battles ride the DIRECT seam (the scenario holds the set_battle latch); failures
# append to the caller's array (the curated_exclusion_pin precedent). NO rng here —
# the battle path consumes the runtime's pinned streams exactly as the live game does.

const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table)
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd")
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const DungeonMaps := DungeonRuntime.DungeonMaps

const PROVOKED_ATTACK_STAGES := 3 # mirrors OverworldMons.PROVOKED_ATTACK_STAGES (:284)
const WHITEOUT_ENEMY_HP := 9999 # the white-out subject survives one hit so the persisted damage is observable


static func whiteout_proof(runtime, species_id: String, player, world, music_router, runner, failures: Array) -> void:
	var mons = runtime.overworld_mons_runtime
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id) # the warp tile SITS ON the anchor
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "whiteout: the warp into %s refused" % dungeon_id, failures): return
	var anywhere_tile := DungeonMaps.spawn_tile_for(dungeon_id) # walkable S cell, deliberately not a classic ',' encounter tile
	var anywhere_logic: Dictionary = runtime._world_gen.get_tile_logic(anywhere_tile)
	LegendarySpawnChecks.ensure(bool(anywhere_logic.get("walkable", false)) and str(anywhere_logic.get("encounter_token", "")) == "", "whiteout: ANYWHERE control tile is not a walkable non-encounter cell", failures)
	var anywhere_scope: Dictionary = runtime.dungeon_runtime.encounter_scope_for(anywhere_tile, "ROCK")
	var authored_scope: Dictionary = DungeonMaps.encounter_scope_for(dungeon_id)
	LegendarySpawnChecks.ensure(str(anywhere_scope.get("token", "")) == dungeon_id and not (anywhere_scope.get("extra_ids", []) as Array).is_empty() and anywhere_scope.get("extra_ids", []) == authored_scope.get("extra_ids", []), "whiteout: ANYWHERE dungeon cell escaped the curated scope", failures)
	var entity: Dictionary = mons._entities.get("legendary_%s" % dungeon_id, {})
	if not LegendarySpawnChecks.ensure(not entity.is_empty(), "whiteout: no chamber entity for %s" % species_id, failures): return
	var tile: Vector2i = entity.get("tile", Vector2i.MAX)
	mons._force_battle(entity, true) # the forced-AGGRESSIVE chase-catch, exactly like a Phase-6 guardian
	var cursor: int = runner.trace_log_line_count()
	var battle_mon: Dictionary = _take_payload(runtime, species_id, cursor, PROVOKED_ATTACK_STAGES, "whiteout", player, world, runner, failures)
	if battle_mon.is_empty(): return
	LegendarySpawnChecks.ensure(str(battle_mon.get("dungeon_id", "")) == dungeon_id, "whiteout: the pending payload's dungeon_id %s != %s" % [str(battle_mon.get("dungeon_id", "")), dungeon_id], failures)
	music_router.play_battle_track(str(battle_mon.get("battle_kind", "wild"))) # a verbatim MIMIC of the main.gd:92 seam — kind plumbing only (headless never plays audio, miss-002)
	var music_pin := LegendarySpawnChecks.music_seam_pin(runner, cursor) # music_track_selected{legendary} witness + the main.gd:92 consumer grep pin (the live bridge is latch-bypassed)
	LegendarySpawnChecks.ensure(music_pin == "", music_pin, failures)
	battle_mon["max_hp"] = WHITEOUT_ENEMY_HP; battle_mon["current_hp"] = WHITEOUT_ENEMY_HP # survives the one damaging hit so the persisted damage is observable
	runtime.start_wild_battle(battle_mon)
	runtime.battle_runtime._player_mon["max_hp"] = WHITEOUT_ENEMY_HP; runtime.battle_runtime._player_mon["current_hp"] = WHITEOUT_ENEMY_HP # unkillable lead: the damaging move lands whatever the ring-band level/speed
	runtime.perform_battle_move(LegendarySpawnChecks.damaging_move_index(runtime.battle_runtime._player_mon))
	for mon in runtime.session.party: mon["current_hp"] = 0 # zero the WHOLE party: the faint handler finds no healthy successor -> defeat (wild_battle's single-mon precedent, generalized)
	runtime.battle_runtime._player_mon["current_hp"] = 0
	var defeat: Dictionary = runtime.perform_battle_move(LegendarySpawnChecks.damaging_move_index(runtime.battle_runtime._player_mon))
	if not LegendarySpawnChecks.ensure(str(defeat.get("outcome", "")) == "defeat", "whiteout: the defeat path reached outcome %s" % str(defeat.get("outcome", "")), failures): return
	LegendarySpawnChecks.ensure(runtime.session.player_tile == runtime.session.campsite_tile and str(runtime.session.active_area) == "", "whiteout: the defeat did not dump the player to the campsite OUTSIDE the dungeon (tile %s, area %s)" % [str(runtime.session.player_tile), str(runtime.session.active_area)], failures)
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "whiteout: the re-entry warp refused", failures): return
	var standing: Dictionary = mons._entities.get("legendary_%s" % dungeon_id, {})
	if not LegendarySpawnChecks.ensure(not standing.is_empty() and str(standing.get("kind", "")) == "legendary", "whiteout: the white-out REMOVED the legendary (:288 violation)", failures): return
	LegendarySpawnChecks.ensure(int(standing.get("current_hp", 0)) > 0 and int(standing.get("current_hp", WHITEOUT_ENEMY_HP)) < WHITEOUT_ENEMY_HP, "whiteout: the enemy's damage did not persist across the re-entry (hp %d)" % int(standing.get("current_hp", 0)), failures)
	LegendarySpawnChecks.ensure(str(standing.get("state", "")) == "idle", "whiteout: the surviving entity did not drop to idle", failures)
	standing["current_hp"] = 1 # sentinel: the rematch payload must consume the standing entity's whittled HP
	var atk: Dictionary = mons.attack_entity(tile)
	if not LegendarySpawnChecks.ensure(bool(atk.get("ok", false)), "whiteout: the surviving legendary refused a second battle (%s)" % str(atk.get("reason", "")), failures): return
	var cursor2: int = runner.trace_log_line_count()
	var retry: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	LegendarySpawnChecks.ensure(int(retry.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "whiteout: the provoked +3 did NOT persist across the white-out (:284 stat persistence; the :280 no-buff witness rides the ko case's fresh attack)", failures)
	LegendarySpawnChecks.ensure(int(retry.get("current_hp", 0)) == 1 and int(retry.get("max_hp", 1)) > 1, "whiteout: the rematch payload did not preserve the standing HP sentinel (hp %d/%d)" % [int(retry.get("current_hp", 0)), int(retry.get("max_hp", 0))], failures)
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("legendary_encounter", cursor2, {"species_id": species_id, "battle_kind": "legendary", "dungeon_id": dungeon_id}), "whiteout: no second legendary_encounter on the rematch", failures)
	runtime.start_wild_battle(retry)
	LegendarySpawnChecks.ensure(str(runtime.run_from_battle().get("outcome", "")) == "escaped", "whiteout: the rematch escape failed", failures)
	runtime.dungeon_runtime.exit_dungeon() # hand the KO proof an OVERWORLD session (the escape leaves the player in the dungeon)


static func ko_proof(runtime, species_id: String, anchored: Array, player, world, runner, failures: Array) -> void:
	var mons = runtime.overworld_mons_runtime
	var dungeon_id := DungeonMaps.dungeon_for_species(species_id)
	var warp: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), species_id)
	if not LegendarySpawnChecks.ensure(warp != LegendaryPlacement.NO_ANCHOR, "ko: %s resolved NO_ANCHOR" % species_id, failures): return
	var seal := LegendarySpawnChecks.seal_refusal_pin(runtime, dungeon_id, warp, runner) # leaves the session INSIDE the dungeon on pass
	if not LegendarySpawnChecks.ensure(seal == "", seal, failures): return
	var id := "legendary_%s" % dungeon_id
	var entity_ko: Dictionary = mons._entities.get(id, {})
	if not LegendarySpawnChecks.ensure(not entity_ko.is_empty(), "ko: no chamber entity for %s after the seal opened" % species_id, failures): return
	var tile: Vector2i = entity_ko.get("tile", Vector2i.MAX); var anchor: Vector2i = entity_ko.get("anchor", tile) # removals key off `anchor` (the ENTRANCE anchor — world-anchored; slice 3)
	var atk: Dictionary = mons.attack_entity(tile)
	if not LegendarySpawnChecks.ensure(bool(atk.get("ok", false)), "ko: attack on %s refused (%s)" % [species_id, str(atk.get("reason", ""))], failures): return
	var cursor: int = runner.trace_log_line_count()
	var battle_mon: Dictionary = _take_payload(runtime, species_id, cursor, 0, "ko", player, world, runner, failures)
	if battle_mon.is_empty(): return
	battle_mon["current_hp"] = 1 # any damaging hit KOs
	runtime.start_wild_battle(battle_mon)
	runtime.battle_runtime._player_mon["max_hp"] = WHITEOUT_ENEMY_HP; runtime.battle_runtime._player_mon["current_hp"] = WHITEOUT_ENEMY_HP # unkillable lead: victory lands whatever the ring-band level/speed order
	var victory: Dictionary = runtime.perform_battle_move(LegendarySpawnChecks.damaging_move_index(runtime.battle_runtime._player_mon))
	if not LegendarySpawnChecks.ensure(str(victory.get("outcome", "")) == "victory", "ko: outcome %s != victory" % str(victory.get("outcome", "")), failures): return
	LegendarySpawnChecks.ensure(runner.trace_log_has_since("overworld_mon_despawned", cursor, {"species_id": species_id, "reason": "ko"}), "ko: no overworld_mon_despawned{reason:ko}", failures)
	LegendarySpawnChecks.ensure((runtime.session.legendary_removals as Array).has(LegendaryPlacement.removal_key(anchor, species_id)), "ko: the removal key %s never reached session.legendary_removals (%s)" % [LegendaryPlacement.removal_key(anchor, species_id), str(runtime.session.legendary_removals)], failures)
	var roundtrip := LegendarySpawnChecks.roundtrip_removal(runtime, species_id, anchored) # the save marshalling round-trip (to_payload/apply_into into a fresh session)
	LegendarySpawnChecks.ensure(roundtrip == "", roundtrip, failures)
	var again: Dictionary = mons.attack_entity(tile) # the second encounter attempt finds it gone
	LegendarySpawnChecks.ensure(str(again.get("reason", "")) == "no_target", "ko: the KO'd legendary is still attackable (%s)" % str(again.get("reason", "")), failures)
	runtime.dungeon_runtime.exit_dungeon() # the re-entry IS the re-stamp: suppression re-derives off the persistent removal set
	if not LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(warp), "ko: the post-KO re-entry refused", failures): return
	LegendarySpawnChecks.ensure(not mons._entities.has(id), "ko: the re-entry re-created the KO'd legendary (suppression not re-derived)", failures)
	runtime.dungeon_runtime.exit_dungeon() # ...then an untouched dungeon still stamps its chamber entity
	var other := str(anchored[1])
	LegendarySpawnChecks.ensure(runtime.dungeon_runtime.try_enter_at(DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), other)), "ko: the untouched %s dungeon refused entry" % other, failures)
	LegendarySpawnChecks.ensure(mons._entities.has("legendary_%s" % DungeonMaps.dungeon_for_species(other)), "ko: the re-stamp dropped the untouched %s" % other, failures)
	runtime.dungeon_runtime.exit_dungeon(); runtime.save_game() # leave the session (and the lingering save) OVERWORLD-clean for the harness tail


# The pending-seam take + the legendary_encounter payload (species/kind/ring/stages). {} on any red, so the caller bails.
static func _take_payload(runtime, species_id: String, cursor: int, stages: int, label: String, player, world, runner, failures: Array) -> Dictionary:
	var battle_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if not LegendarySpawnChecks.ensure(str(battle_mon.get("species_id", "")) == species_id, "%s: the seam returned %s, expected %s" % [label, str(battle_mon.get("species_id", "")), species_id], failures): return {}
	var ok := LegendarySpawnChecks.ensure(str(battle_mon.get("battle_kind", "")) == "legendary", "%s: battle_kind %s != legendary" % [label, str(battle_mon.get("battle_kind", ""))], failures)
	ok = LegendarySpawnChecks.ensure(int(battle_mon.get("attack_stages", 0)) == stages, "%s: attack_stages %d != %d" % [label, int(battle_mon.get("attack_stages", 0)), stages], failures) and ok
	ok = LegendarySpawnChecks.ensure(int(battle_mon.get("ring", 0)) >= LegendaryPlacement.LEGENDARY_RING_MIN, "%s: the encounter's ring %d < %d" % [label, int(battle_mon.get("ring", 0)), LegendaryPlacement.LEGENDARY_RING_MIN], failures) and ok
	ok = LegendarySpawnChecks.ensure(runner.trace_log_has_since("legendary_encounter", cursor, {"species_id": species_id, "battle_kind": "legendary"}), "%s: no legendary_encounter{battle_kind:legendary} at battle start" % label, failures) and ok
	return battle_mon if ok else {}
