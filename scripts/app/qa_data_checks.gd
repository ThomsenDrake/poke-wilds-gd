extends RefCounted

# Data half of the QA audits (entry point: qa_audits.gd run_data). Every
# biome encounter pool is checked for catalog integrity (sprites, catch
# rate, learnset, known types), sample species from each pool are
# instantiated across levels 2..80 and inspected, and the starting bag is
# resolved against the item catalog. Failures are collected; qa_audits.gd
# reports them. Domain/data pieces are reached through the GameRuntime
# instance from ctx so this app-layer file keeps no direct dependency.

const SAMPLE_PER_BIOME := 5
const INSTANCE_LEVELS := [2, 20, 40, 60, 80]

var _ctx: Dictionary = {}
var _failures: Array = []


func run_all(ctx: Dictionary) -> Dictionary:
	_ctx = ctx
	_failures = []
	var biomes_checked := 0
	var species_seen := {}
	var instances_checked := 0
	for biome in _sorted_keys(_biome_defs()):
		biomes_checked += 1
		var filtered: Dictionary = _runtime()._biome_encounters.filter_species_ids(_catalog().species, biome)
		var ids: Array = filtered.get("ids", [])
		for species_id in ids:
			species_seen[str(species_id)] = true
			_audit_pool_species(biome, str(species_id))
		instances_checked += _audit_instances(biome, ids)
	_audit_starting_bag()
	return {
		"failures": _failures,
		"payload": {
			"biomes_checked": biomes_checked,
			"species_checked": species_seen.size(),
			"instances_checked": instances_checked
		}
	}


# A species the encounter filter can actually pick must be battle-ready:
# sprite art on both sides, catchable, with real moves and charted types.
func _audit_pool_species(biome: String, species_id: String) -> void:
	var entry: Dictionary = _catalog().get_species(species_id)
	if entry.is_empty():
		_failures.append("%s/%s: id missing from catalog" % [biome, species_id])
		return
	if str(entry.get("front_path", "")).is_empty() or str(entry.get("back_path", "")).is_empty():
		_failures.append("%s/%s: pool species has no battle sprites" % [biome, species_id])
	if int(entry.get("catch_rate", 0)) <= 0:
		_failures.append("%s/%s: catch_rate %d, catches can never succeed" % [biome, species_id, int(entry.get("catch_rate", 0))])
	var learnset = entry.get("learnset", [])
	if not (learnset is Array) or (learnset as Array).is_empty():
		_failures.append("%s/%s: empty learnset, instances fall back to TACKLE" % [biome, species_id])
	for type_name in entry.get("types", PackedStringArray()):
		if not _chart().is_known_type(str(type_name)):
			_failures.append("%s/%s: type %s unknown to the type chart" % [biome, species_id, str(type_name)])


func _audit_instances(biome: String, ids: Array) -> int:
	var checked := 0
	for species_id in _sample_ids(ids):
		var entry: Dictionary = _catalog().get_species(species_id)
		if entry.is_empty():
			continue
		for level in INSTANCE_LEVELS:
			checked += 1
			var mon: Dictionary = _runtime().pokemon_rules.create_pokemon_instance(entry, level, Callable(_catalog(), "get_move"))
			_audit_instance(biome, species_id, level, mon)
	return checked


# Evenly spaced deterministic sample across the sorted pool ids.
func _sample_ids(ids: Array) -> Array:
	var sample: Array = []
	for i in range(SAMPLE_PER_BIOME):
		if ids.is_empty():
			break
		var species_id := str(ids[int(i * ids.size() / SAMPLE_PER_BIOME)])
		if not sample.has(species_id):
			sample.append(species_id)
	return sample


func _audit_instance(biome: String, species_id: String, level: int, mon: Dictionary) -> void:
	var label := "%s/%s L%d" % [biome, species_id, level]
	if mon.is_empty():
		_failures.append("%s: instance generation returned empty" % label)
		return
	if int(mon.get("level", -1)) != level:
		_failures.append("%s: level came out %d" % [label, int(mon.get("level", -1))])
	if int(mon.get("current_hp", -1)) != int(mon.get("max_hp", -2)):
		_failures.append("%s: current_hp != max_hp" % label)
	var stats: Dictionary = mon.get("stats", {})
	for key in ["hp", "atk", "def", "spe", "sat", "sdf"]:
		if int(stats.get(key, 0)) <= 0:
			_failures.append("%s: stat %s not positive" % [label, key])
	var moves: Array = mon.get("moves", [])
	if moves.is_empty() or moves.size() > 4:
		_failures.append("%s: move count %d outside 1..4" % [label, moves.size()])
	for move in moves:
		var move_id := str(move.get("move_id", ""))
		if int(move.get("pp", 0)) <= 0:
			_failures.append("%s: move %s has no PP" % [label, move_id])
		if _catalog().get_move(move_id).is_empty():
			_failures.append("%s: move %s missing from the move catalog" % [label, move_id])


func _audit_starting_bag() -> void:
	for item_id in _runtime().session.STARTING_BAG.keys():
		if _catalog().get_item(str(item_id)).is_empty():
			_failures.append("starting bag item %s missing from the item catalog" % str(item_id))


func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys


func _biome_defs() -> Dictionary:
	return _runtime()._world_gen.BiomeDefs.new().definitions()


func _chart():
	return _runtime().battle_runtime._rules.TypeChart


func _catalog():
	return _runtime().catalog


func _runtime() -> Node:
	return _ctx["runtime"]
