extends RefCounted

# Phase 7 Build 3 — PURE save-shape migration (world-depth.md § Save v5). v5 is the
# first real bump since v2: a world_id RE-KEYING is structural (additive keys alone
# never move fields). Reconciliation (FROZEN): the ACTIVE world keeps v4 keying
# EXACTLY — its 14 golden top-level keys stay untouched in place; only NON-active
# chained worlds are world_id-scoped, under the additive chained_worlds dict keyed by
# the BARE chain string "<cx>,<cy>" (world_id_for — ONE grammar shared by
# chained_worlds keys, active_chain and the legendary_removals chain tag; NO w prefix
# anywhere). The ONE keying move: a v4 top-level landmark_state (when present)
# relocates BYTE-VERBATIM into chained_worlds["0,0"].landmark_state.
#
# migrate() returns a DEEP COPY: GDScript Dictionaries are BY-REFERENCE, so an
# in-place transform would silently fake the golden compare by aliasing
# (canonical(migrate(golden)) == canonical(golden) would pass VACUOUSLY).
#
# NO preload cycle: this module imports NOTHING from runtime — the schema constant
# (SAVE_VERSION) is passed as an argument (the session_payload.gd sibling pattern;
# session_state.gd stays the single owner of the schema constants).

# The ONE chain-key grammar (world-depth.md § Pinned constants): chained_worlds keys
# (the per-world landmark_state nest included), active_chain, legendary_removals
# chain tags. BARE "<cx>,<cy>" — NO w prefix anywhere.
static func world_id_for(chain: Vector2i) -> String:
	return "%d,%d" % [chain.x, chain.y]


# The inverse parse (same grammar); malformed ids degrade to the origin, never crash.
static func chain_for(world_id: String) -> Vector2i:
	var parts := world_id.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(parts[0].to_int(), parts[1].to_int())


# Payload -> v5 payload as a deep COPY; the argument is NEVER mutated.
#   version <= 4 (or ABSENT — the frozen golden has NO version key): add the chain
#     identity (root_seed := world_seed, active_chain "0,0", chained_worlds {}),
#     relocate a top-level landmark_state BYTE-VERBATIM under
#     chained_worlds["0,0"].landmark_state (dropping the top-level key — the single
#     v4 field that moves), leave every other key in place, set version := save_version;
#   version == save_version: pass-through (still a copy);
#   version > save_version: untouched copy (save_store.gd's .newer.bak refusal owns
#     this path — it never reaches the apply seam in normal play).
# The save_version DEFAULT mirrors SessionState.SAVE_VERSION (a direct import would be
# a preload cycle — see the header); EVERY call site passes the constant explicitly
# (session_payload.gd's seam + save_stability's golden guard), so the default is the
# cycle-guard fallback, never relied on — a schema bump moves all callers together.
static func migrate(payload: Dictionary, save_version: int = 5) -> Dictionary:
	var out: Dictionary = payload.duplicate(true)
	if int(out.get("version", 1)) >= save_version:
		return out # v5 pass-through (still a copy) OR the newer-build refusal shape
	out["root_seed"] = int(out.get("world_seed", 1337))
	out["active_chain"] = world_id_for(Vector2i.ZERO)
	var chained: Dictionary = {}
	if out.has("landmark_state"):
		# The value is carried verbatim (already inside the deep copy); only the
		# keying changes. Origin puzzle state joins the pinned "<cx>,<cy>" keying.
		chained[world_id_for(Vector2i.ZERO)] = {"landmark_state": out["landmark_state"]}
		out.erase("landmark_state")
	out["chained_worlds"] = chained
	out["version"] = save_version
	return out


# The BYTE-VERBATIM inverse of migrate()'s keying move (save_stability's update-mode
# guard): strips the three identity keys and relocates
# chained_worlds["0,0"].landmark_state BACK to the v4 top-level seat, so the committed
# golden regenerates as the v4-shape MIGRATION WITNESS. Lossless ONLY when
# chained_worlds carries AT MOST the origin nest holding ONLY a landmark_state (a
# chained session cannot downshift — callers gate on can_downshift and trace the
# refusal; the witness must always be a payload migrate() has work to do on).
static func can_downshift(payload: Dictionary) -> bool:
	var chained: Variant = payload.get("chained_worlds", {})
	if not (chained is Dictionary):
		return false
	for key in (chained as Dictionary).keys():
		if str(key) != world_id_for(Vector2i.ZERO):
			return false # a non-origin chained world has NO v4 seat
		var entry: Variant = (chained as Dictionary)[key]
		if not (entry is Dictionary):
			return false
		var fields: Array = (entry as Dictionary).keys()
		if fields.size() > 1 or (fields.size() == 1 and str(fields[0]) != "landmark_state"):
			return false # origin MAPS keep v4 top-level keying — never nested
	return true


