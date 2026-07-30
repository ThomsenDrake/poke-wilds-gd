extends RefCounted

# The Phase-6 ENTITY action band for the playtest bot: steal-egg / provoke-Alpha /
# charm-recruit / flee-despawn loops. playtest_bot.gd is AT its 320 budget, so the band
# lives in this sibling module (the playtest_bot_breeding.gd precedent; the bot's one-
# owner-per-file rule is untouched). playtest_entity_soak_scenario.gd drives both. The
# bands act through overworld_mons_runtime's public action seams (egg_take /
# attack_entity / interact) + the wired step clock; store-level hygiene (the pending
# seam, despawn bounds, the player tile) is audited here — the sprite budget + y-sort
# NaN checks need the scene tree, so they ride the scenario.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")

const ENGAGE_RADIUS := 14 # tiles: a band scans this Chebyshev window around the player


# One soak tick: pick a band at random, engage the nearest eligible entity through the
# public seam, then advance the wired step clock (chase/flee/despawn all ride it).
func iterate(runtime, mons, player, world, runner, band_rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var roll := band_rng.randi_range(0, 3)
	var target: Dictionary = {}
	match roll: # whole-store scans (the stand teleports in): a 14-tile band starves every band once roam timelines shift, and a never-firing band must be LOUD, never accidentally quiet
		0: target = _nearest(mons, player, "kind", "egg", 9999)
		1: target = _nearest(mons, player, "disposition", OverworldMons.DISPOSITION_AGGRESSIVE, 9999)
		2: target = _nearest(mons, player, "disposition", OverworldMons.DISPOSITION_FRIENDLY, 9999)
		3: target = _nearest(mons, player, "disposition", OverworldMons.DISPOSITION_TIMID, 9999)
	if target.is_empty():
		stats["starved"] = int(stats.get("starved", 0)) + 1
	else:
		stats["engaged"] = int(stats.get("engaged", 0)) + 1
		match roll:
			0: _steal_egg(runtime, mons, target, stats)
			1: _provoke_alpha(mons, player, world, runner, runtime, target, stats)
			2: _charm_recruit(mons, player, world, runner, runtime, target, stats)
			3: _startle_flee(mons, player, world, runner, runtime, target, stats)
	runtime.note_player_step()
	mons.take_pending_encounter(); mons._pending_id = "" # the step clock ITSELF arms seams (chase-catch :284, guardian spot): the soak never battles, so disarm EVERY tick — and clear the dangling id no battle outcome will (store_clean reads both)


# The soak never battles: a provoked Alpha arms the forced-battle seam, so the band
# consumes it immediately (the soak's contract is that the seam is NEVER left armed).
func _provoke_alpha(mons, player, world, runner, runtime, target: Dictionary, stats: Dictionary) -> void:
	stats["alpha_attempts"] = int(stats.get("alpha_attempts", 0)) + 1
	if not _stand_adjacent(mons, player, world, runner, runtime, target):
		return
	mons.attack_entity(target["tile"])
	if not mons.take_pending_encounter().is_empty():
		stats["alpha_provoked"] = int(stats.get("alpha_provoked", 0)) + 1


func _charm_recruit(mons, player, world, runner, runtime, target: Dictionary, stats: Dictionary) -> void:
	stats["recruit_attempts"] = int(stats.get("recruit_attempts", 0)) + 1
	if not _stand_adjacent(mons, player, world, runner, runtime, target):
		return
	var result: Dictionary = mons.interact(target["tile"])
	if bool(result.get("ok", false)):
		stats["recruits"] = int(stats.get("recruits", 0)) + 1
		if runtime.session.party.size() > 5: # keep the party under the 6-cap so egg takes stay legal
			runtime.session.party.remove_at(runtime.session.party.size() - 1)


# The flee itself fires on the NEXT step clock (step_triggers turns an adjacent timid
# roamer fleeing); the startle is the band's action, the despawn rides the soak's steps.
func _startle_flee(mons, player, world, runner, runtime, target: Dictionary, stats: Dictionary) -> void:
	stats["flee_attempts"] = int(stats.get("flee_attempts", 0)) + 1
	if _stand_adjacent(mons, player, world, runner, runtime, target):
		stats["flees_startled"] = int(stats.get("flees_startled", 0)) + 1


func _steal_egg(runtime, mons, target: Dictionary, stats: Dictionary) -> void:
	stats["egg_attempts"] = int(stats.get("egg_attempts", 0)) + 1
	if runtime.session.party.size() >= 6:
		runtime.session.party.remove_at(runtime.session.party.size() - 1)
	var result: Dictionary = mons.egg_take(target["tile"])
	if bool(result.get("ok", false)):
		stats["eggs_stolen"] = int(stats.get("eggs_stolen", 0)) + 1
		if runtime.session.party.size() > 5:
			runtime.session.party.remove_at(runtime.session.party.size() - 1)


# "" while the store stays hygienic: the forced-battle seam disarmed, no entity past
# DESPAWN_CELLS, nothing on the player's tile. Any breach names the entity.
func store_clean(mons, player_tile: Vector2i) -> String:
	if not mons._pending.is_empty() or str(mons._pending_id) != "":
		return "the pending-encounter seam is left armed (id %s)" % str(mons._pending_id)
	if not mons.entity_at(player_tile).is_empty():
		return "an entity stands on the player's tile"
	var player_cell := OverworldMons.cell_for_tile(player_tile)
	for entity_id in mons._entities.keys():
		var entity: Dictionary = mons._entities[entity_id]
		if str(entity.get("kind", "")) == "legendary":
			continue # Build 2: window-exempt statics persist at ring ≥60 by design (the sim's sync_window skips them too) — the DESPAWN_CELLS drift audit is for window-culled roamers, never the permanent legendaries
		var tile: Vector2i = entity.get("tile", Vector2i.ZERO)
		if OverworldMons.cell_distance(OverworldMons.cell_for_tile(tile), player_cell) > OverworldMons.DESPAWN_CELLS:
			return "entity %s lingers past DESPAWN_CELLS" % str(entity_id)
	return ""


func _nearest(mons, player, field: String, wanted: String, radius: int = ENGAGE_RADIUS) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := radius + 1
	var player_tile: Vector2i = player.tile_position
	for entity_id in mons._entities.keys():
		var entity: Dictionary = mons._entities[entity_id]
		if str(entity.get("kind", "")) == "legendary":
			continue # Build 2: legendaries are NOT a soak action band (the soak never battles — legendary_spawn owns that); permanent window-exempt ring-≥60 AGGRESSIVE statics, an unscoped scan locks onto one and drags the player 70+ rings out, starving the roam banks (the egg-kind targeting precedent)
		if str(entity.get(field, "")) != wanted:
			continue
		var tile: Vector2i = entity.get("tile", Vector2i.ZERO)
		var distance := maxi(absi(tile.x - player_tile.x), absi(tile.y - player_tile.y))
		if distance < best_distance:
			best = entity
			best_distance = distance
	return best


# Stand on the first walkable neighbor of the target (the action seams are adjacency-
# based). No walkable neighbor -> the engagement is skipped (never stand ON the entity:
# the player-tile hygiene audit would flag it).
func _stand_adjacent(mons, player, world, runner, runtime, target: Dictionary) -> bool:
	var tile: Vector2i = target.get("tile", Vector2i.ZERO)
	for offset in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var stand: Vector2i = tile + offset
		if world.is_tile_walkable(stand) and mons.entity_at(stand).is_empty():
			runner.teleport_player(world, player, runtime, stand)
			return true
	return false
