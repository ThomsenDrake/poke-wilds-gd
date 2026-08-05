extends RefCounted

# On-screen GEOMETRY witnesses for new_game_flow (restyle slice; the red-before
# proof carriers). The ce1571b overlays called set_anchors_preset(PRESET_FULL_RECT)
# on freshly new()'d 0x0 Controls, which Godot 4.6 RECT-PRESERVES into a permanent
# 0x0 pin — the center-anchored plates then rendered three-quarters OFF-window
# (the human playtest never saw the name grid; only the hint tail poked in).
# These witnesses fail RED on that collapse and pass once the plate sits fully
# on-screen (the GBC stage idiom of the restyle makes the class impossible:
# stage children carry explicit integer offsets only).
#
# check() is called while the overlay is OPEN; the plate is the overlay's
# PanelContainer today and the restyled widget's plate() after the restyle
# (the overlay exposes a `plate` member in both eras where possible).

func check(overlay: Control, tag: String, failures: Array) -> void:
	var plate: Control = _find_plate(overlay)
	if plate == null:
		failures.append("geo: the %s overlay exposes no plate (member 'plate' or a PanelContainer child)" % tag)
		return
	var rect := plate.get_global_rect()
	var win := overlay.get_viewport().get_visible_rect()
	if rect.size.x < 100 or rect.size.y < 80 or win.intersection(rect) != rect:
		failures.append("geo: the %s plate %s is not fully on-screen in %s (the 0x0-root anchor collapse)" % [tag, str(rect), str(win)])

# Prefer an explicit `plate` member (the restyled stage widgets); else walk the
# subtree for the first PanelContainer (the pre-restyle overlays built theirs
# anonymously). Keeps the witness meaningful across both eras.
func _find_plate(overlay: Control) -> Control:
	var member = overlay.get("plate")
	if member is Control:
		return member
	var stack: Array = overlay.get_children()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is PanelContainer:
			return node
		stack.append_array(node.get_children())
	return null
