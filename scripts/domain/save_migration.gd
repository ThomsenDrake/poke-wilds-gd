extends RefCounted

# PURE save-shape migration. v6 (infinite-world slice) RETIRES the v5 world-chaining model
# for a single seamless plane: a save no longer carries root_seed/active_chain/chained_worlds
# and landmark_state returns to its v4 top-level seat. migrate(payload, 6) FLATTENS a
# chain-less v4/v5 save losslessly — the delta on a chain-less save is EXACTLY {version: 6}
# (the v5 chain keys are added then dropped, a landmark_state nest is added then hoisted back
# to top-level — net identity). A TRULY CHAINED v5 save (active_chain != "0,0" OR a non-origin
# chained_worlds entry) is structurally unrepresentable on one plane: can_represent_infinite
# gates the load path, which REFUSES + PRESERVES it non-destructively (the .newer.bak
# precedent) and starts fresh — never a destructive flatten.
#
# migrate() returns a DEEP COPY: GDScript Dictionaries are BY-REFERENCE, so an in-place
# transform would silently fake the golden compare by aliasing.
#
# NO preload cycle: this module imports NOTHING from runtime — the schema constant
# (SAVE_VERSION) is passed as an argument (the session_payload.gd sibling pattern;
# session_state.gd stays the single owner of the schema constants).

# The chain-key grammar (retained for parsing LEGACY v5 saves on the refusal path): the
# BARE "<cx>,<cy>" form. Malformed ids degrade to the origin, never crash.
static func world_id_for(chain: Vector2i) -> String:
	return "%d,%d" % [chain.x, chain.y]


static func chain_for(world_id: String) -> Vector2i:
	var parts := world_id.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(parts[0].to_int(), parts[1].to_int())


# Payload -> v6 payload as a deep COPY; the argument is NEVER mutated.
#   version >= save_version: pass-through (still a copy) — OR the newer-build refusal shape;
#   version < 5 (or ABSENT — the frozen golden has NO version key): bring to v5 shape first
#     (add chain identity root_seed/active_chain "0,0"/chained_worlds {}, nesting a top-level
#     landmark_state under chained_worlds["0,0"].landmark_state) — the legacy v4->v5 move;
#   then v5 -> v6 FLATTEN: drop root_seed/active_chain/chained_worlds and hoist the origin
#     landmark_state back to the top-level seat (the exact inverse of the v5 relocation).
# Callers gate CHAINED saves on can_represent_infinite BEFORE this (a chained save is
# refused + preserved, never flattened). The save_version DEFAULT mirrors
# SessionState.SAVE_VERSION (a direct import would be a preload cycle); EVERY call site
# passes the constant explicitly, so the default is the cycle-guard fallback, never relied on.
static func migrate(payload: Dictionary, save_version: int = 6) -> Dictionary:
	var out: Dictionary = payload.duplicate(true)
	if int(out.get("version", 1)) >= save_version:
		return out # v6 pass-through (still a copy) OR the newer-build refusal shape
	if int(out.get("version", 1)) < 5:
		out["root_seed"] = int(out.get("world_seed", 1337))
		out["active_chain"] = world_id_for(Vector2i.ZERO)
		var nested: Dictionary = {}
		if out.has("landmark_state"):
			nested[world_id_for(Vector2i.ZERO)] = {"landmark_state": out["landmark_state"]}
			out.erase("landmark_state")
		out["chained_worlds"] = nested
	var chained: Variant = out.get("chained_worlds", {})
	out.erase("root_seed")
	out.erase("active_chain")
	out.erase("chained_worlds")
	if chained is Dictionary:
		var origin: Variant = (chained as Dictionary).get(world_id_for(Vector2i.ZERO), {})
		if origin is Dictionary and (origin as Dictionary).has("landmark_state"):
			out["landmark_state"] = (origin as Dictionary)["landmark_state"]
	out["version"] = save_version
	return out


# True when a (legacy) payload is representable on the single infinite plane: the active
# world is the origin AND chained_worlds carries AT MOST the origin nest holding ONLY a
# landmark_state (any other per-world state — maps, campsite, pastures, player position —
# has no single-plane seat). The load path REFUSES + preserves a payload that fails this.
static func can_represent_infinite(payload: Dictionary) -> bool:
	if str(payload.get("active_chain", world_id_for(Vector2i.ZERO))) != world_id_for(Vector2i.ZERO):
		return false # a non-origin active world cannot be flattened to one plane
	return can_downshift(payload)


# The lossless-boundary predicate (also the update-mode golden guard): chained_worlds holds
# at most the origin nest holding only a landmark_state.
static func can_downshift(payload: Dictionary) -> bool:
	var chained: Variant = payload.get("chained_worlds", {})
	if not (chained is Dictionary):
		return false
	for key in (chained as Dictionary).keys():
		if str(key) != world_id_for(Vector2i.ZERO):
			return false # a non-origin chained world has NO single-plane seat
		var entry: Variant = (chained as Dictionary)[key]
		if not (entry is Dictionary):
			return false
		var fields: Array = (entry as Dictionary).keys()
		if fields.size() > 1 or (fields.size() == 1 and str(fields[0]) != "landmark_state"):
			return false # origin MAPS keep v4 top-level keying — never nested
	return true


