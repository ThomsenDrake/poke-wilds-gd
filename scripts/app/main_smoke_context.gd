extends RefCounted

# Smoke-context assembly EXTRACTED from main.gd's smoke_context() at the 220
# wall (title_flow slice; the input_router/wild_encounter_draw precedent).
# Scenarios index this dict BY KEY — every key the old smoke_context() carried
# is reproduced EXACTLY, plus the two title-flow screens the new_game_flow
# scenario drives (ctx["title_screen"] / ctx["creation_screen"]). The
# callables stay bound to main because they mutate its fields; the matching
# _smoke_set_battle handler lives there too.

const GAME_RUNTIME_PATH := "/root/GameRuntime"


static func build(main: Node) -> Dictionary:
	var runtime: Node = main.get_node(GAME_RUNTIME_PATH)
	return {
		"world": main.get_node("World"),
		"player": main.get_node("Player"),
		"runtime": runtime,
		"battle_view": main.get_node("UI/BattleView"),
		"start_menu": main.get_node("UI/StartMenu"), "camp_menu": main.get_node("UI/CampMenu"),
		"message_box": main.get_node("UI/MessageBox"),
		"music_router": runtime.music_router,
		"structure_layer": main.get_node("StructureLayer"),
		"title_screen": main.get_node("UI/TitleScreen"),
		"creation_screen": main.get_node("UI/CreationScreen"),
		"toggle_menu": Callable(main, "_toggle_menu"),
		"set_battle": Callable(main, "_smoke_set_battle"), "field_move": Callable(main, "_on_field_move_requested")
	}
