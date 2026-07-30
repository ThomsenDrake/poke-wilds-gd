extends RefCounted

# Phase 7 Build 1 context-Z landmark arms (spec: docs/product-specs/world-depth.md
# § Landmarks) — the precedence tier between overworld entities and camp objects
# (entities -> LANDMARKS -> camp objects -> fish -> harvest -> build). Deliberately THIN:
# every puzzle transition, seam write and trace lives in landmark_runtime (the owning
# source); this dispatches the faced tile, surfaces the result message, and refreshes the
# door tiles the puzzle flipped (world_overridden evicts world_view's tile cache so the
# resolver's walkability overlay re-stamps in place).

var _runtime: Node = null
var _show_message: Callable = Callable()

func setup(runtime: Node, show_message: Callable) -> void:
	_runtime = runtime
	_show_message = show_message

# Z facing a landmark interact target; false when no arm fires (fall through to camp
# objects). A landmark tile with no interact arm (floor/wall) ALSO falls through — harvest
# finds nothing there and the build arm refuses via the landmark_id can_place_on clause.
func route_landmark(faced: Vector2i) -> bool:
	var landmark: Variant = _runtime.get("landmark_runtime") if _runtime != null else null
	if landmark == null or not landmark.has_method("interact"):
		return false
	var result: Variant = landmark.call("interact", faced)
	var response: Dictionary = result if result is Dictionary else {}
	if not bool(response.get("handled", false)):
		return false
	var refresh: Variant = response.get("refresh", [])
	if refresh is Array and not (refresh as Array).is_empty():
		for tile in refresh: # the puzzle flipped door walkability through the seam; re-render both doors
			_runtime.emit_signal("world_overridden", tile)
		_runtime.save_game() # a turned key / opened basement survives reload (spec: the additive-key decision proven)
	if str(response.get("message", "")) != "":
		_show_message.call(str(response.get("message", "")), 2.2)
	return true