# v6 -> v4 shape (save_stability's update-mode guard): the golden always regenerates as the
# v4-shape MIGRATION WITNESS migrate() has work to do on (NO version/chain keys, landmark_state
# top-level). Drops the version + any chain keys and hoists an origin landmark_state nest back
# up (a flat v6 payload passes through unchanged but for the dropped version key).
static func downshift(payload: Dictionary) -> Dictionary:
	var out: Dictionary = payload.duplicate(true)
	out.erase("version")
	out.erase("root_seed")
	out.erase("active_chain")
	var chained: Variant = out.get("chained_worlds", {})
	out.erase("chained_worlds")
	if chained is Dictionary:
		var origin: Variant = (chained as Dictionary).get(world_id_for(Vector2i.ZERO), {})
		if origin is Dictionary and (origin as Dictionary).has("landmark_state"):
			out["landmark_state"] = (origin as Dictionary)["landmark_state"]
	return out


# --- Pinned byte-preservation witnesses ---------------------------------------------
# PURE + runtime-free; the phase0 save_migration checker calls this with the committed
# golden + SessionState.SAVE_VERSION. Returns issue strings (empty = green) so a red NAMES
# the drift (miss-002).
static func byte_witness_issues(golden_v4: Dictionary, save_version: int) -> Array:
	var issues: Array = []
	# PRECONDITION pin: the witness fixture MUST stay v4-shaped (no version/chain keys, no
	# landmark_state). A v6-shaped golden would make migrate() a no-op and green the proof
	# forever while proving nothing (the update-mode can_downshift refusal guards the
	# automated path; this guards the fixture itself).
	for key in ["version", "root_seed", "active_chain", "chained_worlds", "landmark_state"]:
		if golden_v4.has(key):
			issues.append("golden: the fixture carries '%s' — the witness MUST stay v4-shaped (migrate() would no-op and the proof would degenerate)" % str(key))
	# PRIMARY witness: migrate() adds EXACTLY {version} — the v6 flatten is the identity on a
	# chain-less save (the v5 chain keys are added then dropped; a landmark_state nest would be
	# added then hoisted back). Snapshot FIRST so an in-place migrate() (argument aliasing) is
	# caught rather than passing vacuously.
	var before := golden_v4.duplicate(true)
	var migrated := migrate(golden_v4, save_version)
	if golden_v4 != before:
		issues.append("golden: migrate() MUTATED its argument (GDScript dicts are by-reference — it must deep-copy)")
	var expected: Dictionary = golden_v4.duplicate(true)
	expected["version"] = save_version
	if migrated != expected:
		issues.append("golden: migrate() changed more than the version key (the v6 flatten must be the identity on a chain-less save)")
	if int(migrated.get("version", 0)) != save_version:
		issues.append("golden: the migrated payload is not version %d" % save_version)
	# SECOND witness: a v4 top-level landmark_state survives migration BYTE-VERBATIM at the
	# top level (the v5 nest+hoist is the identity), NO chain keys survive, argument untouched.
	var state := {"pkmn_mansion": {"statues": [true, false, true], "unlocked": false, "key_taken": false}}
	var v4 := {"version": 4, "world_seed": 555, "landmark_state": state.duplicate(true)}
	var moved := migrate(v4, save_version)
	if not moved.has("landmark_state") or (moved["landmark_state"] as Dictionary) != state:
		issues.append("relocation: the top-level landmark_state is not byte-identical after migration")
	if moved.has("chained_worlds") or moved.has("root_seed") or moved.has("active_chain"):
		issues.append("relocation: a chain key survived the v6 flatten")
	if not v4.has("landmark_state") or int(v4.get("version", 0)) != 4:
		issues.append("relocation: migrate() MUTATED its argument (GDScript dicts are by-reference — it must deep-copy)")
	# REFUSAL witness: a truly chained v5 save is NOT representable on one plane, while a
	# chain-less v5 save IS (lossless flatten).
	var chained := {"version": 5, "world_seed": 555, "root_seed": 555, "active_chain": "0,-1",
		"chained_worlds": {"0,0": {"structures": {"30,40": {"kind": "placed", "structure_id": "fence", "by": "build", "step": 0}}}}}
	if can_represent_infinite(chained):
		issues.append("refusal: a truly chained v5 save (active_chain 0,-1) must NOT be representable on the infinite plane")
	var chainless := {"version": 5, "world_seed": 555, "root_seed": 555, "active_chain": "0,0", "chained_worlds": {}}
	if not can_represent_infinite(chainless):
		issues.append("refusal: a chain-less v5 save must be representable (lossless flatten)")
	return issues
