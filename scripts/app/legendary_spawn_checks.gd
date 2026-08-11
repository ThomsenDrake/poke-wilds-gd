extends RefCounted

# Phase 7 Build 2 legendary_spawn CHECKS, extracted from legendary_spawn_scenario.gd
# at the app 220 budget wall (check_architecture.gd SCRIPT_LIMITS; the world_depth_checks
# precedent). The scenario keeps the anchor/exclusion/whiteout/ko FLOW; this owns the
# three proofs that grew past the budget once hardened against vacuous passes:
#   (1) anchor_set_pin — pins the EXACT derived set under the scenario seed (ALL SEVEN
#       anchored — the climate field generates LAVA, the retired radial gap) instead of
#       a >=2 floor, and asserts the anchored tiles are DISTINCT (the sibling-exclusion
#       chain displaces same-region siblings; a collision lets entity_at mask one);
#   (2) music_seam_pin — the battle-MUSIC seam is observable (music_router emits
#       music_track_selected, asserted for kind "legendary" -> the beasts track) AND its
#       production consumer main.gd:92 reads battle_kind off the pending payload (a static
#       grep pin — the live bridge early-returns under the set_battle latch, so that line
#       never executes in-scenario);
#   (3) roundtrip_removal — the KO removal key survives session_payload's to_payload ->
#       apply_into into a FRESH session, and re-deriving the stamped set off THAT set keeps
#       the KO'd species gone while every untouched anchored legendary returns.
# NO rng, NO I/O beyond the source-text grep + the runtime's own trace log; the round-trip
# builds a SEPARATE session (never runtime.session), so the shared encounter stream is
# never perturbed (the double-run lane stays byte-identical).

