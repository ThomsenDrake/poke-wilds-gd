extends RefCounted

# Phase 7 Build 2 legendary_spawn CHECKS, extracted from legendary_spawn_scenario.gd
# at the app 220 budget wall (check_architecture.gd SCRIPT_LIMITS; the world_depth_checks
# precedent). The scenario keeps the anchor/exclusion/whiteout/ko FLOW; this owns the
# three proofs that grew past the budget once hardened against vacuous passes:
#   (1) anchor_set_pin — pins the EXACT derived set under the scenario seed (the SNOW
#       three anchored, the LAVA four NO_ANCHOR) instead of a >=2 floor, and asserts the
#       anchored tiles are DISTINCT (no sibling-anchor collision masking one of the seven);
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
# App may not preload domain directly (check_architecture.gd layer table) — ride the
# runtime's own preload (the landmark_flow precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement

const ORIGIN := Vector2i.ZERO # Build 2 stamps the origin world (Build 3 threads the active chain)
const MAIN_SOURCE_PATH := "res://scripts/app/main.gd"
# The exact derived placement under the scenario's pinned seed (EMPIRICALLY captured off
# LegendaryPlacement.anchor_for, NOT hardcoded tiles): origin worlds generate ZERO LAVA
# tiles to ring 400 (the empirical flag), so the SNOW three anchor and the LAVA four
# resolve NO_ANCHOR. Order == LEGENDARY_IDS iteration order. A salt/affinity regression
# that moves ANY frozen legendary flips one of these sets and reds the lane.
const EXPECTED_ANCHORED := ["REGICE", "REGIELEKI", "REGIGIGAS"]
const EXPECTED_LAVA_ABSENT := ["MEWTWO", "REGIROCK", "REGISTEEL", "REGIDRAGO"]


# Pin the EXACT anchored/NO_ANCHOR partition + tile distinctness. `world_seed` is the LIVE
# derived seed (runtime.get_world_seed()), so the tile re-derivation agrees with the sim's
# stamp. Returns "" on pass, a failure label otherwise.
static func anchor_set_pin(anchored: Array, lava_absent: Array, world_seed: int) -> String:
	if anchored != EXPECTED_ANCHORED:
		return "anchor: anchored set %s != the pinned SNOW three %s (a salt/affinity regression moved a frozen legendary off its anchor)" % [str(anchored), str(EXPECTED_ANCHORED)]
	if lava_absent != EXPECTED_LAVA_ABSENT:
		return "anchor: lava_absent set %s != the pinned LAVA four %s (the empirical-flag NO_ANCHOR witness changed)" % [str(lava_absent), str(EXPECTED_LAVA_ABSENT)]
	var seen: Array = []
	for species in anchored:
		var tile: Vector2i = LegendaryPlacement.anchor_for(world_seed, ORIGIN, str(species))
		if seen.has(tile):
			return "anchor: %s shares tile %s with an earlier legendary (a sibling-anchor collision lets entity_at mask one of the seven)" % [str(species), str(tile)]
		seen.append(tile)
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
