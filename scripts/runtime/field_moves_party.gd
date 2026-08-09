extends RefCounted

# The canonical ALL-FIELD-MOVES playtest party (Phase 4; spec: field-moves.md).
#
# A shared FIXTURE — a constant + swap-in helper, NOT a save fixture. A save
# fixture (visual_sweep_baselines.craft_state's write_payload + apply_loaded_state)
# resets the bag/clock/steps and never re-seeds the runtime generator, so the
# harvest/encounter playtests built on it would run on a torn world — the exact
# pitfall harvest_flow's header documents. A swap-in leaves the seeded generator +
# bag intact, which is what the field-move + building playtests need. No
# save-migration work: the fixture rides the existing session.party shape.
#
# The six species are the verified MINIMUM cover (DP-optimal = 6) of all 13 ported
# field moves, computed from the real catalog flags (assets/source/pokemon/*/wilds_data.asm
# db flags + base_stats.asm types) under FieldMoves.can_perform semantics (flag 1
# able / 2 force-unable, else AUTO_TYPES by type; surf = final-stage WATER). The
# user-named trio anchors it — Rhyperior = Smash/Dig/Ride/Surf, Charizard = Flash/
# Fly, Machop = Build — and Calyrex/Dedenne/Drapion fill cut+teleport, charm+power,
# attack+repel. Every six resolves in pokemon_catalog (folder-derived id), is
# encounter-eligible (front+back+catch_rate>0+learnset), and carries NO force-unable
# (flag==2) move it is meant to cover.
#
# ADOPTION (the house's universal party-craft path): scenarios + the playtest bot
# drive it through smoke_scenario_runner.swap_party
#     runner.swap_party(runtime, FieldMovesParty.FIELD_MOVES_PARTY, FieldMovesParty.PARTY_LEVEL)
# or the per-spec-level helper below (FieldMovesParty.swap_in), and RESTORE on every
# exit. The first act of any scenario built on it is the precondition witness
# (FieldMovesParty.verify(runtime) == []) so catalog / AUTO_TYPES drift fails LOUD
# instead of vacuously passing on a silently-short party.

const FieldMoves := preload("res://scripts/domain/field_moves.gd")

# All 13 ported field moves the party must collectively perform. (The exec plan's
# "12" is an off-by-one: 8 zero-caller + 5 live = 13. headbutt/paint/follow are in
# the asm flag block but NOT in the ported set.)
const ALL_FIELD_MOVES: PackedStringArray = [
	"cut", "dig", "smash", "surf", "flash", "build",
	"charm", "repel", "attack", "teleport", "fly", "ride", "power"
]

# Shared default level every member is built at unless PARTY_SPEC pins one: high
# enough for a full 4-move level-up set + the level-gated Charm pacify hook, well
# under the 100 cap. Scenarios may pass their own level to swap_party instead.
const PARTY_LEVEL := 50

# Per-member attribution, in party order. `field_moves` documents the cover and
# powers the precondition witness — it is the species CAPABILITY, NOT the battle
# moveset: battle moves derive from the learnset via create_pokemon_instance, while
# field moves are a type/flag capability separate from battle moves in this port.
const PARTY_SPEC := [
	{"species_id": "RHYPERIOR", "level": 50, "field_moves": ["dig", "smash", "surf", "ride"]},
	{"species_id": "CHARIZARD", "level": 50, "field_moves": ["flash", "fly"]},
	{"species_id": "MACHOP", "level": 50, "field_moves": ["build"]},
	{"species_id": "CALYREX", "level": 50, "field_moves": ["cut", "teleport"]},
	{"species_id": "DEDENNE", "level": 50, "field_moves": ["charm", "power"]},
	{"species_id": "DRAPION", "level": 50, "field_moves": ["repel", "attack"]},
]

# The species-id list for smoke_scenario_runner.swap_party (folder-derived catalog
# ids; get_species uppercases its arg, so these resolve directly).
const FIELD_MOVES_PARTY: PackedStringArray = [
	"RHYPERIOR", "CHARIZARD", "MACHOP", "CALYREX", "DEDENNE", "DRAPION"
]


# Fresh instances for every PARTY_SPEC member, built through the same path
# swap_party uses (catalog.get_species + pokemon_rules.create_pokemon_instance),
# each at its pinned level. Unresolved species are SKIPPED here — verify() turns
# that skip into a loud red, never a silent short party.
static func build_party(runtime) -> Array:
	var party: Array = []
	var get_move := Callable(runtime.catalog, "get_move")
	for entry in PARTY_SPEC:
		var species: Dictionary = runtime.catalog.get_species(str(entry.get("species_id", "")))
		if species.is_empty():
			continue
		party.append(runtime.pokemon_rules.create_pokemon_instance(species, int(entry.get("level", PARTY_LEVEL)), get_move))
	return party


# Swap the fixture party into the session, returning the previous party for
# restore (mirror of smoke_scenario_runner.swap_party, at per-spec levels).
static func swap_in(runtime) -> Array:
	var previous: Array = runtime.session.party
	runtime.session.party = build_party(runtime)
	return previous


static func restore(runtime, previous: Array) -> void:
	runtime.session.party = previous


# Field moves the CURRENT session party CANNOT perform ([] == the full 13-move
# cover holds). Mirrors game_runtime.party_has_field_move_ability per move, so any
# catalog / AUTO_TYPES drift surfaces as a named red. Call AFTER swap_in.
static func uncovered_moves(runtime) -> Array:
	var uncovered: Array = []
	for move_id in ALL_FIELD_MOVES:
		if not runtime.party_has_field_move_ability(str(move_id)):
			uncovered.append(str(move_id))
	return uncovered


# PARTY_SPEC species ids that do not resolve in the live catalog ([] == all six
# present). A non-empty result means the cover would be silently short — fail loud.
static func unresolved_species(runtime) -> Array:
	var missing: Array = []
	for entry in PARTY_SPEC:
		if runtime.catalog.get_species(str(entry.get("species_id", ""))).is_empty():
			missing.append(str(entry.get("species_id", "")))
	return missing


# Full precondition witness for a scenario's first act (call AFTER swap_in): [] when
# the fixture is sound — all six resolve, the party is six strong, all 13 moves
# covered — otherwise a list of human-readable problems to push_error on.
static func verify(runtime) -> Array:
	var problems: Array = []
	for species_id in unresolved_species(runtime):
		problems.append("species %s does not resolve in pokemon_catalog" % species_id)
	if runtime.session.party.size() != PARTY_SPEC.size():
		problems.append("party has %d members, expected %d" % [runtime.session.party.size(), PARTY_SPEC.size()])
	for move_id in uncovered_moves(runtime):
		problems.append("no party member can perform %s" % move_id)
	return problems