const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const MusicRouter := preload("res://scripts/runtime/music_router.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # the seal proof rides its DungeonLayouts preload (the layer table)
# App may not preload domain directly (check_architecture.gd layer table) — ride the
# runtime's own preload (the landmark_flow precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const Landmarks := LandmarkRuntime.Landmarks

const ORIGIN := Vector2i.ZERO # Build 2 stamps the origin world (Build 3 threads the active chain)
const MAIN_SOURCE_PATH := "res://scripts/app/main.gd"
# The exact derived placement under the scenario's pinned seed (EMPIRICALLY captured off
# LegendaryPlacement.legendaries_for_world, NOT hardcoded tiles): under the climate field
# ALL SEVEN anchor (LAVA generates — the retired radial quantization gap is RESOLVED);
# the NO_ANCHOR set is EMPTY. Order == LEGENDARY_IDS iteration order. A salt/affinity/
# threshold regression that moves ANY frozen legendary flips one of these sets and reds
# the lane.
const EXPECTED_ANCHORED := ["MEWTWO", "REGIROCK", "REGICE", "REGISTEEL", "REGIELEKI", "REGIDRAGO", "REGIGIGAS"]
const EXPECTED_LAVA_ABSENT: Array = []


# Pin the EXACT anchored/NO_ANCHOR partition + tile distinctness. `world_seed` is the LIVE
# derived seed (runtime.get_world_seed()), so the tile re-derivation agrees with the sim's
# stamp. Returns "" on pass, a failure label otherwise.
static func anchor_set_pin(anchored: Array, lava_absent: Array, world_seed: int) -> String:
	if anchored != EXPECTED_ANCHORED:
		return "anchor: anchored set %s != the pinned seven %s (a salt/affinity/threshold regression moved a frozen legendary off its anchor)" % [str(anchored), str(EXPECTED_ANCHORED)]
	if lava_absent != EXPECTED_LAVA_ABSENT:
		return "anchor: lava_absent set %s != [] (under the climate field every frozen legendary anchors; a NO_ANCHOR flags an anchor-scan regression)" % str(lava_absent)
	var seen: Array = []
	for entry in LegendaryPlacement.legendaries_for_world(world_seed, ORIGIN): # the sim's exact source (the sibling-exclusion chain; a per-species anchor_for can disagree by a displaced tile)
		var tile: Vector2i = entry.get("tile", LegendaryPlacement.NO_ANCHOR)
		if seen.has(tile):
			return "anchor: %s shares tile %s with an earlier legendary (a sibling-anchor collision lets entity_at mask one of the seven)" % [str(entry.get("species_id", "")), str(tile)]
		seen.append(tile)
	return ""


# The sim's exact stamped source set (the sibling-exclusion chain threaded across
# LEGENDARY_IDS): species -> the derived entry. A per-species anchor_for skips the
# exclusion and can disagree with the stamp by a displaced tile, so every consumer
# (the scenario's entity==derived assert, the distinctness pin) derives through here.
static func expected_anchor_set(world_seed: int) -> Dictionary:
	var expected := {}
	for entry in LegendaryPlacement.legendaries_for_world(world_seed, ORIGIN):
		expected[str(entry.get("species_id", ""))] = entry
	return expected


# SYNTHETIC NO_ANCHOR witness (the natural negative proof is vacuous once all seven
# anchor under the climate field): a reach-1 box resolves NO_ANCHOR for every species,
# and legendaries_for_world skips them all — the no-entity skip path stays proven,
# never silently vacuous. Returns "" on pass.
static func synthetic_no_anchor_witness(world_seed: int) -> String:
	var none_count: int = LegendaryPlacement.legendaries_for_world(world_seed, ORIGIN, [], 1).size()
	if none_count != 0:
		return "anchor: a reach-1 box still stamped %d legendaries (the NO_ANCHOR skip path regressed)" % none_count
	return ""


# The battle-music seam is observable AND its production consumer is pinned. Returns "" on
# pass. `cursor` scopes the trace search to AFTER the scenario's play_battle_track call.
static func music_seam_pin(runner, cursor: int) -> String:
	var expected_track := str(MusicRouter.BATTLE_TRACKS["legendary"])
	if not runner.trace_log_has_since("music_track_selected", cursor, {"kind": "legendary", "track_path": expected_track}):
		return "music: no music_track_selected{kind:legendary, track:%s} after the battle-start call (the kind->track seam is unobservable)" % expected_track
	# Static grep pin: the live bridge is latch-bypassed under test (main._in_battle early-
	# returns), so main.gd:92 never runs in-scenario — pin its TEXT instead so a revert to
	# play_battle_track("wild") reds here even though the scenario's own mimic call stays green.
	var source := FileAccess.get_file_as_string(MAIN_SOURCE_PATH)
	if not source.contains("play_battle_track(str(wild_mon.get(\"battle_kind\""):
		return "music: main.gd no longer reads battle_kind off the pending payload (the production kind consumer regressed)"
	return ""


# The KO removal key survives the save marshalling round-trip (session_payload.gd to_payload
# + apply_into): a FRESH session loaded from the KO'd session's payload carries the key, and
# re-deriving the stamped set off THAT persistent set keeps the KO'd species gone while every
# untouched anchored legendary returns. Deleting either marshalling line reds this. Returns
# "" on pass.
static func roundtrip_removal(runtime, species_id: String, anchored: Array) -> String:
	var payload: Dictionary = runtime.session.to_save_payload({}, {})
	var fresh = SessionState.new()
	fresh.apply_loaded_state(payload, runtime.session.get_party_snapshot())
	var key := ""
	for entry in LegendaryPlacement.legendaries_for_world(runtime.get_world_seed(), ORIGIN): # slice 3: the removal key is the species' CANONICAL origin anchor
		if str(entry.get("species_id", "")) == species_id:
			key = LegendaryPlacement.removal_key(entry.get("tile", LegendaryPlacement.NO_ANCHOR), species_id)
	if not (fresh.legendary_removals as Array).has(key):
		return "ko: the to_payload/apply_into round-trip lost the removal key %s (fresh set %s) — a KO'd legendary would respawn on save-load" % [key, str(fresh.legendary_removals)]
	var present: Array = []
	for entry in LegendaryPlacement.legendaries_for_world(runtime.get_world_seed(), ORIGIN, fresh.legendary_removals):
		present.append(str(entry.get("species_id", "")))
	if present.has(species_id):
		return "ko: the round-tripped removal set still stamps the KO'd %s (suppression not re-derived from the persisted set)" % species_id
	for other in anchored:
		var sid := str(other)
		if sid != species_id and LegendaryPlacement.anchor_for(runtime.get_world_seed(), ORIGIN, sid) != LegendaryPlacement.NO_ANCHOR and not present.has(sid):
			return "ko: the round-tripped removal set dropped the untouched %s" % sid
	return ""


# --- Shared scenario helpers (the ONE home; the dungeon + battle checks ride these) --------
# A damaging move that cannot stall (heal/leech would never end the battle path).
static func damaging_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var move: Dictionary = moves[i]
		if int(move.get("power", 0)) > 0 and int(move.get("pp", 0)) > 0 and str(move.get("effect", "")) != "EFFECT_LEECH_HIT" and str(move.get("effect", "")) != "EFFECT_HEAL": return i
	return 0


static func ensure(ok: bool, label: String, failures: Array) -> bool:
	if not ok:
		failures.append(label)
	return ok


# The Regigigas five-tablet seal (the legendary-dungeon slice): the warp REFUSES with an
# incomplete set (no warp; the dungeon_entry_refused trace names the dungeon), then granting
# all five tablets opens it (never consumed). Returns "" on pass and leaves the caller
# INSIDE the dungeon; a failure label otherwise (the caller bails).
static func seal_refusal_pin(runtime, dungeon_id: String, warp: Vector2i, runner) -> String:
	var cursor: int = runner.trace_log_line_count()
	if runtime.dungeon_runtime.try_enter_at(warp):
		return "ko: the Regigigas seal opened WITHOUT the five tablets"
	if not runner.trace_log_has_since("dungeon_entry_refused", cursor, {"dungeon_id": dungeon_id}):
		return "ko: no dungeon_entry_refused trace off the sealed warp"
	for tablet in DungeonRuntime.DungeonLayouts.TABLET_FOR_SPECIES.values():
		runtime.session.add_item(str(tablet), 1)
	if not runtime.dungeon_runtime.try_enter_at(warp):
		return "ko: the seal refused the five-tablet bag"
	return ""


# Phase 7 audit R6: curated/extra_ids are injected AFTER the biome filter, so every live
# landmark and dungeon scope must independently reject legendaries AND non-battle-viable
# catalog entries. Walk the production scopes (mutation-proven) and append named failures.
static func curated_exclusion_pin(runtime, failures: Array) -> void:
	var seed: int = runtime.get_world_seed()
	var seen_tokens: Dictionary = {}
	for landmark in Landmarks.landmarks_in_world(seed, ORIGIN):
		var footprint: Rect2i = landmark["footprint"]
		for y in range(footprint.position.y, footprint.end.y):
			for x in range(footprint.position.x, footprint.end.x):
				var tile := Vector2i(x, y)
				var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
				var token := str(logic.get("encounter_token", ""))
				if token == "" or seen_tokens.has(token):
					continue
				seen_tokens[token] = true
				var scope: Dictionary = runtime.landmark_runtime.encounter_scope_for(tile, str(logic.get("biome", "")))
				var curated: Dictionary = scope.get("curated", {}) if scope.get("curated", {}) is Dictionary else {}
				var extra: Array = scope.get("extra_ids", []) if scope.get("extra_ids", []) is Array else []
				if curated.is_empty() and extra.is_empty():
					continue
				_assert_curated_scope(token, curated, extra, runtime, failures)
	for dungeon_id in DungeonRuntime.DungeonMaps.DUNGEON_IDS:
		var scope: Dictionary = DungeonRuntime.DungeonMaps.encounter_scope_for(str(dungeon_id))
		_assert_curated_scope(str(dungeon_id), scope.get("curated", {}), scope.get("extra_ids", []), runtime, failures, true)
	# A known dungeon with malformed authored data keeps its token but exposes no drawable pool.
	var malformed_scopes := [{}, {"level_band": [5, 6], "curated": []}, {"curated": {"SNORUNT": [5, 6]}}, {"level_band": [5], "curated": {"SNORUNT": [5, 6]}}, {"level_band": [5, 6], "curated": {"SNORUNT": [5]}}]
	for index in range(malformed_scopes.size()):
		var refused: Dictionary = DungeonRuntime.DungeonLayouts.normalize_encounter_scope("dungeon_regice", malformed_scopes[index])
		if str(refused.get("token", "")) != "dungeon_regice" or not (refused.get("extra_ids", []) as Array).is_empty() or not (refused.get("curated", {}) as Dictionary).is_empty():
			failures.append("exclusion: malformed dungeon scope %d did not preserve a tokened-empty refusal" % index)

static func _assert_curated_scope(token: String, curated: Dictionary, extra: Array, runtime, failures: Array, require_nonempty: bool = false) -> void:
	var curated_ids: Array = curated.keys(); curated_ids.sort()
	var extra_ids: Array = []
	for species_id in extra:
		if not extra_ids.has(str(species_id)): extra_ids.append(str(species_id))
	extra_ids.sort()
	if require_nonempty and curated_ids.is_empty(): failures.append("exclusion: %s curated scope is empty" % token)
	if curated_ids != extra_ids: failures.append("exclusion: %s extra_ids %s != curated keys %s" % [token, str(extra_ids), str(curated_ids)])
	var ids: Array = curated_ids.duplicate()
	for species_id in extra_ids:
		if not ids.has(species_id): ids.append(species_id)
	for species_id in ids:
		var sid := str(species_id)
		if LegendaryPlacement.LEGENDARY_IDS.has(sid):
			failures.append("exclusion: %s is drawable in the %s curated scope (legendaries must stay static)" % [sid, token])
		if not runtime._biome_encounters.is_battle_viable(sid, runtime.catalog.get_species(sid)):
			failures.append("exclusion: %s is not battle-viable in the %s curated scope" % [sid, token])
