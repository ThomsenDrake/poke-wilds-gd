extends RefCounted

const PerformanceMonitors := preload("res://scripts/runtime/performance_monitors.gd")

# Read-only diagnostics service. The controller passes GameRuntime explicitly,
# so capture does not require a marker Node or expand the autoload tree.


static func capture(runtime: Node, screen: String) -> Dictionary:
	var game := state_summary(runtime)
	game["current_screen"] = screen
	return {"save": save_payload(runtime), "runtime": environment_summary(runtime), "game": game}


static func save_payload(runtime: Node) -> Dictionary:
	return runtime.session.to_save_payload(
		runtime._world_gen.overrides_for_save(), runtime._world_gen.placements_for_save())


static func state_summary(runtime: Node) -> Dictionary:
	var session = runtime.session
	var party: Array = []
	for mon_variant in session.party:
		if not mon_variant is Dictionary:
			continue
		var mon: Dictionary = mon_variant
		party.append({
			"species_id": str(mon.get("species_id", "")),
			"level": int(mon.get("level", 1)),
			"hp": int(mon.get("current_hp", mon.get("hp", 0))),
			"max_hp": int(mon.get("max_hp", 0)),
			"status": str(mon.get("status", "")),
		})
	return {
		"current_screen": PerformanceMonitors.screen_label_for(runtime),
		"world_seed": session.world_seed,
		"player_tile": [session.player_tile.x, session.player_tile.y],
		"active_area": session.active_area,
		"time_of_day_minutes": session.time_of_day_minutes,
		"total_steps": session.total_steps,
		"party": party,
		"bag": session.bag.duplicate(true),
		"battle_active": not runtime.battle_runtime.get_snapshot().is_empty(),
	}


static func environment_summary(runtime: Node) -> Dictionary:
	var window := runtime.get_viewport().get_visible_rect().size
	return {
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"os_name": OS.get_name(),
		"os_version": OS.get_version(),
		"architecture": Engine.get_architecture_name(),
		"locale": OS.get_locale(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"window_size": [int(window.x), int(window.y)],
	}
