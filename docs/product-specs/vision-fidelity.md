Status: current
Last verified: 2026-07-20
Review cadence days: 21
Source paths: scripts/app/snapshot_capture.gd, scripts/app/visual_sweep.gd, scripts/app/visual_sweep_baselines.gd, scripts/app/ui_render_audit.gd, scripts/app/display_matrix.gd, tools/run_playtests.py, tools/godot_dap_smoketest.py

# Vision Fidelity

This subsystem is the capture-honesty contract for windowed screenshot verification. It never changes what the game renders; it only makes captures trustworthy and their failures legible. Threshold constants and event payloads are single-sourced in `scripts/app/snapshot_capture.gd` (a tree-free `RefCounted`, layer `app`).

## Capture contract

- Every windowed readback first awaits the existing scenario settle waits, THEN awaits a `RenderingServer.frame_post_draw` readback guard (`guard_readback()`), which fires after all viewports finished updating for the frame. The guard is always ADDED AFTER the settles, never a substitute: `visual_sweep.gd:57` `_settle(5)` lets a resized window present before the first capture, and `ui_render_audit.gd:48` warns that the battle SubViewport only redraws while visible, which its `_settle(2)` services. The guard advances whole rendered frames only — no wall-clock dependence — preserving the determinism culture.
- `capture(runtime, viewport, shot, options)` is the shared pipeline: guard → `trace_cursor` (the `SmokeScenarioRunner.trace_log_line_count()` sampled at capture time, before the readback) → `viewport.get_texture().get_image()` → optional `save_png` → byte size → validity oracle → on invalid a `capture_invalid` trace, on valid a `snapshot_captured` trace plus the duplicate-capture hook. It returns `{ok, image, kind, classification, luminance, bytes, shot_seq, trace_cursor, detail, metadata}`; the caller owns the returned image and `snapshot_capture` retains nothing.
- `options` accepts `save_path` (default `""` = no PNG write), `shot_seq` (default: the instance's 1-based counter), `dup_check` (scenario-option trigger for the duplicate hook), and `metadata` — a RESERVED hook carried through unused so Slice 3 can add a sidecar writer inside `capture()` without a signature change. Slice 1 writes NO sidecar files.
- Delegation: `visual_sweep.gd` `_capture` delegates and keeps its red-on-invalid windowed contract (an invalid capture still fails the sweep); `ui_render_audit.gd` `_pixel_half` delegates the guard plus oracle and keeps `GRADUATED := false` (findings stay quarantine-tier); `display_matrix.gd` `_check_size` inserts the guard between `await _settle(SETTLE_FRAMES)` and the root-viewport `get_image()`. `visual_sweep_passed` gains `window` and `dup_checked` (threaded through `visual_sweep_baselines.gd` `report()`).
- Root-viewport-crop fallback: if the battle SubViewport readback is magenta/stale (Godot 4.6 regression #115402 — magenta SubViewport frames after load/save, fixed only in 4.7), `ui_render_audit` crops the root viewport via `crop_battle_display()` (same texel-scale geometry as `display_matrix.gd` `_display_crop`), traces the fallback in the `capture_invalid` detail, and downscales NEAREST to the 160x144 stage so the lint's display contract holds.
- A magenta `capture_invalid` with `classification=regression` firing on the pinned Godot 4.6.1 binary is the guard working, not a defect of this subsystem. The global `tools/visual_diff.py` gate (0 pass / 1 drift / 2 error, 0.5% at tolerance 8) is unchanged by this contract.

## Validity oracle and thresholds

`classify(image, png_bytes)` is pure (no traces). Precedence, first match wins: `headless` > `blank` > `undersize` > `magenta` > `uniform`. Magenta is checked before uniform because a magenta frame is also uniform and magenta is the identified cause.

| Constant | Value | Meaning |
| --- | --- | --- |
| `MIN_SHOT_BYTES` | 5120 | PNG file bytes; below => kind `undersize` (checked only when a PNG was written, i.e. `png_bytes >= 0`) |
| `LUMINANCE_FLOOR` | 0.01 | Rec.709 mean luminance (0-1) over sampled pixels; below => kind `blank` |
| `UNIFORM_LUMA_SPAN` | 0.004 | ~1/255; (max-min) sampled luminance span below => kind `uniform` |
| `MAGENTA_CHANNEL_TOL` | 8 | Sample matches when r >= 255-tol AND g <= tol AND b >= 255-tol (pure #FF00FF signature of #115402) |
| `MAGENTA_RATIO` | 0.5 | Matching sample share at or above => kind `magenta` |
| `SAMPLE_BUDGET` | 4096 | Even-stride pixel samples per validity pass (keeps GDScript cost in low ms at 1152x648) |

Kinds: `headless` = empty image while `DisplayServer.get_name() == "headless"`; `blank` = null/empty image in a windowed run, or mean luminance below the floor; `undersize` = PNG bytes in `[0, MIN_SHOT_BYTES)`; `magenta` = magenta sample share at or above `MAGENTA_RATIO`; `uniform` = luminance span below `UNIFORM_LUMA_SPAN`. Classification is `transport` when the display server is headless and `regression` otherwise; `magenta` is ALWAYS `regression`. Kind `undersize` is also emitted by `capture()` (outside the pure `classify()` above) when `save_png` itself fails on an otherwise-valid image: no PNG bytes exist, `png_bytes` stays -1, and `detail` carries the error code, so a windowed shot that cannot be written still fails red in `visual_sweep`. `capture_invalid` is warning tier: it explains a capture but never fails a scenario on its own (findings policy).

## Transport-honesty semantics

- Headless capture is impossible by engine design (RenderingServerDummy returns blank/dummy values; offscreen rendering is still open proposal #5790). Blank captures under `--headless` are engine reality, classified `transport`, never a red.
- The windowed-only skip set `WINDOWED_ONLY_SCENARIOS = {visual_sweep, visual_sweep_update}` is single-sourced in `tools/godot_dap_smoketest.py` and shared by `tools/run_playtests.py`. `display_matrix` is deliberately NOT in it: it runs under force-headless and self-skips its pixel work in-engine (`display_matrix.gd:44-47`), still emitting `display_matrix_passed {skipped: headless}` — which is also why the default run's harness-skip count is 1, not 2. (`WINDOWED_SUBPROCESS_SCENARIOS`, which does include `display_matrix`, is only the windowed-subprocess LAUNCH set used when NOT force-headless.)
- Under `PLAYTEST_FORCE_HEADLESS=1`, both harnesses report a windowed-only scenario as skipped-with-reason, never failed: the runner prints a SKIP row, the summary line reads e.g. `summary: 19/19 (1 skipped-headless)`, the summary carries `skipped_headless`, and the exit code is 0 whenever only transport skips occurred. In the default 19-scenario run only `visual_sweep` is skipped (`display_matrix` additionally self-skips in-engine with `display_matrix_passed {skipped: headless}` — a pre-existing, distinct skip; `visual_sweep_update` is not in the default set).
- `godot_dap_smoketest.py` run directly with a windowed-only scenario under `PLAYTEST_FORCE_HEADLESS=1` prints `SKIP: <scenario>: windowed-only scenario skipped under PLAYTEST_FORCE_HEADLESS (captures need a real window and renderer)`, writes an `ok: true` result file with `skipped_reason`, and exits 0.

## Duplicate-capture hook

- Triggers: environment `PLAYTEST_CAPTURE_DUPCHECK` set to anything other than `""`/`0`/`false`/`no`/`off`, OR `options.dup_check == true` (the scenario-option path). Default OFF.
- A duplicate check captures the same quiesced shot twice: a SECOND `guard_readback()` plus readback one newly rendered frame later — no game state advances between the pair (the scenario is quiesced), but the engine has rendered one more frame, and frame-to-frame readback differences in that quiesced state are exactly the nondeterminism this hook catches. Both images are converted to `Image.FORMAT_RGBA8` and their `get_data()` byte arrays compared.
- Any nonzero delta emits `capture_invalid` with `kind=nondeterministic_pair`, `classification=regression`, `luminance` from the primary, and a detail of the form `N of M pixels differ; first byte offset K` — the identified cause.
- Quarantine-tier: the primary capture still returns `ok=true`, `dup_checked` increments and feeds `visual_sweep_passed`, the primary PNG stays canonical, and the pair is compared in memory only (never saved).

## Stamp schema

`snapshot_captured` payload (Source `App.SnapshotCapture`, info tier; headless never emits it):

| Field | Type | Meaning |
| --- | --- | --- |
| `shot` | String | Filename (`09_battle.png`) or caller shot name (`battle_action`) |
| `shot_seq` | int | 1-based per SnapshotCapture instance (1..16 across a sweep) |
| `ts_msec` | int | `Time.get_ticks_msec()` at capture time — same boot clock as the record-level `ts_msec` |
| `trace_cursor` | int | Trace-log line count sampled at capture time; join key into `user://logs/agent_trace.jsonl` (this record lands at cursor+1; join with the inclusive `trace_log_has_since(event, cursor, ...)`) |
| `window` | [int, int] | `DisplayServer.window_get_size()` |
| `renderer` | String | `rendering/renderer/rendering_method` project setting (`RenderingServer.get_current_renderer()` does not exist on Godot 4.6.1 — verified; the setting resolves per platform and names the active method, e.g. `forward_plus`) |
| `godot_version` | String | `Engine.get_version_info()["string"]` (the pinned binary reports `4.6.1-stable (official)` — verified from harvested stamps) |

`sidecar_path` is RESERVED for Slice 3: documented here and in `docs/references/trace-events.md`, absent from Slice 1 payloads.

`capture_invalid` payload (Source `App.SnapshotCapture`, warning tier): `shot` (String), `kind` (`blank`|`uniform`|`magenta`|`undersize`|`headless`|`nondeterministic_pair`), `classification` (`transport`|`regression` — magenta is always regression), `luminance` (float 0.0-1.0, 0.0 when the image is unavailable), `detail` (identified cause: byte count, magenta ratio, luma span, diff-pixel count + first offset, or fallback note).

Report stamps: `.godot-smoke/playtest-report.json` top level carries `head_sha` (`git rev-parse HEAD`), `godot_version`, `window`, and `renderer`, plus `summary` (including `skipped_headless`) and `scenarios`. The three runtime fields are harvested from the last `snapshot_captured` payload seen; absent fields are `null`, NEVER faked (headless-only runs have no `snapshot_captured` traces, so all three are null while `head_sha` is still present). Each run also deletes `.godot-smoke/result-*.json` files older than the run start so stale reds cannot contradict the report. `head_sha` is the freshness-refusal hook for `verify_all.py` (Slice 3+); `check_repo_contracts.py` verifies that, if the report exists, it carries `head_sha` and `godot_version` keys (nulls allowed).

## DECIDUEYE canary rect

The enemy canary in the battle shots is DECIDUEYE's front sprite: `front.png` is a 56x728 strip of 13 frames of 56x56, and `battle_surface_layout.gd:157` crops the first frame (`first.region = Rect2(0, 0, frame.get_width(), frame.get_width())`).

- Node rect (layout math, verified from scene + code): `EnemySprite` draws that 56x56 frame at stage rect `(96, 8, 56, 56)` inside the 160x144 `BattleViewport` (`scenes/ui/BattleView.tscn`). At the canonical 1152x648 window, `battle_view.gd` picks integer scale `floor(min((1152-32)/160, (648-32)/144)) = 4`, giving `BattleDisplay` rect `(256, 36, 640, 576)` and canary display rect `(640, 68, 224, 224)` = 50,176 px ≈ 6.72% of the 746,496-px frame. This replaces the unverified "~16x16 sprite = 0.034% of the frame" assumption cited in the plan docs (docs/superpowers/plans/2026-07-20-agent-legibility-and-vision-verification.md) by ~200x.
- Measured ink rect (verified 2026-07-20 against the committed baseline `docs/generated/visual-baselines/09_battle.png` and re-verified the same day by the windowed-verification pass against a fresh windowed capture — bit-identical to the baseline — using the `tools/visual_diff.py` stdlib decoder): frame 0 of `front.png` carries 2057 opaque pixels (all alpha 255, 7 distinct colors) with a native ink bbox of `(0, 0, 54, 56)` (2px transparent right margin). All 2057 opaque sprite pixels match the capture inside `(640, 68, 224, 224)` — 100.00% at per-channel tolerance 8, every match an exact uniform 4x4 block, confirming integer scale 4 at offset `(640, 68)`. The sprite ink therefore occupies display rect `(640, 68, 216, 224)` = 48,384 px ≈ 6.48% of the frame (node rect 50,176 px ≈ 6.72%); the ink itself is 2057×4² = 32,912 px ≈ 4.41% on screen. The battle background fills the remaining node-rect pixels, so the canary signal is the sprite ink, not whole-rect opacity. Either way the true on-screen footprint is ~6.5-6.7% — roughly 200x the unverified 0.034% assumption.
- Gate catchability: the global 0.5% gate is 3,732 px at 1152x648. A wholesale canary change (sprite swapped, blanked, or strip-loader regression) alters the 32,912 ink px = 4.41% of the frame — ~9x over the gate, comfortably CAUGHT (a whole-node-rect change would be ~13x over). The unverified 0.034% assumption (~254 px, a 16x16 sprite) sat BELOW the gate and would have been MISSED — the measurement flips the canary from "gate-blind" to "gate-visible".

## Smoke validation

- `visual_sweep` captures its deterministic 16-shot set at the canonical 1152x648 window; every capture now emits `snapshot_captured` (or a quarantine-tier `capture_invalid` explaining why not), and `visual_sweep_passed` carries `window` and `dup_checked`. Baseline diffing via `tools/visual_diff.py` is unchanged.
- `ui_render_audit` runs its pixel half through the guard plus oracle; a magenta SubViewport readback engages the root-viewport-crop fallback with a traced note, while a non-magenta invalid verdict (blank/uniform) skips the lint (lint findings against a known-invalid frame would be noise). Lint findings stay quarantine-tier until graduated (a later slice).
- `display_matrix` adopts the guard around each per-size capture; its in-engine headless self-skip is untouched.
- `python3 tools/run_playtests.py --include-smoke` reports 19/19 with transport skips under `PLAYTEST_FORCE_HEADLESS=1` and stamps the report with `head_sha` plus the windowed runtime fields when any windowed capture ran.
