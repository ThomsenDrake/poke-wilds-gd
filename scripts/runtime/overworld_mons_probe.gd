extends RefCounted

# Phase 6 overworld mons SCENARIO/AUDIT oracle helpers (spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation), extracted at the app line budget so the
# gate scenario's two check files AND world_entity_audit share one implementation
# instead of three mirrors. Runtime layer (app may preload it; it reaches the entity
# runtime + world only through passed objects, never a domain preload). Reads: the
# live-entity window, the entity-set determinism hash, the deterministic biome band
# anchors (the world_generator ring convention), the nest search, the seeded wild-draw
# sequence (the unconsumed-stream CONTROL), and the JSONL trace scan (the house
# trace-log convention, single-sourced path).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const CELL_SIZE := 8 # mirrors OverworldMons.CELL_SIZE (scenario contract)
const AXIS_SCAN_MAX := 24576 # ring bound for the biome discovery (generous for arbitrary save seeds; the climate field puts LAVA anywhere, so most seeds resolve far inside the cap)

# The full per-entity state over sorted ids — two same-(seed, steps, player-tile)
# derivations yield the identical string (the determinism proof, scenario + audit).
func entity_hash(mons, center: Vector2i, radius: int) -> String:
	var parts: Array = []
	for e in live(mons, center, radius):
		parts.append("%s|%s|%d,%d|%s|%s|%d|%s|%s|%d|%d|%d" % [str(e.get("id", "")), str(e.get("species_id", "")),
			e.tile.x, e.tile.y, str(e.get("disposition", "")), str(e.get("state", "")), int(e.get("level", 0)),
			str(e.get("is_shiny", false)), str(e.get("gender", "")), int(e.get("current_hp", 0)),
			int(e.get("attack_stages", 0)), int(e.get("pacify_steps", 0))])
	parts.sort()
	return ";".join(PackedStringArray(parts))

func live(mons, center: Vector2i, radius: int) -> Array:
	var result: Variant = mons.call("live_entities_in", Rect2i(center - Vector2i(radius, radius), Vector2i(radius * 2 + 1, radius * 2 + 1)))
	return result if result is Array else []

func by_id(mons, near: Vector2i, entity_id: String) -> Dictionary: # ids are stable across roam tiles
	for e in live(mons, near, 32):
		if str(e.get("id", "")) == entity_id:
			return e
	return {}

# Tile-validity guardrail: no two MONS share a tile (spawn anchors + roam + chase/flee all exclude
# occupied tiles, so a shared tile is a placement regression). A mon may shadow an egg (entity_at
# gives mons Z-precedence by design), so eggs are skipped. Returns failure dicts (miss-002 loud).
func tile_overlap_failures(mons, center: Vector2i, radius: int) -> Array:
	var seen := {}
	var failures: Array = []
	for e in live(mons, center, radius):
		if str(e.get("kind", "")) == "egg":
			continue
		var key := "%d,%d" % [e.tile.x, e.tile.y]
		if seen.has(key):
			failures.append({"tile": [e.tile.x, e.tile.y], "kind": "entity_tile_overlap", "entity_id": str(e.get("id", ""))})
		seen[key] = true
	return failures

# biome -> stand tile, deterministic: the spoke scan (EIGHT spokes — axes + diagonals —
# first-seen per biome; the climate field puts every biome somewhere on the plane, and a
# rare pocket can thread BETWEEN the four axes on some world seeds), then a local walkable
# stand tile. WATER stands on LAND within `water_reach` tiles of the patch so water cells
# enter the spawn window (swim_only only).
func biome_anchors(world, biomes: Array, water_reach: int = 10) -> Dictionary:
	var first_seen := {}
	for r in range(0, AXIS_SCAN_MAX, 2):
		for k in range(8):
			var point := band_point(r, k)
			var seen: String = str(world.get_tile_logic(point).get("biome", ""))
			if not first_seen.has(seen):
				first_seen[seen] = point
	var anchors := {}
	for biome in biomes:
		if first_seen.has(str(biome)):
			anchors[str(biome)] = stand_tile(world, first_seen[str(biome)], str(biome), water_reach)
	return anchors


# One of the eight Manhattan-ring directions at `ring` (the band-spread anchor generator
# the spawn case + audit use to sample many slot draws along a biome band).
func band_point(ring: int, direction: int) -> Vector2i:
	var half := ring / 2
	var points := [Vector2i(ring, 0), Vector2i(half, ring - half), Vector2i(0, ring),
		Vector2i(-(ring - half), half), Vector2i(-ring, 0), Vector2i(-half, -(ring - half)),
		Vector2i(0, -ring), Vector2i(ring - half, -half)]
	return points[direction % 8]


# A walkable stand tile of the biome near `near` (ring scan, radius 24 cap); WATER stands
# on LAND within `water_reach` tiles of the patch so water cells enter the spawn window
# (swim_only mons ride water tiles only). Vector2i.MAX when none.
func stand_tile(world, near: Vector2i, biome: String, water_reach: int = 10) -> Vector2i:
	for radius in range(0, 25):
		for tile in ring(near, radius):
			var logic: Dictionary = world.get_tile_logic(tile)
			if biome == "WATER":
				if bool(logic.get("walkable", false)) and water_within(world, tile, water_reach):
					return tile
			elif bool(logic.get("walkable", false)) and str(logic.get("biome", "")) == biome:
				return tile
	return Vector2i.MAX


