Status: current
Last verified: 2026-07-20
Review cadence days: 21
Source paths: scripts/app/snapshot_capture.gd, scripts/app/visual_sweep.gd, scripts/app/visual_sweep_baselines.gd, scripts/app/ui_render_audit.gd, scripts/app/display_matrix.gd, tools/run_playtests.py, tools/godot_dap_smoketest.py, tools/determinism_verify.py, project.godot

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

## Determinism knobs (Slice 2, verify-first)

The game scales MANUALLY in two independent places — `battle_view.gd` `_layout_display()` computes an integer scale `k = floor(min((w-32)/160, (h-32)/144))` for the 160x144 battle SubViewport (Nearest-forced upsample), and the overworld camera zooms 3x over 16px tiles — with NO engine stretch (`display/window/stretch/mode` is `disabled`; `project.godot` carries no `[display]` section). The verify-first gate confirmed this before pinning anything that could fight it. Two knobs are pinned in the existing `[rendering]` section of `project.godot` (exact keys as written):

| Project setting key | Pinned value | Engine default (4.6.1, measured via `property_get_revert` on the pinned binary) | Effect |
| --- | --- | --- | --- |
| `rendering/anti_aliasing/quality/msaa_2d` | `0` | `0` (disabled) | Documents the already-disabled 2D MSAA so a future editor toggle cannot silently add per-sample blending to pixel art. Zero rendering delta by construction. |
| `rendering/2d/snap/snap_2d_transforms_to_pixel` | `true` | `false` | Quantizes 2D transforms to screen pixels at sampling time: the overworld walk lerp (`player_avatar.gd` position lerp, no camera smoothing) and any fractional camera position land on integer pixel offsets instead of smearing tile edges through the inherited Linear canvas filter. `rendering/2d/snap/snap_2d_vertices_to_pixel` stays at its default `false` (not pinned). |

`tools/determinism_verify.py pins` asserts both pins are present with these values AND that the rejected candidate pins below stay absent; it is the permanent verify-first aid (absorbed by `verify_all.py` when it lands).

### Verify-first evidence (measured 2026-07-20; Godot 4.6.1-stable official, forward_plus, canonical 1152x648 window)

Decision rule: adopt candidate-full ONLY if the DECIDUEYE canary and 7px battle fonts render identical-or-crisper across ALL 16 shots AND `display_matrix` stays green across all 6 sizes AND 2/2 consecutive windowed sweeps are bit-identical; otherwise adopt safe-subset. Three configs were measured windowed (`python3 tools/run_playtests.py --scenario visual_sweep`/`visual_sweep_update` transport; artifacts in `/tmp/slice2-evidence/`):

| Config | Consecutive sweeps | vs committed baselines | DECIDUEYE canary rect (640,68,224,224), shots 09-12 | Battle fonts (09_battle, stage-native 160x144) | display_matrix (6 sizes incl. odd 438x383) | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| untouched (sanity) | — | 16/16 byte-identical, max drift 0.0% | — | distinct RGB 155, ink 3313 px, fringe 2731 px | — | baseline |
| **safe-subset** (the two pins above) | 2/2 bit-identical, all 16 shots | 16/16 byte-identical, max drift 0.0% | 100% 4x4-block-uniform: 3136/3136 blocks, 0 smear, 0 off-grid transitions (4008 x-transitions) | identical to sanity (distinct 155 / ink 3313 / fringe 2731) | PASS, 6/6 sizes, max drift 0.0, all matrix frames 100% block-uniform | **ADOPTED** |
| candidate-full (safe subset + `rendering/textures/canvas_textures/default_texture_filter=0` [Nearest (value 0, same numbering as the runtime CanvasItem.TEXTURE_FILTER enum)] + `display/window/stretch/mode="viewport"` / `scale_mode="integer"`) | 2/2 bit-identical, all 16 shots (still deterministic) | 12/16 changed, max drift 57.73%; `visual_sweep` compare FAILS the 0.5% gate | still 100% block-uniform, 0 off-grid | identical | PASS, 6/6 sizes, max drift 0.0 | **REJECTED** |

