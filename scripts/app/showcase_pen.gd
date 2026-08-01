extends RefCounted

# Showcase PEN frame (NOT a baseline): a fenced pasture holding a deterministic female+male EEVEE
# pair plus a ground egg at noon (breeding-shinies-drops-fishing.md). The pen world is its own seed
# (2026072605 — the proven pen+egg world) with the exact 16-fence price in the bag; the driver re-
# crafts it. The craft rides the existing Phase-5 surfaces: find_pen_site (5x5 grass-free single-
# biome block) -> build_pen (16-fence ring) -> gendered_instances -> pasture_deposit x2 -> poke_
# pasture_happiness(255) -> wait_for_pen_egg (seeded cadence). Framed from the gate side, the avatar
# turned to face the pen; the EEVEEs stay penned and the egg stays on the ground (the shot's point).
# Reaches into the driver node for the shared capture/craft plumbing. NO rng on the capture path.

const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const SITE_RADIUS := 160
const EGG_CAP_STEPS := 6000
const PEN_SPEC := {"world_seed": 2026072605, "time_of_day": 720, "party": [["MACHOP", 30]], "bag": {"log": 16, "dry_soil": 16}}
const SHOT := "07_pen_eggs.png"


static func run(s: Node) -> void:
	if not s._craft(PEN_SPEC):
		s._failures.append("%s: pen-world craft failed (catalog incomplete)" % SHOT); return
	var runtime = s._runtime() # untyped: _runtime() is a dynamic reach into the driver node (the visual_sweep_pokemon precedent)
	var center := Sites.find_pen_site(s._world(), s._player().tile_position, SITE_RADIUS)
	if center == Vector2i.ZERO:
		s._failures.append("%s: no pen site within %d tiles of spawn (find_pen_site seam broken)" % [SHOT, SITE_RADIUS]); return
	if not bool(Sites.build_pen(runtime, center).get("ok", false)):
		s._failures.append("%s: fence ring at %s did not build/enclose (build_pen seam broken)" % [SHOT, center]); return
	Phase5.invalidate_pen_cache(runtime)
	var anchor := Phase5.pen_key_for(runtime, center)
	var pair: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", 30, ["female", "male"])
	if anchor.is_empty() or pair.size() != 2:
		s._failures.append("%s: no pen anchor / EEVEE pair (pen_key_for / gendered_instances broken)" % SHOT); return
	runtime.session.party.append(pair["female"])
	runtime.session.party.append(pair["male"])
	s._runner.teleport_player(s._world(), s._player(), runtime, center)
	for _i in range(2): # deposit the two just-appended mons (last party slot each time)
		Phase5.pasture_deposit(runtime, runtime.session.party.size() - 1)
	Phase5.poke_pasture_happiness(runtime, anchor, 255)
	var egg: Dictionary = Phase5.wait_for_pen_egg(runtime, anchor, EGG_CAP_STEPS, 60)
	if egg.is_empty():
		s._failures.append("%s: the seeded cadence laid no egg within %d steps (egg seam broken)" % [SHOT, EGG_CAP_STEPS]); return
	# Gate-side view: stand one tile outside the ring, turn the avatar to face the pen (fence-blocked step).
	var spot: Dictionary = Sites.pen_stand_spot(s._world(), center)
	if spot.is_empty():
		s._failures.append("%s: no gate-side stand spot around %s (pen_stand_spot broken)" % [SHOT, center]); return
	s._runner.teleport_player(s._world(), s._player(), runtime, spot["stand"])
	s._player().smoke_step(spot["faced"] - spot["stand"]) # blocked by the fence, turns the avatar
	s._world().set_time_of_day(int(PEN_SPEC["time_of_day"]))
	s._world().sync_visible(s._player().tile_position)
	await s._capture(SHOT, {"locale": "Fenced pen with EEVEE pair + a ground egg",
		"seed": int(PEN_SPEC["world_seed"]), "camera_tile": [int(spot["stand"].x), int(spot["stand"].y)],
		"pen_center": [center.x, center.y], "egg_tile": [int(egg["tile"].x), int(egg["tile"].y)],
		"pen_species": "EEVEE", "bag": (PEN_SPEC as Dictionary)["bag"]})
