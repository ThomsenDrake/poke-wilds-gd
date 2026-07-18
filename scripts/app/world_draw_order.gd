extends RefCounted

# Headless render-order model for the world scene, mirroring Godot's
# documented canvas rules: items draw sorted by effective z_index first
# ("nodes sort relative to each other only if they are on the same z_index");
# within one z_index, fully y-sort-enabled chains order by global Y; any
# remaining tie falls back to scene-tree order. world_consistency_audit uses
# it to prove the north/south z-order contract without pixels.


# True when canvas item `a` draws above (later than) item `b`.
static func draws_over(a: CanvasItem, b: CanvasItem) -> bool:
	var z_a := effective_z(a)
	var z_b := effective_z(b)
	if z_a != z_b:
		return z_a > z_b
	var y_a := y_sort_key(a)
	var y_b := y_sort_key(b)
	if not is_nan(y_a) and not is_nan(y_b) and y_a != y_b:
		return y_a > y_b
	return tree_order_after(a, b)


# z_index accumulated through the z_as_relative chain.
static func effective_z(item: CanvasItem) -> int:
	var z := 0
	var node: Node = item
	while node is CanvasItem:
		var canvas := node as CanvasItem
		z += canvas.z_index
		if not canvas.z_as_relative:
			break
		node = canvas.get_parent()
	return z


# The item's global Y when every canvas ancestor is y-sort-enabled, so the
# item joins the shared sort space; NAN when the chain is broken, meaning the
# item renders as one block at its nearest unsorted ancestor's position.
static func y_sort_key(item: CanvasItem) -> float:
	var node := item.get_parent()
	while node is CanvasItem:
		if not (node as CanvasItem).y_sort_enabled:
			return NAN
		node = node.get_parent()
	return item.global_position.y


# Scene-tree order fallback: shared ancestors cancel; at the first diverging
# pair the higher child index draws later (an ancestor draws below its
# descendant).
static func tree_order_after(a: CanvasItem, b: CanvasItem) -> bool:
	var chain_a := _canvas_chain(a)
	var chain_b := _canvas_chain(b)
	var i := 0
	while i < chain_a.size() and i < chain_b.size() and chain_a[i] == chain_b[i]:
		i += 1
	if i >= chain_a.size() or i >= chain_b.size():
		return chain_a.size() > chain_b.size()
	return (chain_a[i] as Node).get_index() > (chain_b[i] as Node).get_index()


static func _canvas_chain(item: CanvasItem) -> Array:
	var chain: Array = []
	var node: Node = item
	while node is CanvasItem:
		chain.push_front(node)
		node = node.get_parent()
	return chain