static func downshift(payload: Dictionary) -> Dictionary:
	var out: Dictionary = payload.duplicate(true)
	out.erase("root_seed")
	out.erase("active_chain")
	var chained: Variant = out.get("chained_worlds", {})
	out.erase("chained_worlds")
	if chained is Dictionary:
		var origin: Variant = (chained as Dictionary).get(world_id_for(Vector2i.ZERO), {})
		if origin is Dictionary and (origin as Dictionary).has("landmark_state"):
			out["landmark_state"] = (origin as Dictionary)["landmark_state"]
	return out


# --- Pinned byte-preservation witnesses (world-depth.md § Save v5) -----------------
# PURE + runtime-free; the phase0 save_migration v5 checker calls this with the
# committed golden + SessionState.SAVE_VERSION. Returns issue strings (empty = green)
# so a red NAMES the drift (miss-002).
static func byte_witness_issues(golden_v4: Dictionary, save_version: int) -> Array:
	var issues: Array = []
	# PRECONDITION pin: the witness fixture MUST be v4-shaped. A hand-edited v5-shaped
	# golden (identity keys, NO version key) would read as version 1 and make migrate()
	# OVERWRITE the same keys it already carries — a silent no-op that greens every
	# witness below while proving nothing (the update-mode can_downshift refusal guards
	# the automated path; this guards the fixture itself).
	for key in ["version", "root_seed", "active_chain", "chained_worlds", "landmark_state"]:
		if golden_v4.has(key):
			issues.append("golden: the fixture carries '%s' — the witness MUST stay v4-shaped (migrate() would no-op and the proof would degenerate)" % str(key))
	# PRIMARY witness: migrate() adds EXACTLY the three identity keys — root_seed ==
	# the golden world_seed (world_seed_for(root,(0,0)) == root is FROZEN), active_chain
	# "0,0", chained_worlds {} — and leaves every golden top-level key deep-equal.
	# The snapshot FIRST makes this witness self-protecting against argument aliasing:
	# an in-place migrate() would mutate golden_v4, `expected` (derived from it) would
	# inherit the mutation, and the compare would pass VACUOUSLY.
	var before := golden_v4.duplicate(true)
	var migrated := migrate(golden_v4, save_version)
	if golden_v4 != before:
		issues.append("golden: migrate() MUTATED its argument (GDScript dicts are by-reference — it must deep-copy)")
	var expected: Dictionary = golden_v4.duplicate(true)
	expected["root_seed"] = int(expected.get("world_seed", 1337))
	expected["active_chain"] = world_id_for(Vector2i.ZERO)
	expected["chained_worlds"] = {}
	expected["version"] = save_version
	if migrated != expected:
		issues.append("golden: migrate() changed more than the three identity keys (root_seed/active_chain/chained_worlds)")
	if int(migrated.get("root_seed", 0)) != int(golden_v4.get("world_seed", -1)):
		issues.append("golden: root_seed != the golden world_seed (origin identity world_seed_for(root,(0,0)) == root is frozen)")
	# SECOND witness: a v4 top-level landmark_state relocates BYTE-VERBATIM under
	# chained_worlds["0,0"].landmark_state with the top-level key dropped — AND the
	# argument is left untouched (the deep-copy purity guard against aliasing).
	var state := {"pkmn_mansion": {"statues": [true, false, true], "unlocked": false, "key_taken": false}}
	var v4 := {"version": 4, "world_seed": 555, "landmark_state": state.duplicate(true)}
	var moved := migrate(v4, save_version)
	var origin_entry: Variant = moved.get("chained_worlds", {}).get(world_id_for(Vector2i.ZERO), {})
	var nested: Variant = (origin_entry as Dictionary).get("landmark_state", {}) if origin_entry is Dictionary else {}
	if moved.has("landmark_state"):
		issues.append("relocation: the top-level landmark_state survived migration")
	if not (nested is Dictionary) or (nested as Dictionary) != state:
		issues.append("relocation: chained_worlds[\"0,0\"].landmark_state is not byte-identical to the v4 value")
	if not v4.has("landmark_state") or v4.has("chained_worlds") or int(v4.get("version", 0)) != 4:
		issues.append("relocation: migrate() MUTATED its argument (GDScript dicts are by-reference — it must deep-copy)")
	return issues
