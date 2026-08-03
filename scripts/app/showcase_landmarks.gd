extends RefCounted

# Showcase ORIGIN-landmark frames (NOT baselines): the Pokémon Mansion statue room with the puzzle
# SOLVED + both doors open (01), the unlocked sewer/basement underneath (02), the Desert Ruins
# exterior with its glowing statues (03), and the Heart Tower's dedicated-tileset chamber (05).
# Footprints are PROBED off the view's tile logic via ShowcaseSupport (never hardcoded); the mansion
# puzzle is crafted through the frozen seam (set_landmark_state + rebuild), NEVER the keying. The
# entity layer stays inert and encounter_chance is pinned 0 by the driver, so no pending seam arms.
# Reaches into the driver node for the shared capture/craft plumbing (the beacon/expand precedent).
# NO rng; byte-stable.

const ShowcaseSupport := preload("res://scripts/app/showcase_support.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd") # walkable_near framing math

const RUINS_ID := "desert_ruins"
const MANSION_ID := "pkmn_mansion"
const TOWER_ID := "heart_tower"
const SPIRAL_CAP := 80
const MANSION_ROOM_LOCAL := Vector2i(7, 6) # statue row y7 one row below, both door tiles y5 above
const MANSION_SEWER_LOCAL := Vector2i(2, 6) # sewer floor (x<=4, y>=6); stairs_down (2,7), sewer door (4,5)
const RUINS_EXTERIOR_LOCAL := Vector2i(7, 8) # south stand: the whole footprint + glowing statues frame
const TOWER_CHAMBER_LOCAL := Vector2i(4, 4) # base chamber center (the enterable entry tile is (4,7))
const MANSION_DOOR_LOCALS := {"room_door": Vector2i(7, 5), "sewer_door": Vector2i(4, 5)}
const SOLVED_MANSION := {MANSION_ID: {"statues": [true, true, true], "unlocked": true, "key_taken": true}}
const SHOT_STATUE_ROOM := "01_mansion_statue_room.png"
const SHOT_SEWER := "02_mansion_sewer.png"
const SHOT_RUINS := "03_ruins_exterior.png"
const SHOT_TOWER := "05_heart_tower.png"


static func run(s: Node) -> void:
	await _mansion_shots(s)
	await _ruins_shot(s)
	await _tower_shot(s)


# (01)+(02) Mansion: seam-craft the SOLVED puzzle, rebuild so the resolver re-stamps both door
# overlays walkable, then frame the lit statue room and the unlocked sewer from inside the footprint.
static func _mansion_shots(s: Node) -> void:
	var fp := ShowcaseSupport.find_footprint(s._world(), MANSION_ID, SPIRAL_CAP)
	if fp.size == Vector2i.ZERO:
		s._failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT_STATUE_ROOM, MANSION_ID, SPIRAL_CAP]); return
	ShowcaseSupport.write_mansion_state(s._runtime(), fp, (SOLVED_MANSION as Dictionary)[MANSION_ID]) # the instance-keyed merge (slice 3)
	s._world().rebuild(int(s._runtime().get_world_seed()))
	for door in MANSION_DOOR_LOCALS:
		var door_tile: Vector2i = fp.position + MANSION_DOOR_LOCALS[door]
		if not bool(s._world().get_tile_logic(door_tile).get("walkable", false)):
			s._failures.append("%s: %s at %s stayed sealed after the solved seam-craft (door overlay broken)" % [SHOT_STATUE_ROOM, door, door_tile]); return
	var room_tile: Vector2i = fp.position + MANSION_ROOM_LOCAL
	if not bool(s._world().get_tile_logic(room_tile).get("walkable", false)):
		s._failures.append("%s: statue-room camera tile %s not walkable (domain layout drift)" % [SHOT_STATUE_ROOM, room_tile]); return
	ShowcaseSupport.teleport(s, room_tile)
	await s._capture(SHOT_STATUE_ROOM, {"locale": "Pokémon Mansion statue room (puzzle solved, both doors open)",
		"seed": s._runtime().get_world_seed(), "camera_tile": [room_tile.x, room_tile.y],
		"footprint": ShowcaseSupport.rect_array(fp), "mansion_state": (SOLVED_MANSION as Dictionary)[MANSION_ID],
		"statue_locals": [[6, 7], [7, 7], [8, 7]], "door_locals": {"room_door": [7, 5], "sewer_door": [4, 5]}})
	# (02) Sewer/basement: the SAME solved state; stand on the sewer floor, the stairs_down prop + the
	# open sewer door framing the descent.
	var sewer_tile: Vector2i = fp.position + MANSION_SEWER_LOCAL
	var sewer_logic: Dictionary = s._world().get_tile_logic(sewer_tile)
	if str(sewer_logic.get("landmark_id", "")) != MANSION_ID or not bool(sewer_logic.get("walkable", false)):
		s._failures.append("%s: sewer camera tile %s landmark/walkable unexpected (domain layout drift)" % [SHOT_SEWER, sewer_tile]); return
	ShowcaseSupport.teleport(s, sewer_tile)
	await s._capture(SHOT_SEWER, {"locale": "Pokémon Mansion unlocked sewer / basement",
		"seed": s._runtime().get_world_seed(), "camera_tile": [sewer_tile.x, sewer_tile.y],
		"footprint": ShowcaseSupport.rect_array(fp), "stairs_down_tile": [fp.position.x + 2, fp.position.y + 7],
		"open_sewer_door": [fp.position.x + 4, fp.position.y + 5]})


