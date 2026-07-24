extends RefCounted

# Time-of-day phase model (spec: docs/product-specs/camping-crafting-survival.md).
# Pure data + rules, the SINGLE SOURCE OF TRUTH for the in-game clock's day/night
# bounds — mirroring world_view.gd's TIME_OF_DAY_KEYFRAMES (the presentation tint
# keeps its own copy for rendering; the night_cycle scenario asserts the boundary
# minutes agree so the two cannot drift silently).
#
# Minutes are minutes-since-midnight, wrapped to [0, 1440) by session_state. Night
# runs 20:30 (1230) -> 04:30 (270); dawn / day / dusk are all "DAY" for gameplay
# gates (Espeon's MORNDAY happiness evolution = morning+day hours is the faithful
# reading, so dawn counts as DAY). The wiki Time page is an empty stub, so the exact
# windows are a documented port decision pinned to the tint keyframes.

const NIGHT_START := 1230 # 20:30
const NIGHT_END := 270 # 04:30
const DAWN_END := 480 # 08:00 (dawn keyframe band upper bound)
const DUSK_START := 1020 # 17:00
const WAKE_MINUTES := 420 # 07:00 — where a night rest lands you (inside the dawn band)


# True when `minutes` is inside the night band (~20:30-04:30).
static func is_night(minutes: int) -> bool:
	return minutes >= NIGHT_START or minutes < NIGHT_END


# The evolution / battle gate label: "NIGHT" in the night band, else "DAY" (dawn,
# day and dusk all map to DAY — documented port decision). Fed into
# pokemon_rules.check_level_evolution's context["time_of_day"].
static func time_of_day_label(minutes: int) -> String:
	return "NIGHT" if is_night(minutes) else "DAY"


# Fine-grained phase for tint-adjacent queries ("night"|"dawn"|"day"|"dusk").
static func phase_for(minutes: int) -> String:
	if is_night(minutes):
		return "night"
	if minutes < DAWN_END:
		return "dawn"
	if minutes >= DUSK_START:
		return "dusk"
	return "day"
