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
	var key := "0,0:%s" % species_id
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


# Phase 7 audit R6: the curated/extra_ids exclusion path the per-biome pool scan cannot see.
# generate_wild_encounter injects a scope's extra_ids/curated AFTER the biome filter
# (landmark_runtime.pick_species_for), so a legendary added to a LIVE landmark scope
# (e.g. MEWTWO into Landmarks.RUINS_INNER_CURATED) becomes drawable on that footprint's
# tiles while every per-biome exclusion assert stays green. Walk the LIVE scope tables
# (mutation-proven, the world_depth_checks style) and assert curated ∩ legendaries == ∅ and
# extra_ids ∩ legendaries == ∅ for every tokened footprint tile. Appends named failures.
static func curated_exclusion_pin(runtime, failures: Array) -> void:
	var seed: int = runtime.get_world_seed()
	for landmark in Landmarks.landmarks_in_world(seed, ORIGIN):
		var footprint: Rect2i = landmark["footprint"]
		for y in range(footprint.position.y, footprint.end.y):
			for x in range(footprint.position.x, footprint.end.x):
				var tile := Vector2i(x, y)
				var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
				var token := str(logic.get("encounter_token", ""))
				if token == "":
					continue
				var scope: Dictionary = runtime.landmark_runtime.encounter_scope_for(tile, str(logic.get("biome", "")))
				var curated: Dictionary = scope.get("curated", {}) if scope.get("curated", {}) is Dictionary else {}
				var extra: Array = scope.get("extra_ids", []) if scope.get("extra_ids", []) is Array else []
				if curated.is_empty() and extra.is_empty():
					continue
				for species in LegendaryPlacement.LEGENDARY_IDS:
					var sid := str(species)
					if curated.has(sid):
						failures.append("exclusion: %s is curated into the %s scope (curated ∩ legendaries must be empty — a legendary is drawable on that footprint)" % [sid, token])
					if extra.has(sid):
						failures.append("exclusion: %s is an extra_id of the %s scope (extra_ids ∩ legendaries must be empty)" % [sid, token])