Candidate-full per-shot delta vs committed baselines (changed pixels / pct): 01_overworld_spawn 328,889 / 44.06%; 02_overworld_walked 296,733 / 39.75%; 03_biome_desert 324,631 / 43.49%; 03_biome_forest 344,774 / 46.19%; 03_biome_plains 321,008 / 43.00%; 03_biome_sand 258,605 / 34.64%; 03_biome_savanna 430,923 / 57.73%; 04_night 214,851 / 28.78%; 05_dawn 301,740 / 40.42%; 06_menu 156,001 / 20.90%; 07_party_screen 99,305 / 13.30%; 08_bag_screen 99,305 / 13.30%. Battle shots 09-12 unchanged (0 px): battle art is `TEXTURE_FILTER_NEAREST`-forced in code on every art node (`battle_surface.gd:61-62`, `battle_view.gd:28`, `attack_animator.gd:138`) and drawn 1:1 inside the 160x144 SubViewport, so the project default filter never touches battle sprites or the size-7 battle font (rendered at 1:1, then integer-upscaled by the Nearest-forced `BattleDisplay`).

Rejection rationale (candidate-full):
1. NOT identical-or-crisper across all 16 shots: the Nearest default filter re-renders overworld tiles — the inherited Linear filter blends tile texels at camera zoom 3x even at pixel-exact rest positions, and Nearest yields crisp 3x3 blocks, changing 34-58% of overworld pixels — and shifts the root-UI default-theme panels/backgrounds (shots 06-08) by 13-21%. The overworld is re-rendered, not identical.
2. `visual_sweep` compare FAILS under candidate-full (12 shots over the 0.5% gate): adoption would force regeneration of 12 baselines and change the shipped product look. That is a visible product change requiring owner sign-off, not a silent determinism pin, and the stretch pin carried an explicit high-rejection-risk flag — `[display]` stretch layers OS-level scaling UNDER both manual scaling paths (`_layout_display` reads `get_viewport_rect()`, which stretch freezes at the base size) = double-scaling by construction.
3. The adoption bar's first clause fails, so the rule resolves to "otherwise adopt safe-subset." The rejection is purely about CHANGED PIXELS: candidate-full was deterministic (2/2 bit-identical) and display_matrix stayed green, so there is no instability or double-scaling breakage on the tested sizes — recorded with evidence per exit criterion 6.

Visible-change record (exit criterion 4): the adopted config is byte-identical to all 16 committed baselines — a zero-delta triptych (`tools/determinism_verify.py cmp` reports 16/16 identical against the post-pin sweep; `tools/visual_diff.py` max drift 0.0%). There is NO visible product change and no owner sign-off is required. Because every frame is byte-identical, baseline regeneration was a no-op: the 16 committed PNGs and their tracked `.png.import` sidecars are untouched, and the headless `--import` pass had nothing to re-import. Under the adopted config the variance budget tightens to the measured noise floor: zero (2/2 consecutive windowed sweeps byte-identical on all 16 shots).

When pins force regeneration: ANY `project.godot` rendering/display key change (these pins, a future filter or stretch change), a Godot binary bump, or a driver/renderer change invalidates the baselines — they are driver-specific pixels (MoltenVK/Vulkan on this Mac vs the `d3d12` driver pin on Windows). Re-run the verify-first gate (`tools/determinism_verify.py pins` + a windowed sweep vs baselines) BEFORE committing new pins, then regenerate via the procedure in [RELIABILITY.md](../RELIABILITY.md). The Slice 1 report stamps (`head_sha`, `godot_version`, `window`, `renderer`, schema-checked by `check_repo_contracts.py`) record baseline provenance: baselines captured under a different binary or config must not be diffed. Mechanical refuse-on-mismatch lands with `tools/verify_all.py` (Workstream L.1); until then the rule is human/agent-enforced policy.

### Owner sign-off record (exit criterion 4, embedded at Integrate 2026-07-20)

**NO VISIBLE PRODUCT CHANGE — OWNER SIGN-OFF NOT REQUIRED (zero-delta triptych).**

