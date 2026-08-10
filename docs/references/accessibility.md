Status: current
Last verified: 2026-08-09
Review cadence days: 21
Source paths: scripts/ui/gbc_widgets.gd, scripts/ui/gbc_stage.gd, scripts/ui/menu_list_stage.gd
# Accessibility Annotations (GBC UI)

agent surface; this file is the AccessKit annotation contract it points at).

The GBC widget/stage library annotates every widget it builds with Godot 4.5+
screen-reader metadata (AccessKit-backed). The annotations are METADATA ONLY:
they set `Control.accessibility_*` properties and change no geometry, no
visuals, and no input handling — the committed visual baselines
(`docs/generated/visual-baselines/`) are unaffected by construction.

The surface serves two consumers from ONE contract:

- **Player-facing**: with an active platform screen reader, the AccessKit tree
  exposes menu rows, the selection cursor, and hint text.
- **Agent-facing**: the same properties are plain readable data for the repo's
  agent-legibility surfaces (the UI-tree dump scenario reads
  `accessibility_name`/`accessibility_description`/`accessibility_live` off
  the built Controls), so an agent can answer "what is selected / unavailable"
  without pixels.

## API surface used (verified against the pinned binary, 4.6.1.stable)

GDScript-reachable `Control` properties, set at build/selection time:

- `accessibility_name: String` — the accessible name reported to assistive apps.
- `accessibility_description: String` — human-readable state reported alongside.
- `accessibility_live: DisplayServer.AccessibilityLiveMode` — live-region mode
  (`LIVE_POLITE` for regions whose content changes while focus is elsewhere).

Engine-derived behavior relied on (verified in the 4.6 engine source,
`scene/gui/label.cpp` / `control.cpp`): a `Label`'s accessible role is
`ROLE_STATIC_TEXT` and its accessible VALUE is kept in sync with `.text` on
every `set_text`; the base `Control` update copies name/description/live into
the AccessKit element. `mouse_filter = MOUSE_FILTER_IGNORE` does NOT exclude a
control from the accessibility tree.

Deliberately NOT used: the low-level `DisplayServer.accessibility_create_element`
/ `accessibility_update_set_role` / `accessibility_update_set_list_item_*` RID
API. Godot 4.6.1 exposes `Node.get_accessibility_element()`, but the engine's
own per-class update handlers rewrite the element (a `Label` re-pins
`ROLE_STATIC_TEXT` on every update), so handwritten role/state overrides race
the engine and can error on platforms where no accessibility tree exists.
List-item semantics are therefore carried in the name/description text.

## Annotation contract (what is set where)

| Widget | Where | `accessibility_name` | `accessibility_description` | `accessibility_live` |
| --- | --- | --- | --- | --- |
| Row-list row (`Label`) | `GbcWidgets.RowList.set_rows` | the row text, pinned at build (row text is final) | `"Item N of M"`, plus `", selected"` on the cursor row; refreshed on every selection change | off |
| Menu-list row (`Label`) | `MenuListStage.Rows.set_rows` | the row text, pinned at build (row strings are never rewritten — the `clip_text` contract) | `"Item N of M"`, plus `", unavailable"` on greyed (non-black-ink) rows and `", selected"` on the cursor row; refreshed on every selection change | off |
| List cursor (`TextureRect`) | `GbcWidgets._cursor` + `RowList._refresh_a11y` / `Rows._refresh_a11y` | `"Selection cursor"` | `"Row N of M: <row text>"`, rewritten on every `set_rows`/`select`/`move` | `LIVE_POLITE` |
| Hint label | `GbcWidgets.hint_label` | unset — hint text mutates after build, so the engine tracks `.text` as the accessible value (a pinned name would go stale) | unset | `LIVE_POLITE` |
| Static stage label | `GbcStage.make_label` | the text, pinned ONLY when non-empty at build | unset | off |

Unavailable entries: the greyed-row screens (dim-ink options/camp rows) build
on `menu_list_stage.gd`'s `Rows` widget (`set_rows(texts, inks)`); a row whose
ink is not black carries `", unavailable"` in its description. The shared
`GbcWidgets.RowList.set_rows(texts)` takes no availability array — no caller
ever passed one, so the seam lives on the widget the greyed screens use.

The `ui_tree_dump` scenario emits these annotations per dumped Control as
`a11y_name` / `a11y_description` / `a11y_live` (only when non-default), so the
cursor's `"Row N of M"` position and any selected/unavailable row states are
readable from `.godot-smoke/ui_tree/<screen>.json` without pixels.

## Experimental status

Screen-reader support upstream is still partial, so the announcement half is
best-effort and the metadata half is the contract:

- The 4.6.1 class reference ships EMPTY descriptions for the accessibility
  members (verified via `--doctool`); editor tooling around them is young.
- Headless runs build no AccessKit tree (`SceneTree.is_accessibility_supported()`
  is false); the properties still store and read back fine, which is what the
  agent-legibility consumer uses.
- docs.godotengine.org already shows a refactored `AccessibilityServer` enum
  namespace on `master`; the pinned 4.6.1 binary keeps
  `AccessibilityLiveMode` under `DisplayServer` and has no `AccessibilityServer`
  singleton. The binary (via `--dump-extension-api`) is authoritative here.

## Rule for new widgets

Annotate as built: any new widget the library (or a screen) constructs gets an
`accessibility_name` at minimum, `LIVE_POLITE` if its text mutates in place,
and NEVER a name pinned over text that mutates afterwards (pin at
`set_rows`-time final text only). GUI focus and input semantics stay frozen —
selection is surfaced through description/live metadata, never through
`focus_mode` changes.
