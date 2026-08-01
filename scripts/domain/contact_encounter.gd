extends RefCounted

# Contact-battle rule (overworld-pokemon.md): with random encounters OFF by default, a wild
# battle starts when the player's overworld sprite COLLIDES with a wild mon — modeled as a
# SHARED TILE (the game is physics-free; "collision" is a tile-coordinate check). Eggs NEVER
# battle on contact (they keep the TAKE/Attack binary only). Pure predicate — the runtime
# (overworld_mons_runtime._check_player_contact) owns the forced-battle seam it feeds.

static func is_battle_contact(entity: Dictionary) -> bool:
	return not entity.is_empty() and str(entity.get("kind", "")) != "egg"
