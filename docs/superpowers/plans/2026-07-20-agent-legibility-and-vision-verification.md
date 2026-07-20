Status: active
Last verified: 2026-07-20
Review cadence days: 14
Source paths: docs/product-specs, docs/registry/subsystems.toml, docs/QUALITY_SCORE.md, docs/RELIABILITY.md, docs/references/trace-events.md, docs/references/vision-review-rubric.md, docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md, scripts/app, scripts/runtime, tools

# Vision Fidelity & Agent Legibility

## Goal

Deepen an AI agent's **legibility** into (a) Godot 4.6.1 itself and (b) this port's *running* game, so the local playtest suite gains **fidelity** and catches bugs more reliably — concretely through **additional vision checks** and **structured observation of the running game**. The suite already captures well; what it cannot do today is (1) see small, localized regressions under its one global pixel gate, (2) *explain* a failing diff, or (3) read the live game's semantic state alongside a screenshot. This plan closes all three.

It is built on the **Vision-first** proposal (the higher-scoring of the two reviewed: it grows the *coded* red-tier oracle surface, introduces no runtime network surface, and is the most flake-averse), with the **Introspection-first** proposal's legibility backbone grafted in **in-process** — semantic snapshot sidecars correlated to the JSONL trace, an explainable per-region diff, and an ASCII change grid an agent can read with no vision at all. The Introspection-first proposal's live TCP endpoint is **deliberately deferred** to an optional later lane: the in-process collectors deliver ~90% of the structured-observation value with zero new runtime moving parts.

**Non-goals** (explicit): any CI runtime gate (CI stays lint/contract-only); cross-platform/cross-machine baseline sharing (pixels are driver-specific); a first-party GDScript test runner (Godot 4.6 ships none; `--test` is engine-dev-only); OCR as a primary text oracle (strictly dominated here by template matching on a fixed font); headless capture of any kind (blank by engine design).

**Operating constraint:** the suite stays **local and windowed** for captures. This is engine reality, not policy preference — verified below.

## Context & research takeaways

Verified against Godot 4.6 sources and against this checkout (HEAD `cf323a6`, 2026-07-20). Techniques adopted, with version caveats:

