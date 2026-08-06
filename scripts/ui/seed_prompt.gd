extends Control

# NEW GAME's custom world-seed entry, added by StartMenu at runtime (no scene
# node: start_menu.gd sits at the 220 ui wall — the menu_context.gd extraction
# precedent), restyled onto the GBC stage idiom (restyle slice wave 2): an
# opaque black backing + the 160x144 gbc_stage, a centered white plate, and the
# seed digit row (scripts/ui/gbc_digit_row.gd — its typed-digit append / bump /
# backspace logic was PORTED VERBATIM from this file, MAX_SEED cap and "[d]"
# cursor marking included). RANDOM stays the ONE-PRESS default: the MessageBox
# confirm's Z answers straight (the menu_save smoke + input_gate part D drivers
# pin that single tap), and this prompt opens ONLY from the confirm-phase
# left/right gesture, a tap those drivers never perform. Digits enter by
# typing; ←/→ moves the cursor, ↑/↓ bumps the selected digit, Backspace
# deletes; Z starts the game with the shown seed, X backs out to the menu.
# Pure input UI — no rng, no game state: the chosen seed rides
# _call_context("new_game", [seed]) into game_runtime.new_game(custom_seed).

signal seed_confirmed(seed_value: int)
signal cancelled

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const GbcWidgets := preload("res://scripts/ui/gbc_widgets.gd")
const GbcDigitRow := preload("res://scripts/ui/gbc_digit_row.gd")

const MAX_SEED := 2147483647 # 0x7fffffff: game_runtime's world_seed mask (the random draw's range)
const PLATE_RECT := Rect2(8, 40, 144, 64) # centered white plate on the black backing

var _label: Label
var _stage: Control
var _digits # GbcDigitRow — the entry SURVIVES across opens (tweak a previous seed); first open shows 0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT) # the diagnosis-2 fix: anchors AND zero offsets (set_anchors_preset would keep the 0x0 new()-rect)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parts := GbcStage.build(self) # opaque black backing + 160x144 stage
	_stage = parts.stage
	GbcStage.on_resized(self, parts.display)
	var plate := GbcWidgets.plate(PLATE_RECT, _stage)
	_label = Label.new()
	_label.name = "SeedLabel"
	_label.position = Vector2(4, 4)
	_label.size = Vector2(136, 56)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GbcStage.apply_font(_label, Color.BLACK) # black ink on the white plate
	plate.add_child(_label)
	_digits = GbcDigitRow.new()


func open_prompt() -> void:
	_digits.start_edit()
	_refresh()
	visible = true


func close_prompt() -> void: # silent (menu hide): no cancelled — the closer owns its own state
	_digits.stop_edit()
	visible = false


# Scenario seam (restyle design §2: bounds audits ride the stage rect).
func stage_root() -> Control: return _stage


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("action_a"):
		_digits.stop_edit()
		visible = false
		seed_confirmed.emit(_digits.seed())
	elif event.is_action_pressed("action_b"):
		_digits.stop_edit()
		visible = false
		cancelled.emit()
	elif _digits.handle(event): # arrows / typed unicode digits / Backspace, MAX_SEED-capped
		_refresh()
	else:
		return # Enter and friends stay unhandled (the menu toggle keeps working)
	get_viewport().set_input_as_handled()


func _refresh() -> void:
	_label.text = "NEW GAME — CUSTOM SEED\n%s\nType digits; ←/→ pick a digit; ↑/↓ change it; Backspace deletes.\n(Z: Start   X: Back)" % _digits.display_text()
