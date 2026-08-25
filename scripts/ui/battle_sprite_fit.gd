extends RefCounted

# Battle slot policy: native-centered when the cropped frame fits, aspect-centered
# only when it overflows so 40px fronts stay sharp and 64–80px sheets still fit.


static func apply(rect: TextureRect) -> void:
	var mode := expected(rect)
	if mode >= 0:
		rect.stretch_mode = mode


static func expected(rect: TextureRect) -> int:
	var tex := rect.texture
	if tex == null:
		return -1
	var overflow := tex.get_width() > int(rect.size.x) or tex.get_height() > int(rect.size.y)
	return TextureRect.STRETCH_KEEP_ASPECT_CENTERED if overflow else TextureRect.STRETCH_KEEP_CENTERED


static func audit(stage: Node, fail: Callable) -> void:
	for n in ["EnemySprite", "PlayerSprite"]:
		var rect: TextureRect = stage.get_node(n)
		if rect.texture != null and rect.stretch_mode != expected(rect):
			fail.call("%s stretch_mode does not fit its frame" % n)