- **`await RenderingServer.frame_post_draw` capture guard (ADOPT, P0).** The Viewport docs warn `get_image()` "might be completely black or outdated if used too early"; `frame_post_draw` fires after all viewports finish updating. This checkout's captures use `_settle(N)` → `await get_tree().process_frame` (`visual_sweep.gd:103`, `ui_render_audit.gd:195`) — *not* the docs-mandated readback guard. **Caveat (verified on disk):** `visual_sweep.gd:60` `_settle(5)` exists to let a *resized window present*, and `ui_render_audit.gd:46` warns the battle SubViewport *only redraws while visible*. The fix is to **keep** those waits and **add** the `frame_post_draw` readback guard — never substitute.
- **Headless capture is impossible by design (CLOSES an audit fragility).** `--headless` implies RenderingServerDummy; "most functions return dummy values"; offscreen rendering is still open proposal #5790. The audited "`visual_sweep` red under forced-headless" is **unfixable headless** — so this plan reclassifies it as a *skipped/transport* result (Workstream L.2), not a lying red.
- **Godot 4.6 SubViewport→ViewportTexture regression #115402 (GUARD).** Renders magenta/stale frames after load/save; fixed **only in 4.7, no backport**. `ui_render_audit.gd:182` reads the battle SubViewport directly on the pinned 4.6.1 — a live threat. Add a magenta-frame validity check and a root-viewport-crop fallback.
- **Movie Writer `--write-movie --fixed-fps N --quit-after N` (OPTIONAL, deferred).** Highest-fidelity capture primitive Godot ships: forces identical `_process` delta, perfect frame pacing, 8-digit PNG burst, available in exported projects. **Caveats:** captures *only the root viewport*; on window≠movie size it crops + **bilinear-resizes** (smears pixel art) — so it must run windowed at exactly 1152×648; forces AudioDriverDummy; `Ctrl+C` corrupts AVI (PNG sequence safe) so always bound with `--quit-after`. Kept as a quarantine-tier *motion* lane for `battle_anim`, never mixed into the 16 committed baselines.
- **Built-in remote RPCs `rq_screenshot`/`next_frame`/`inspect_objects` (DEFERRED).** New in 4.5; engine-guaranteed step-capture. **But** the wire is 4-byte-length-prefixed **Variant binary** over `tcp://`, and handlers register only with `--remote-debug`. Costs a Python Variant codec. The in-process NDJSON sidecar path sidesteps this entirely; the codec/endpoint is a P3 option.
- **DAP is editor-only and `evaluate` is pause-only (KEEP AS-IS).** `tools/godot_dap_smoketest.py` is a correct, rare implementation; it stays the breakpoint-deep-inspection path. `godot/put_msg` (JSON-native bridge into the remote-debug surface) is a documented optional spike.
- **Determinism knobs (ADOPT behind a verify-first gate).** The engine default 2D texture filter is **Linear** and transform snapping is **OFF**; `project.godot` sets **no `[display]` section** and only `rendering_device/driver.windows="d3d12"` (verified on disk). The game therefore renders pixel art through inherited bilinear filtering with sub-pixel jitter — the variance that eats the 0.5% budget. Pin `msaa_2d=0` + `snap_2d_transforms_to_pixel=true` first (safe); pin Nearest + stretch `viewport`/`integer` **only if** per-import verification shows the DECIDUEYE canary and 7px fonts render identically or crisper (the game scales manually today — don't fight it blind). Pixels are driver-specific (d3d12 on Windows vs Vulkan/MoltenVK on this Mac), so baselines stay machine-local and every artifact is stamped.
- **Per-region diff verdicts + clustering (ADOPT).** Industry-standard (BackstopJS per-selector thresholds, Playwright `maxDiffPixels`, looks-same `shouldCluster` cluster bboxes). The global %-only verdict is replaced by named regions with their own thresholds, diff clusters as bounding boxes, and a low-res ASCII change grid.
- **Template glyph matching over OCR (ADOPT).** On a fixed known bitmap font at deterministic integer scale, rasterized expected-string masks matched at modeled rects are **zero-flake**, return per-glyph bboxes (enabling clipping/overlap/min-stroke oracles), and a failed match **is** the garble signal — strictly dominating Tesseract/Paddle/EasyOCR here (and Paddle/Easy drag in torch/paddle, against the stdlib discipline). OCR is deferred indefinitely (only earns its keep for future procedural strings templates can't enumerate).
- **WCAG rendered-pixel contrast + Machado-2009 CVD simulation (ADOPT).** ~20–60 stdlib lines each: linearized-sRGB relative luminance ratio (AA 4.5:1 / 3:1 large) sampled in already-modeled label rects catches text-over-battle-effect failures design-time checks miss (coded-grade); Machado, Oliveira & Fernandes 2009 severity matrices (hardcoded, cited — **not** the Lokno gist the author labels a hack) simulate HP-bar/status/canary palettes under protan/deutan/tritan (quarantine-tier accessibility evidence).
- **Set-of-Mark grounding + two-tier VLM discipline (ADOPT).** VideoGameQA-Bench (arXiv 2505.15952) measured **45.2%** best visual-regression accuracy and **~19.8% PPV** at realistic prevalence — empirically mandating this repo's two-tier policy. Set-of-Mark numbered overlays (arXiv 2310.11441) are the proven accuracy lever; requiring every finding to cite a region id it intersects is the cheap, decisive false-positive filter. Reviewer discipline per LLM-as-judge literature: temperature 0, n=2 vote, before/after order shuffle.

**Verified correction to both source proposals (do not repeat):** the "~16×16 sprite = 0.034% of the frame = order of magnitude under the 0.5% floor" claim is **unverified and likely wrong here.** `pokewilds/pokemon/pokemon/decidueye/front.png` is **56×728 = a 13-frame strip of 56×56 frames**, and `battle_surface_layout.gd:157` crops the front sprite to a `width×width` square (56×56 stage px). Displayed at the battle stage's integer scale inside the 1152×648 root capture, the canary's footprint is likely *several* percent, which the global gate may well catch when it changes wholesale. The per-region upgrade is still correct and still ships — its real value is **sub-region** sensitivity (a 1-frame strip offset, edge strip-bleed, bilinear smear at the frame boundary) plus **dynamic-zone masking** and **explainability** — but the canary's true on-screen display rect is **measured in Slice 1**, and thresholds are set from that measurement, not from an assumed footprint. **MEASURED (2026-07-20, Slice 1):** integer scale 4 gives canary node rect `(640, 68, 224, 224)` = 50,176 px ≈ 6.72% of the 1152×648 frame; the sprite's own ink (2057 opaque px, native bbox 54×56) matches the committed baseline at 100.00% in exact 4×4 blocks at tolerance 8, i.e. ink rect `(640, 68, 216, 224)` ≈ 6.48% — about 200× the 0.034% assumption. See `docs/product-specs/vision-fidelity.md` § DECIDUEYE canary rect.

## Relationship to the active plans

- **`pokewilds-feature-completion.md` Workstream L** is the home of this work. This plan **implements** L.2 (transport honesty), L.3 (artifact freshness / HEAD stamping), L.4 (`tools/vision_review.py`), and L.5 (graduate the pixel lint), and produces the building blocks L.1 (`verify_all.py`) absorbs when it lands. It does **not** touch L.6 (bot coverage) or L.7 (scenario backlog). It **references, not duplicates,** Phase 0.7 (the `--verbose` ObjectDB leak oracle — `--headless --quit` exits with zero leak warnings): that check belongs to Phase 0.
- **`harness-engineering-reorientation.md`** stays active and orthogonal (legibility/harness health); this plan shares its doc contract.
- **Oracle design spec** (`docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md`): this plan fulfills its Lane-4 "structured findings file on every sweep whose shots change" criterion and its success criterion that "the rubric catches at least one seeded visual defect that all coded oracles miss in a validation pass," and respects its graduation rule (a heuristic flips only after staying clean across repeated real runs).

## Per-slice definition of done

Each slice inherits the repo's per-slice DoD (`pokewilds-feature-completion.md`): (1) spec, (2) registry subsystem with `validation_commands` + `required_trace_events`, (3) `check_architecture.py` green (app/ui ≤ 220, other scripts ≤ 320, `.tscn` ≤ 250; split before adding), (4) new traces documented in `trace-events.md` and no new silent fallbacks, (5) a scenario asserts the behavior, (6) changed shots get committed baselines + a vision review, (7) `QUALITY_SCORE.md` + `RELIABILITY.md` + `tech-debt-tracker.md` updated (mechanically enforced by `check_change_contract.py`), (8) local gate green.

**Change-contract note (verified):** `check_change_contract.py` requires, for *every* subsystem whose `code_paths`/`scene_paths` a slice touches, co-modification of `docs/registry/subsystems.toml`, that subsystem's `spec_doc`, `docs/QUALITY_SCORE.md`, and `docs/RELIABILITY.md`. Slices below that touch both a new file (new `vision_fidelity` subsystem) **and** an `app_bootstrap` file (e.g. `visual_sweep.gd`) must co-modify **both** subsystems' spec docs (`vision-fidelity.md` and `bootstrap-and-overworld.md`) plus the shared QUALITY_SCORE/RELIABILITY. `check_repo_contracts.py` additionally fails if any `required_trace_event` is absent from `trace-events.md` — every new event below is added there in the same slice.

## Design

### New subsystem

`vision_fidelity` (layer `app`; `spec_doc = docs/product-specs/vision-fidelity.md`), registered in `docs/registry/subsystems.toml`:
- `code_paths = ["scripts/app/snapshot_capture.gd", "scripts/app/render_introspection.gd", "scripts/app/text_oracle.gd"]`
- `required_trace_events = ["snapshot_captured", "capture_invalid", "text_oracle_passed", "quarantine_finding"]`
- `validation_commands`: `check_repo_contracts`, `check_architecture`, `godot_dap_smoketest.py … --scenario visual_sweep`, `godot_dap_smoketest.py … --scenario ui_render_audit`, `python3 tools/run_playtests.py`.

New files fit layering (`app` may import `app/runtime/ui/core`; `runtime` may **not** import `app/ui` — so every collector composing `UiRenderModel` lives in `app`):

| File | Layer | Budget | Role |
|---|---|---|---|
| `scripts/app/snapshot_capture.gd` (NEW) | app | ~150/220 | Capture contract: `frame_post_draw` readback guard, capture-validity oracle, duplicate-capture hook, sidecar writer |
| `scripts/app/render_introspection.gd` (NEW) | app | ~170/220 | In-process semantic collector: labels/draw-order/palettes/expected regions (composes `ui_render_model.gd` + `world_draw_order.gd`) — no `main.gd` edits |
| `scripts/app/text_oracle.gd` (NEW) | app | ~200/220 | Glyph template oracle: TextServer raster masks matched at `UiRenderModel.expected()` rects, per-glyph bboxes, clipping/overlap/min-stroke checks |
| `tools/visual_region_diff.py` (NEW) | tools | ~200, stdlib | Per-region verdicts, cluster extraction, triptych + clusters.json + ASCII grid (imports `visual_diff`'s PNG decoder via the importlib pattern `run_playtests.py` already uses) |
| `tools/visual_explain.py` (NEW) | tools | ~180, stdlib | Sidecar↔cluster join → explanation sentences + explicit `unexplained` queue |
| `tools/png_canvas.py` (NEW) | tools | ~120, stdlib | PNG encoder + box/text primitives shared by triptych and Lane-4 overlays |
| `tools/contrast_check.py` (NEW) | tools | ~60, stdlib | WCAG rendered-pixel contrast + text-edge contrast in modeled label rects |
| `tools/cvd_sim.py` (NEW) | tools | ~50, stdlib | Machado-2009 CVD matrices over palette pairs + canary palette |
| `tools/vision_review.py` (NEW) | tools | ~250, stdlib | Lane-4 automation: SoM bundle, `--reviewer-cmd` plugin, region-grounding enforcement, schema validate/repair (Workstream L.4 deliverable) |
| `tools/graduation_ledger.py` (NEW) | tools | ~120, stdlib | `finding_id`→graduated-oracle join; precision/recall telemetry |
| `tools/vision_metrics.py` (NEW, optional `vision` extra) | tools | ~80 | SSIM-map corroboration (imports scikit-image only under the extra; never a gate) |
| `pyproject.toml` (NEW) | repo | — | uv-managed (per user convention); optional extra `vision = ["scikit-image"]`; core tools stay stdlib-only |
| `docs/product-specs/vision-fidelity.md` (NEW) | doc | — | Spec: capture contract, sidecar schema, region gates, oracles (house format) |
| `docs/references/snapshot-sidecar.md` (NEW) | doc | — | Sidecar JSON schema + correlation protocol (with the Status/Last-verified/Review-cadence/Source-paths header so `check_repo_contracts` passes) |

Files **edited** stay at or under budget — the over-tight files are **relieved by delegation, never grown**:

| File | Now | Change |
|---|---|---|
| `scripts/app/visual_sweep.gd` | 219/220 | `_capture` (L82–101) delegates to `snapshot_capture`; `_settle(5)` window-present at L60 **kept**; `visual_sweep_passed` payload gains region/sidecar fields → **~205** |
| `scripts/app/ui_render_audit.gd` | 202/220 | `_pixel_half` adds `frame_post_draw` guard + magenta validity + root-viewport-crop fallback; `GRADUATED` bool → `GRADUATED_STATES` dict; calls `text_oracle`; pixel-half detail delegates out to stay ≤ 220 → **~218** |
| `scripts/app/display_matrix.gd` | 211/220 | adopts the `frame_post_draw` guard around per-size captures → **~216** |
| `scripts/app/visual_sweep_baselines.gd` | 210/220 | commits/copies baseline sidecars in `_update_baselines`; passes `--sidecar-dirs` to the region diff; surfaces region verdicts in `visual_sweep_passed` → **~218** (if it would exceed, the sidecar-copy helper moves into `snapshot_capture.gd`) |
| `scripts/app/main.gd` | 219/220 | **untouched** — `render_introspection` takes the existing `smoke_context()` ctx dict |
| `scripts/runtime/smoke_scenario_runner.gd` | 305/320 | **untouched in the critical path** — `trace_log_line_count()` (L260) is called *by* `snapshot_capture`; the deferred TCP endpoint would be the only future edit here |
| `tools/run_playtests.py` | 462 | HEAD/Godot/renderer stamps; `WINDOWED_SUBPROCESS_SCENARIOS` skip-with-reason under `PLAYTEST_FORCE_HEADLESS`; stale `result-*.json` sweep; quarantine + `vision_review_written` report sections; freshness refusal |
| `tools/visual_diff.py` | 253 | expose the changed-pixel index set (already built at L143) to the region module; global gate + exit-code contract (0 pass / 1 drift / 2 error) **unchanged** |
| `tools/check_repo_contracts.py` | 120 | + region-coverage check (every committed baseline shot has region entries) and a core-tools-stdlib-only guard |
| `project.godot` | — | determinism pins (Slice 2, verify-first) |

### New trace events (all added to `trace-events.md` + the owning subsystem's `required_trace_events` in the same slice)

| Event | Source | Tier | Payload |
|---|---|---|---|
| `snapshot_captured` | `App.VisualSweep` | info | `shot, sidecar_path, shot_seq, ts_msec, trace_cursor, window:[w,h], renderer` |
| `capture_invalid` | `App.VisualSweep` | warning | `shot, kind: blank\|uniform\|magenta\|undersize\|headless\|nondeterministic_pair, classification: transport\|regression, luminance, detail` |
| `text_oracle_passed` | `SmokeScenarios` | coded | `states_checked, strings_checked, glyphs_checked` |
| `visual_sweep_passed` *(extended)* | `SmokeScenarios` | coded | gains `region_failures, clusters_explained, clusters_unexplained, sidecar_paths` |
| `quarantine_finding` *(new kinds)* | `SmokeScenarios` | quarantine | kinds added: `capture_nondeterminism, region_drift, glyph_mismatch, contrast_low, cvd_collapse, vision_review` |
| `vision_review_written` *(report field, not JSONL)* | report | quarantine | `shots_reviewed, findings, grounded, dropped, reviewer` — a `playtest-report.json` field |

### Artifact formats

- **Screenshot + sidecar (the correlation backbone).** Alongside each `.godot-smoke/shots/<shot>.png` the capture contract writes `<shot>.sidecar.json`; committed `<shot>.sidecar.json` siblings live next to baseline PNGs in `docs/generated/visual-baselines/`. Sidecars are **canonical JSON** (sorted keys, integer rects via `UiRenderModel.map_region`, `ts_msec` from boot not wall-clock) so they are git-diffable and byte-stable per seed. The `trace_cursor` is `smoke_scenario_runner.trace_log_line_count()` at capture time — the verified join key into `user://logs/agent_trace.jsonl`. Correlation is total: PNG ↔ sidecar ↔ `agent_trace.jsonl` (trace_cursor + ts_msec) ↔ `playtest-report.json`.

```json
{
  "shot": "09_battle.png", "shot_seq": 9, "ts_msec": 12345, "trace_cursor": 482,
  "window": [1152, 648],
  "crafted_state": {"world_seed": 20260717, "party": [["DECIDUEYE",20],["CHIKORITA",5]],
                    "bag": {"poke_ball":5,"potion":3}, "time_of_day": 720,
                    "battle_rng_seed": 20260717, "wild": ["DECIDUEYE",18]},
  "capture_env": {"renderer": "...", "adapter_name": "...", "adapter_version": "...",
                  "driver_info": [], "godot_version": "4.6.1"},
  "labels": [{"text":"PECK","stage_rect":[x,y,w,h],"display_rect":[X,Y,W,H]}],
  "draw_order": [{"node":"...","z":0,"rect":[X,Y,W,H],"texture":"..."}],
  "palettes": {"canary": ["#A8B0C0"], "hud": []},
  "cursor_pairs": [], "expected_regions": {"ink":[], "forbidden":[], "strings":[]},
  "canary_rect": [X,Y,W,H],
  "validity": {"luminance": 0.41, "uniform": false, "bytes": 18332}
}
```

- **Diff artifacts (on any drifted shot).** `<shot>.triptych.png` (baseline | actual | annotated-diff, pixelmatch conventions red=diff), `clusters.json` (machine-readable cluster bounding boxes), `<shot>.ascii.txt` (32×18 change-density grid — an agent reads the heatmap with **no vision**). All stamped HEAD/seed/window/renderer.
- **`.godot-smoke/vision-review.json`** — regenerated per the existing rubric schema, additively extended with `region_id, evidence_crop, explanation, sidecar_ref`; the stale July-19 pilot is deleted on first run.
- **`playtest-report.json`** — gains `head_sha, godot_version, window, renderer` (renderer/adapter read from sidecar `capture_env`), a `quarantine` section, and `vision_review_written`.

## Rollout slices

Sequenced so **honest captures come first** (everything else stands on them), then the legibility backbone, then the coded oracles, then Lane 4, then graduation — the marginal-bug-catching-value order.

### Slice 1 — Capture honesty (no product change)

`snapshot_capture.gd` (frame_post_draw readback guard **added after** the existing window-present/SubViewport-visibility waits; capture-validity oracle: `MIN_SHOT_BYTES` 5120 + luminance floor + uniform-color + magenta-frame #115402 check, with transport-vs-regression classification; duplicate-capture hook). `visual_sweep.gd`/`ui_render_audit.gd`/`display_matrix.gd` adopt it by delegation. `run_playtests.py`: HEAD/Godot/renderer stamps (L.3), `WINDOWED_SUBPROCESS_SCENARIOS` skip-with-reason under `PLAYTEST_FORCE_HEADLESS` → `19/19 (1 skipped-headless)` (L.2), stale `result-*.json` sweep. `godot_dap_smoketest.py` shares the skip semantics. New events `snapshot_captured`/`capture_invalid` documented + registered. Co-modify `vision_fidelity` + `app_bootstrap` docs.

**Exit criteria:** two consecutive **windowed** sweeps bit-identical on all 16 shots, **or** every nonzero duplicate delta carries a `capture_nondeterminism` quarantine trace with an identified cause; `PLAYTEST_FORCE_HEADLESS=1` reports `19/19 (1 skipped-headless)` and never goes red on transport; `playtest-report.json` carries HEAD sha + Godot 4.6.1 + renderer and `check_repo_contracts` verifies the stamp; the canary's **true on-screen display rect is measured** and recorded (corrects the 0.034% assumption); `check_architecture` + `check_change_contract` green.

### Slice 2 — Determinism pinning (verify-first) + baseline regeneration

**Verify-first gate:** confirm the game's manual scaling path (no `[display]` section today) before pinning anything that could fight it. Pin the **safe subset** first (`rendering/anti_aliasing/quality/msaa_2d=0`, `rendering/2d/snap/snap_2d_transforms_to_pixel=true`); pin Nearest default texture filter + stretch `viewport`/`integer` **only if** per-import verification shows the DECIDUEYE strip sprite and 7px battle fonts render identically or crisper (verify the strip sprite's per-import filter). Regenerate all 16 baselines (and baseline sidecars once Slice 3 lands) in the **same** change; co-modify per the change contract.

**Exit criteria:** `display_matrix_passed` stays green across all 6 window sizes; canary edges measure block-uniform (triptych of old-vs-new baselines reviewed, no new sub-pixel smear); 2/2 post-regen sweeps bit-identical; owner sign-off recorded for any visible product change; change-contract check green. If Nearest/integer-scale is rejected, this slice shrinks to snapping + stamps and the variance budget tightens accordingly.

### Slice 3 — Semantic sidecars + explainable per-region diff (the legibility backbone, in-process)

`render_introspection.gd` collects labels (`UiRenderModel.visible_labels` + `ink_rect` + `map_region`), draw order (composes `world_draw_order.gd`), palettes (`Image.get_used_colors` per region), and expected regions (`UiRenderModel.expected`); `snapshot_capture.gd` writes the canonical sidecar; `visual_sweep_baselines.gd` commits baseline sidecars. `visual_region_diff.py`: region masks from committed sidecars — **canary rect at ~0 tolerance (first red-tier coded region)**, ink/string regions near-zero, known-dynamic zones (cursor cells, animation rects) masked — global 0.5%/tolerance-8 kept as backstop; cluster bboxes + 32×18 ASCII grid + triptych via `png_canvas.py`; exit-code contract unchanged. `visual_explain.py`: sidecar↔cluster join → `label_moved / label_overlap_sprite / canary_absent / palette_dropped / region_ink_lost / unexplained`. `check_repo_contracts.py` gains the region-coverage + stdlib-only guards.

**Exit criteria:** the region gate fires on a **seeded** canary perturbation (1-frame strip offset) and a deleted battle label in a validation pass — each turning the suite red via its region gate without any per-bug assertion — then reverted; every cluster in a deliberately-broken shot carries an explanation or an explicit `unexplained` tag; **region gates arm red only after the duplicate-capture noise floor measures zero** across 3 consecutive seeded windowed runs (else they stay quarantine-tier and the nondeterminism is investigated); sidecar `trace_cursor` join into `agent_trace.jsonl` verified for 3 shots; 10 consecutive windowed runs produce zero region-gate flakes; `visual_diff.py` exit-code contract unchanged so CI posture is untouched.

### Slice 4 — Coded legibility oracles (glyph template match, WCAG contrast, CVD sim)

`text_oracle.gd`: expected strings rasterized to ink masks via **TextServer glyph-atlas readback** (`RenderingServer.texture_2d_get`, windowed, `frame_post_draw`-gated — `Font.draw_string` targets a CanvasItem, not an Image, so CPU masks need readback) and XOR-matched at `UiRenderModel.expected()` rects with a tolerance **calibrated from measured noise**, returning per-glyph bboxes for clipping/overlap and min-stroke-width (ink run-length) checks. `ui_render_audit.gd`: `GRADUATED` bool → `GRADUATED_STATES` dict; pixel half calls `text_oracle`; **battle states graduate first** (best-modeled in `ui_render_art.gd`). `contrast_check.py` (WCAG, coded after clean-run history) + `cvd_sim.py` (Machado-2009, quarantine-tier); `generate_legibility_report.py` gains contrast + CVD sections. New event `text_oracle_passed`; new `quarantine_finding` kinds `glyph_mismatch/contrast_low/cvd_collapse`.

**Exit criteria:** a **duplicate-run raster-equivalence proof** passes (raw TextServer raster matches the in-engine Label at 7px across repeated runs) — the glyph match stays **quarantine-tier until this proof lands**, then graduates per state; garble/`low_ink` quarantine findings gain a coded graduation path; contrast check is deterministic (zero run-to-run variance) across 3 runs; `text_oracle_passed` documented + registered; change-contract green.

### Slice 5 — Lane 4 automation with grounded findings (implements Workstream L.4)

`vision_review.py`: per changed shot assembles the full-frame before/after pair + **native-resolution crops of every diff cluster** (capped full frames hide small diffs) + **numbered Set-of-Mark overlays from sidecar rects** + expected-strings manifest + rubric; invokes a pluggable reviewer via `--reviewer-cmd` (stdin JSON of paths, stdout schema JSON); **default reviewer is a deterministic sidecar-consistency checker** so the pipeline runs with no model and is CI-safe. Enforcement: every finding **must cite a region id present in the sidecar and intersect its bbox** — findings missing all regions are auto-dropped as ungrounded; `vision-review.json` schema validate/repair; reviewer discipline fixed (temperature 0, n=2 vote, before/after shuffle). Output replaces the stale pilot; `run_playtests.py` merges a quarantine section and refuses a review file older than the shots it covers. Each finding records a `finding_id` join key to any future graduated oracle. Rubric gains the grounding contract + reviewer-parameter block.

**Exit criteria:** every sweep whose shots change auto-produces `.godot-smoke/vision-review.json`; **100% of emitted findings cite a sidecar region id and intersect it** (a deliberately-bad mock reviewer's ungrounded outputs are dropped and counted); the oracle spec's success criterion is met — the rubric + grounding catches **at least one seeded visual defect that all coded oracles miss** in a validation pass, recorded as a `quarantine_finding`-class entry; calibration join keys present in the report; quarantine→graduation keys recorded.

### Slice 6 — Graduation + calibration + optional capture extensions (continuous; folds into Workstream L.5)

`graduation_ledger.py`: `finding_id`→graduated-oracle join + periodic precision/recall stats into the legibility report (the existing quarantine→graduation pipeline **is** the free VLM calibration loop). Flip `GRADUATED_STATES` per state only after **5 consecutive clean windowed runs + glyph-oracle agreement** and once feature-phase 1–3 baseline churn settles. Optional `uv` extra `vision = [scikit-image]` + `vision_metrics.py` for SSIM-map corroboration (**quarantine-tier forever, never a gate** — windowing dilutes sprite/glyph-scale defects). **Optional spikes, explicitly off the critical path**, each behind its own registry entry if adopted and never gating CI: Movie Writer PNG-burst lane (windowed at exactly 1152×648, quarantine-tier motion for `battle_anim`); DAP `godot/put_msg` bridge; ScriptBacktrace (#91006) structured frames in error traces; and the **deferred live introspection endpoint** — an in-game NDJSON-over-TCP server (`127.0.0.1`, read-only allowlist, only when `scenario.json` carries an introspection option, disabled in exports) reusing `render_introspection.gd` for interactive mid-run agent queries, built **only if** the in-process sidecars prove insufficient.

**Exit criteria:** any `GRADUATED_STATES` flip is backed by N consecutive clean windowed runs with explanations on file (the flip is Workstream L.5's decision); calibration stats show quarantine-finding precision trending up across two review cadences; any adopted optional spike ships behind its own registry entry and never gates CI.

## Vision-check catalog

| # | Check | Catches | False-positive control | Quarantine → graduation |
|---|---|---|---|---|
| 1 | Capture-validity oracle (blank/uniform/magenta #115402/undersize/headless) | Blank/magenta/wrong-scene captures; the lying headless red | Pure pixel functions; transport-vs-regression classification | **Coded red** — transport errors always loud; regression-class after clean history |
| 2 | Duplicate-capture noise floor | Run-to-run nondeterminism | Seeded captures must be bit-identical | Any delta is `capture_nondeterminism` (quarantine), investigated before gates arm |
| 3 | Canary region gate (~0 tol) | Strip-bleed, 1-frame strip offset, bilinear smear at the DECIDUEYE front frame | Arms red only after measured-zero noise floor; rect **measured in Slice 1** | **First graduated coded region** |
| 4 | Ink/string region gates (near-zero) | Garbled/moved/clipped battle text | Rects from committed sidecars + measured font model; 3× noise floor | Coded red after glyph-oracle agreement + clean streak |
| 5 | Diff clustering + ASCII grid + triptych | Localizes any change | Evidence artifacts, not verdicts | Quarantine evidence |
| 6 | Sidecar↔cluster explainer | "label PECK moved 3px", "canary absent from draw order", "palette entry dropped" | Labeled hypotheses; `unexplained` queue surfaced (guards false closure) | Quarantine — explanations never gate |
| 7 | Glyph template oracle (TextServer raster match) | Garbled/missing/clipped glyphs | Duplicate-run raster-equivalence proof; fixed deterministic font; failed match **is** the signal; tolerance from measured noise | Coded red per state after proof + clean streak (graduates garble/`low_ink` lint) |
| 8 | Min stroke width (ink run-lengths) | Wrong-scale/blurry/half-pixel text (4.5↔4.6 theme/oversampling regressions) | Pure run-length on a binarized crop | Coded red with the glyph oracle |
| 9 | WCAG rendered-pixel contrast | Text-over-battle-effect contrast loss; missing drop shadows | Deterministic luminance math confined to modeled label rects | Coded red after clean-run history |
| 10 | Machado-2009 CVD simulation | HP-bar green→red / status / canary palette collapse under protan/deutan/tritan | Deterministic 3×3 matmul (paper matrices, not the Lokno gist) | Quarantine — accessibility evidence |
| 11 | SSIM-map (optional `uv` extra) | Corroborating localization heatmap | Never a sole verdict (windowing dilutes sprite/glyph diffs) | Quarantine forever |
| 12 | Lane-4 SoM-grounded VLM review | Seeded visual defects all coded oracles miss (oracle success criterion) | Region-ID intersection auto-drops ungrounded; temp 0 / n=2 / order shuffle; deterministic default reviewer | Quarantine forever, never self-graduates; calibration ledger measures realized PPV |
| 13 | Determinism knob pinning (verify-first) | Sub-pixel variance eating the 0.5% budget | Verify-first gate; safe subset first; baseline regen in the same change | n/a (prevention) |
| 14 | HEAD/renderer stamps + stale-result sweep | Cross-machine/version baseline mismatch; stale reds | Refuse-on-stamp-mismatch | n/a (transport honesty) |

## Integration with Workstream L (extend, never duplicate)

- **L.1 `verify_all.py`** (absent today): this plan's checks (capture-validity, region gates, glyph oracle, contrast, Lane-4 invocation) are the steps `verify_all.py` absorbs when it lands; nothing here depends on it.
- **L.2 transport honesty**: implemented by Slice 1 (skip-with-reason + `capture_invalid` classification → `19/19 (1 skipped-headless)`).
- **L.3 artifact freshness / HEAD stamping**: implemented by Slice 1 (HEAD/Godot/renderer stamps + stale `result-*.json` sweep; renderer/adapter via sidecar `capture_env`, no `main.gd` edits) and hardened by Slice 3 sidecar stamps; `verify_all.py` refuses a report older than HEAD.
- **L.4 Lane-4 automation**: implemented by Slice 5 (`tools/vision_review.py`, the exact file L.4 names).
- **L.5 graduate the pixel lint**: implemented by Slice 6 (`GRADUATED`→`GRADUATED_STATES`, per-state flips with evidence).
- **Phase 0.7 leak oracle**: referenced, **not** duplicated — the `--verbose` ObjectDB leak check stays in Phase 0.

## Risks

| Risk | Mitigation |
|---|---|
| **Flakeness from the `frame_post_draw` swap** (naive substitution captures mid-resize / before the SubViewport redraws) | **Keep** the `_settle(5)` window-present wait (`visual_sweep.gd:60`) and the SubViewport-visibility wait (`ui_render_audit.gd:46`); **add** the readback guard. Red region gates arm only after the duplicate-capture noise floor measures **zero**; nonzero floors are investigated, not tolerated. |
| **Godot-version drift** (4.6 #115402 SubViewport magenta, no backport; 4.6 D3D12 default for new projects; point-release pixel shifts) | Magenta validity check + root-viewport-crop fallback; `capture_env` stamps renderer/adapter/Godot version; runner **refuses** cross-machine/cross-version baseline compare on stamp mismatch (hardens the local-only policy). |
| **VLM cost/variance** (~45% accuracy, ~19.8% PPV) | Region-ID intersection auto-drops ungrounded findings; quarantine-only, never self-graduating; deterministic default reviewer; model behind `--reviewer-cmd`; graduation ledger measures realized precision/recall. |
| **Scope / new moving parts** | Live TCP introspection endpoint **deferred** — in-process sidecars deliver ~90% of the value with zero new runtime surface; no network organ in the critical path. |
| **Canary-arithmetic correction** | `front.png` is 56×728 (56×56 frames), so the "0.034% blind spot" is unverified/likely wrong; **measure the true rect in Slice 1** and set thresholds from measurement. Region value stands for sub-region strip-bleed + masking + explainability regardless. |
| **Glyph raster-equivalence unverified** (`Font.draw_string` → CanvasItem, not Image; hinting/oversampling at 7px) | TextServer glyph-atlas readback + **duplicate-run raster-equivalence proof**; hold quarantine-tier until proven; calibrate XOR tolerance from measured noise. |
| **Baseline + sidecar churn** through feature phases 1–3 (heaviest UI change) | Canonical JSON keeps diffs reviewable; sidecars co-commit with baselines under one update command so they cannot desync; region-coverage contract check catches manifest staleness; capture slices land before / ride the churn deliberately. |
| **Determinism pins are a visible product change**; `project.godot` has no `[display]` section (manual scaling) | Verify-first gate + owner sign-off; safe subset first; if Nearest/integer-scale fights the manual path, shrink to snapping + stamps. |
| **Line-budget fragility** (`visual_sweep` 219, `ui_render_audit` 202, `main` 219, `smoke_scenarios` 219, runner 305) | Grow **none**: `visual_sweep` shrinks via delegation; `main.gd` untouched (collectors take the ctx dict); the runner is not edited in the critical path (the only future edit is the deferred endpoint). |
| **Driver-dependent pixels** (d3d12 on Windows vs Vulkan/MoltenVK on this Mac) | Stamp-and-refuse-on-mismatch enforced **before** region gates ship, so cross-machine runs never produce mystery diffs that look like regressions. |
| **`verify_all.py` absent + Phase 0.7 concurrent** | New checks are `verify_all.py` steps when L.1 lands; the `--verbose` leak oracle stays Phase 0.7 (referenced, not claimed here). |
| **Process**: all three design stances were delivered; judges scored Introspection-first vs Vision-first in detail (the minimal-incremental digest was truncated during judging) | Minimal-incremental components (transport honesty, HEAD stamping, thin deterministic default reviewer, zero new runtime surface) are grafted into the synthesis; no standalone comparison was lost. |

## Exit criteria

The initiative is done when the repo's definition of done holds **and**:

- With the current codebase clean, the full suite stays green and **two consecutive windowed sweeps are bit-identical** on all 16 shots (or every nonzero delta has a `capture_nondeterminism` trace with an identified cause).
- Re-introducing a **seeded** canary strip-bleed (1-frame offset) and a deleted battle label turns the suite **red via the region gates** with no per-bug assertion written (validation pass, then reverted) — the oracle spec's "no new assertions for that specific bug" bar.
- `PLAYTEST_FORCE_HEADLESS=1` reports `19/19 (1 skipped-headless)` and is never red on transport.
- `playtest-report.json` carries HEAD sha + Godot 4.6.1 + renderer; `verify_all.py` (once L.1 lands) refuses a report older than HEAD.
- Lane 4 produces `.godot-smoke/vision-review.json` on **every** sweep whose shots change; **100%** of findings cite and intersect a sidecar region; the rubric + grounding catches **≥1 seeded visual defect all coded oracles miss**, as a `quarantine_finding`.
- The pixel lint is graduated **per state** (`GRADUATED_STATES`) after 5 clean windowed runs + glyph-oracle agreement; the glyph oracle's raster-equivalence proof is on file.
- Every new trace event is in `trace-events.md` and the owning subsystem's `required_trace_events`; `check_repo_contracts` + `check_architecture` + `check_change_contract` + `check_quality_docs` all green; QUALITY_SCORE/RELIABILITY/tech-debt-tracker co-modified per slice.
- Whole-suite runtime stays under the ~6-minute budget; save-guard discipline unchanged.