Config adopted: safe-subset — `rendering/2d/snap/snap_2d_transforms_to_pixel=true` + `rendering/anti_aliasing/quality/msaa_2d=0` (both under `[rendering]` in `project.godot`; working tree already in this state, diff verified to contain ONLY these two pins).

Evidence of zero visible change:
- All 16 baselines regenerated via windowed `visual_sweep_update` (`visual_sweep_passed`, mode=update, 16/16 updated, pruned=[], max_drift_pct 0.0; stamps head=39dce19944318a3d3552dadfdae472f6235a460c, godot=4.6.1-stable (official), window=[1152,648], renderer=forward_plus) and every regenerated PNG is SHA-256 byte-identical to its committed baseline and to git HEAD (`git diff HEAD -- docs/generated/visual-baselines` = 0 files).
- Old-vs-new per-shot: 16/16 byte_identical=True, 0 changed pixels at tolerance 0 AND 0 at tolerance 8. Zero changed shots.
- Zero-delta triptychs (old | new | 32x-amplified diff; all diff panels pure black): `/tmp/slice2-evidence/triptychs/` (16 files, `<shot>_triptych.png`).
- Canary block-uniformity old==new: 100% 4x4-block-uniform, 0 off-grid transitions, all edge runs multiples of 4 (no sub-pixel smear); 7px font metrics old==new.
- Post-regen stability: 2/2 consecutive windowed `visual_sweep` runs PASS with max_drift_pct 0.0 (compared=16, mismatched=[]); run1 == run2 == committed baselines byte-for-byte; bonus `PLAYTEST_CAPTURE_DUPCHECK=1` run: dup_checked=16, mismatched=[], drift 0.0 (intra-run noise floor zero).
- `display_matrix`: `display_matrix_passed`, 6 sizes incl. odd 438x383, max_drift_pct 0.0 (<=1.0% threshold).
- Static gates all green: check_change_contract (silent — project.godot is not .gd/.tscn), check_repo_contracts, check_architecture, check_quality_docs (all exit 0).

Candidate-full (Nearest default filter `rendering/textures/canvas_textures/default_texture_filter=0` + `display/window/stretch/mode="viewport"` + `scale_mode="integer"`) REJECTED with evidence (exit criterion 6): deterministic and display_matrix-green, but changed 12/16 shots by up to 57.7% (overworld tiles re-rendered Linear->Nearest at camera zoom 3x; root-UI default-theme panels 13-21%; only the 4 Nearest-forced battle shots byte-identical), failing the 'identical-or-crisper across ALL 16 shots' adoption bar and `visual_sweep` compare; adoption would force 12-baseline regeneration and a visible product change requiring owner sign-off. The stretch pin carried the explicit HIGH-REJECTION-RISK / 'shrink path is the expected outcome' flag. Rejection evidence: `/tmp/slice2-evidence/SUMMARY.md`, candidate-full.json, cand-run1/, cand-run2/, safe-matrix/.

Baseline regeneration under the chosen config was a byte-no-op (verified, not assumed); the 16 committed baselines remain correct; nothing else in `docs/generated` changed. Evidence bundle: `/tmp/slice2-evidence/BUILD_BASELINES_EVIDENCE.md`.

## Smoke validation

- `visual_sweep` captures its deterministic 16-shot set at the canonical 1152x648 window; every capture now emits `snapshot_captured` (or a quarantine-tier `capture_invalid` explaining why not), and `visual_sweep_passed` carries `window` and `dup_checked`. Baseline diffing via `tools/visual_diff.py` is unchanged.
- `ui_render_audit` runs its pixel half through the guard plus oracle; a magenta SubViewport readback engages the root-viewport-crop fallback with a traced note, while a non-magenta invalid verdict (blank/uniform) skips the lint (lint findings against a known-invalid frame would be noise). Lint findings stay quarantine-tier until graduated (a later slice).
- `display_matrix` adopts the guard around each per-size capture; its in-engine headless self-skip is untouched.
- `python3 tools/run_playtests.py --include-smoke` reports 19/19 with transport skips under `PLAYTEST_FORCE_HEADLESS=1` and stamps the report with `head_sha` plus the windowed runtime fields when any windowed capture ran.
