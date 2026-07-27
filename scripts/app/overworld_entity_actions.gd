extends RefCounted

# Phase 6 overworld context-Z arms (spec: docs/product-specs/overworld-pokemon.md),
# extracted from field_action_router.gd (at its 219/220 wall) so the router can spend
# the freed lines on the entity-first precedence (entities -> camp objects -> fishing
# -> harvest -> build). A mon's Z routes to the dialogue-recruit runtime path (interact
# owns the refusal / warning / provocation wording + traces); a wild egg's Z is the TAKE
# arm (egg_stolen + provocation; the guardian's forced battle rides the pending-encounter
# seam through main's normal presentation). Attack-on-egg (the :248 shiny-check + clear)
# rides field_move_actions' Attack arm instead — never Z. The Phase 5 fence pen action
# moved here with the arms so the router keeps one delegation per precedence tier.
# Reads the entity runtime via Object semantics (it is a RefCounted, NOT a Node — the
# entity_layer convention); an inert subsystem (the activation opt-out leaves every
# non-opt-in smoke scenario entity-free) has an empty store, so route_entity falls
# through to the camp-object tier — baseline protection by construction.

var _runtime: Node = null
var _player: Node = null
var _show_message: Callable = Callable()

func setup(runtime: Node, player: Node, show_message: Callable) -> void:
	_runtime = runtime
	_player = player
	_show_message = show_message

# Z facing an overworld entity; false when the tile holds none (fall through).
func route_entity(faced: Vector2i) -> bool:
	var mons := _mons()
	if mons == null:
		return false
	var entity: Variant = mons.call("entity_at", faced)
	if not (entity is Dictionary) or (entity as Dictionary).is_empty():
		return false
	var result: Variant = mons.call("interact", faced) # mon -> recruit path; egg -> egg_take
	var response: Dictionary = result if result is Dictionary else {}
	if str(response.get("message", "")) != "":
		_show_message.call(str(response.get("message", "")), 1.8)
	return true

# Phase 5 breeding fence Z (moved verbatim from field_action_router._pen_action): pick
# up a pen ground egg (priority) or withdraw the latest penned mon; an empty message
# falls through (breeding_interact reads the pen interior beyond the fence).
func pen_action(tile: Vector2i) -> bool:
	if _runtime == null or not _runtime.has_method("breeding_interact"):
		return false
	var result: Variant = _runtime.call("breeding_interact", _player.tile_position, tile)
	if not (result is Dictionary) or str((result as Dictionary).get("message", "")).is_empty():
		return false
	_show_message.call(str((result as Dictionary).get("message", "")), 1.6)
	return true

func _mons() -> Object:
	if _runtime == null or not ("overworld_mons_runtime" in _runtime):
		return null
	var value: Variant = _runtime.get("overworld_mons_runtime")
	return value if value is Object and (value as Object).has_method("entity_at") else null