# Closing chase step must NOT arm the battle (the sprite is still lerping from 2 tiles
# away). The next player-step clock, once adjacent and settled, catches. "" = ok.
func chase_settle_failure(world, mons, runtime, stand: Vector2i) -> String:
	var far: Vector2i = Vector2i.ZERO
	for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		if world.is_tile_walkable(stand + direction) and world.is_tile_walkable(stand + direction * 2):
			far = stand + direction * 2
			break
	if far == Vector2i.ZERO:
		return "settle: no 2-tile walkable corridor beside the player"
	var cell := Vector2i(floori(float(far.x) / 8.0), floori(float(far.y) / 8.0))
	var record: Dictionary = mons.get("_sim").call("new_mon", "inject_settle", "roaming", 0, cell, "MACHOP", far, 5, "AGGRESSIVE")
	record["state"] = "chasing"
	mons._entities[str(record.id)] = record
	runtime.note_player_step()
	if not (mons.get("_pending") as Dictionary).is_empty():
		return "settle: the closing chase step armed the battle (sprite still 2 tiles away)"
	runtime.note_player_step()
	if (mons.get("_pending") as Dictionary).is_empty():
		return "settle: the settled adjacent chaser did not catch"
	mons.take_pending_encounter()
	return ""


# Deterministic stimulus crafting for scenario/audit (party-swap status): a fresh entity
# record on a walkable tile `distance` from `center`, rolled on the derived stream (the
# sim's new_mon), inserted live. Only for when the natural scan misses (band-spawn luck).
func inject_entity(world, mons, center: Vector2i, species_id: String, disposition: String, distance: int, biome: String) -> Dictionary:
	for tile in ring(center, distance):
		var logic: Dictionary = world.get_tile_logic(tile)
		if not bool(logic.get("walkable", false)): continue
		if biome != "" and str(logic.get("biome", "")) != biome: continue
		var cell := Vector2i(floori(float(tile.x) / 8.0), floori(float(tile.y) / 8.0))
		var record: Dictionary = mons.get("_sim").call("new_mon", "inject_%s" % species_id, "roaming", 0, cell, species_id, tile, 5, disposition)
		mons._entities[str(record.id)] = record
		return record
	return {}

func water_within(world, tile: Vector2i, radius: int) -> bool:
	for r in range(1, radius + 1):
		for other in ring(tile, r):
			if str(world.get_tile_logic(other).get("biome", "")) == "WATER":
				return true
	return false


func ring(center: Vector2i, radius: int) -> Array:
	if radius == 0:
		return [center]
	var tiles: Array = []
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if maxi(absi(x), absi(y)) == radius:
				tiles.append(center + Vector2i(x, y))
	return tiles

# The first nest cell center in the deterministic search sequence (the runtime owns the
# domain nest roll; app/audit may not reach domain), or Vector2i.ZERO when none lies in
# range (cell centers are never (0,0), so ZERO is a safe sentinel — callers skip, never fake).
func find_nest(mons, centers: Array, radius: int) -> Vector2i:
	for center in centers:
		var found: Variant = mons.call("find_nest_center_near", center, radius)
		if found is Vector2i and found != Vector2i.ZERO:
			return found
	return Vector2i.ZERO

# N seeded wild draws as comparable strings (species|level|shiny) — the CONTROL asserting
# the identical sequence with entities active vs inert (the shared _rng unconsumed).
func draw_sequence(runtime, tile: Vector2i, biome: String, draws: int) -> Array:
	var sequence: Array = []
	for _i in range(draws):
		var mon: Dictionary = runtime.generate_wild_encounter(tile, biome)
		sequence.append("%s|%d|%s" % [str(mon.get("species_id", "")), int(mon.get("level", 0)), str(mon.get("is_shiny", false))])
	return sequence

# Trace events at/after cursor matching every key of `match` (JSON round-trip normalizes
# the log's floated numbers — the smoke_scenario_runner convention).
func trace_count(cursor: int, event_name: String, match: Dictionary = {}) -> int:
	var count := 0
	var normalized: Dictionary = JSON.parse_string(JSON.stringify(match)) if not match.is_empty() else {}
	for line in _lines_from(cursor):
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary) or str((parsed as Dictionary).get("event", "")) != event_name:
			continue
		var payload: Variant = (parsed as Dictionary).get("payload", {})
		var hit := true
		for key in normalized.keys():
			if not (payload is Dictionary) or (payload as Dictionary).get(key) != normalized[key]:
				hit = false
		if hit:
			count += 1
	return count

func last_payload(cursor: int, event_name: String) -> Dictionary:
	var last: Dictionary = {}
	for line in _lines_from(cursor):
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary and str((parsed as Dictionary).get("event", "")) == event_name:
			var payload: Variant = (parsed as Dictionary).get("payload", {})
			last = payload if payload is Dictionary else {}
	return last

func _lines_from(cursor: int) -> Array:
	var lines := _trace_lines()
	var out: Array = []
	for index in range(maxi(cursor, 0), lines.size()):
		out.append(lines[index])
	return out

func _trace_lines() -> PackedStringArray:
	if not FileAccess.file_exists(SmokeScenarioRunner.TRACE_LOG_PATH):
		return PackedStringArray()
	var file := FileAccess.open(SmokeScenarioRunner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text := file.get_as_text()
	file.close()
	return text.split("\n", false)