# (03) Desert Ruins exterior: stand south of the chamber so the footprint (walls + the glowing outer
# statue pair) fills the frame. Asserts the stand tile is walkable; the glowing statues are domain-
# guaranteed for the ruins footprint (recorded in the sidecar, not hard-asserted).
static func _ruins_shot(s: Node) -> void:
	var fp := ShowcaseSupport.find_footprint(s._world(), RUINS_ID, SPIRAL_CAP)
	if fp.size == Vector2i.ZERO:
		s._failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT_RUINS, RUINS_ID, SPIRAL_CAP]); return
	var stand := WorldDepthExpand.walkable_near(s._world(), fp.position + RUINS_EXTERIOR_LOCAL)
	if stand == Vector2i.MAX:
		s._failures.append("%s: no walkable exterior camera tile near %s (framing broken)" % [SHOT_RUINS, fp.position + RUINS_EXTERIOR_LOCAL]); return
	ShowcaseSupport.teleport(s, stand)
	await s._capture(SHOT_RUINS, {"locale": "Desert Ruins exterior (glowing statues)",
		"seed": s._runtime().get_world_seed(), "camera_tile": [stand.x, stand.y],
		"footprint": ShowcaseSupport.rect_array(fp),
		"glowing_statue_tiles": [[fp.position.x + 3, fp.position.y + 5], [fp.position.x + 11, fp.position.y + 9]]})


# (05) Heart Tower: stand in the base chamber; assert the dedicated tileset's chamber tile is the
# tower landmark + walkable (the wall/decor props render around it).
static func _tower_shot(s: Node) -> void:
	var fp := ShowcaseSupport.find_footprint(s._world(), TOWER_ID, SPIRAL_CAP)
	if fp.size == Vector2i.ZERO:
		s._failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT_TOWER, TOWER_ID, SPIRAL_CAP]); return
	var chamber: Vector2i = fp.position + TOWER_CHAMBER_LOCAL
	var logic: Dictionary = s._world().get_tile_logic(chamber)
	if str(logic.get("landmark_id", "")) != TOWER_ID or not bool(logic.get("walkable", false)):
		s._failures.append("%s: chamber tile %s landmark/walkable unexpected (domain layout drift)" % [SHOT_TOWER, chamber]); return
	ShowcaseSupport.teleport(s, chamber)
	await s._capture(SHOT_TOWER, {"locale": "Heart Tower base chamber (dedicated tileset)",
		"seed": s._runtime().get_world_seed(), "camera_tile": [chamber.x, chamber.y],
		"footprint": ShowcaseSupport.rect_array(fp)})
