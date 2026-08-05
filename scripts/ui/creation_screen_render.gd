extends RefCounted

# CreationScreen step rendering EXTRACTED from creation_screen.gd at the 220
# ui wall (restyle slice wave 0; the menu_context.gd extraction precedent).
# The SAME step strings as the pre-restyle screen (design §2.2 pin) — only the
# surfaces moved (frame1 interior Title/Value + textbox_bg1 hint band).
# fonts.ttf has no arrow glyphs (verified), so the hint copy rides L/R/U/D —
# never tofu (design §1.3).

const SessionState := preload("res://scripts/runtime/session_state.gd")

const SEED_HINT := "(L/R: enter a custom seed   Z: next)"
const SEED_EDIT_HINT := "Type digits; L/R pick a digit; U/D change it; Backspace deletes. (Z: commit   X: close)"


static func render(screen) -> void:
	if screen._step == screen.STEP_SEED:
		screen._title_label.text = "WORLD SEED"
		screen._value_label.text = screen._digit_row.display_text() if screen._digit_row.editing_active() else screen._seed_line()
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
		screen._value_label.text = "NAME — %s\nPLAYER — %s\nSHINY RATE — 1/%d\nWORLD SEED — %s" % [screen._committed_name(), screen._avatar, int(SessionState.SHINY_ODDS_CHOICES[screen._shiny_index]), screen._seed_line()]
		screen._hint_label.text = "(Z: begin   X: back)"
	screen._hint_label.visible = not screen._overlay_open()
