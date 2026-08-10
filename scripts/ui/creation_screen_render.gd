extends RefCounted

# CreationScreen step rendering EXTRACTED from creation_screen.gd at the 220
# ui wall (restyle slice wave 0; the menu_context.gd extraction precedent).
# The SAME step strings as the pre-restyle screen (design §2.2 pin) — only the
# surfaces moved (frame1 interior Title/Value + textbox_bg1 hint band).
# fonts.ttf has no arrow glyphs (verified), so the hint copy rides L/R/U/D —
# never tofu (design §1.3).

const SessionState := preload("res://scripts/runtime/session_state.gd")
const CreationStage := preload("res://scripts/ui/creation_screen_stage.gd")

const SEED_HINT := "(L/R: enter a custom seed   Z: next)"
const SEED_EDIT_HINT := "Type digits; L/R pick a digit; U/D change it; Backspace deletes. (Z: commit   X: close)"
const FRAME_INTERIOR := CreationStage.FRAME_RECT # single-sourced at the stage (it owns the frame art)
const TITLE_VALUE_GAP := 2.0


# Scenario seams (restyle design §2.2; the old Panel/Margin/VBox node reads) —
# moved here with the step strings at creation_screen.gd's second 220 wall, so
# the app readers (new_game_flow_checks / visual_sweep_title / play_agent) read
# the same module that renders the labels.
static func step_title_label(screen) -> Label: return screen._title_label
static func step_value_label(screen) -> Label: return screen._value_label
static func seed_edit_active(screen) -> bool: return screen._step == screen.STEP_SEED and screen._digit_row.editing_active() # the old SeedPrompt-visible witness
static func committed_name(screen) -> String: return SessionState.DEFAULT_PLAYER_NAME if screen._name.is_empty() else screen._name
static func seed_line(screen) -> String: return "RANDOM" if screen._seed < 0 else str(screen._seed)


static func render(screen) -> void:
	if screen._step == screen.STEP_SEED:
		screen._title_label.text = "WORLD SEED"
		screen._value_label.text = screen._digit_row.display_text() if screen._digit_row.editing_active() else seed_line(screen)
		screen._hint_label.text = SEED_EDIT_HINT if screen._digit_row.editing_active() else SEED_HINT
	elif screen._step == screen.STEP_SHINY:
		var odds := int(SessionState.SHINY_ODDS_CHOICES[screen._shiny_index])
		screen._title_label.text = "SHINY RATE"
		screen._value_label.text = "1/%d (DEFAULT)" % odds if odds == SessionState.SHINY_ODDS_DEFAULT else "1/%d" % odds
		screen._hint_label.text = "(L/R: change  Z: next)"
	elif screen._step == screen.STEP_NAME:
		screen._title_label.text = "NAME"
		screen._value_label.text = screen._name if not screen._name.is_empty() else "(none — Z to enter)"
		screen._hint_label.text = "(Z: enter name   X: back)"
	elif screen._step == screen.STEP_AVATAR:
		screen._title_label.text = "PLAYER"
		screen._value_label.text = screen._avatar
		screen._hint_label.text = "(Z: choose avatar   X: back)"
	elif screen._step == screen.STEP_GO:
		screen._title_label.text = "Go!" # i18n go, verbatim (FLAGGED: hardcoded)
		screen._value_label.text = "NAME — %s\nPLAYER — %s\nSHINY RATE — 1/%d\nWORLD SEED — %s" % [committed_name(screen), screen._avatar, int(SessionState.SHINY_ODDS_CHOICES[screen._shiny_index]), seed_line(screen)]
		screen._hint_label.text = "(Z: begin   X: back)"
	screen._hint_label.visible = not screen._overlay_open()


# Vertically centers the title+value block within the baked frame: single-line
# steps used to top-anchor in the 80px-tall frame and leave it ~75% empty.
# MUST run deferred (creation_screen._render): get_line_count reflects autowrap
# only after a layout pass, and the SHINY value + GO summary do wrap.
static func center_block(screen) -> void:
	var value_label: Label = screen._value_label
	var title_label: Label = screen._title_label
	var value_lines: int = maxi(1, value_label.get_line_count())
	var block_h: float = title_label.get_line_height() + TITLE_VALUE_GAP + value_lines * value_label.get_line_height()
	var top: float = FRAME_INTERIOR.position.y + (FRAME_INTERIOR.size.y - block_h) / 2.0
	title_label.position.y = top
	value_label.position.y = top + title_label.get_line_height() + TITLE_VALUE_GAP
	value_label.size.y = value_lines * value_label.get_line_height()
