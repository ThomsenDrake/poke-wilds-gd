Status: approved
Last verified: 2026-07-18
Review cadence days: 30
Date: 2026-07-18
Source paths: scripts/app/qa_scenarios.gd, scripts/app/nav_audit.gd, scripts/app/qa_audits.gd, scripts/app/layout_audit.gd, scripts/app/visual_sweep.gd, scripts/runtime/playtest_bot.gd, tools/run_playtests.py, tools/visual_diff.py

# Autonomous Playtesting Oracles — Design

## Purpose

The current 14-scenario suite passes while a human playtester still finds bugs it
cannot see: spatial collision defects (sprite/prop overlap, z-order, walk-through)
and rendered-text defects (garbled/overlapping battle text). Those classes escape
because today's oracles are either trace-level (no pixels) or regression-level
(baseline diffs guard only what exists and can bake in a bug). This design adds
**model-based oracles**: for any game state, the suite computes an independent
expected scene description from external truth (world data, baked art, catalog,
font metrics) and checks reality against it — catching bug *classes* without a
human describing individual bugs.

## Decisions from brainstorming

- Approach: model-based expected-scene verification (chosen over pure
  invariant-oracle expansion and fuzz-only), scoped to structure/consistency/ink
  placement — explicitly NOT pixel-perfect re-rendering.
- Runtime: windowed runs (editor DAP) allowed for pixel oracles in the default
  suite; headless lanes must carry everything that does not need pixels.
- Failure policy: two-tier. Deterministic oracles (geometry, logic, data) are
  hard gates; heuristic pixel checks start quarantined and graduate to hard
  gates once stable.

## Architecture — four oracle lanes, one model

1. **`world_consistency_audit`** (overworld): three-way cross-check per tile —
   logic (`get_tile_logic`), render (scene-tree texture; windowed pixel
   signature), collision (`is_tile_walkable` + movement probe) — plus
   player-vs-prop spatial contracts and encounter/tall-grass alignment.
2. **`ui_render_audit`** (battle + menu screens): per deterministic state,
   compute expected ink regions, forbidden zones, and structural pairs from the
   baked art + data + font metrics; verify scene tree (headless half) and pixels
   (windowed half).
3. **Soak upgrade**: the seeded bot asserts the world consistency contract on
   every step during random play.
4. **Agent vision review**: a multimodal agent reads every captured screenshot
   against a structured per-state rubric, catching what no coded oracle was
   written to catch (quarantine-tier findings).

The model's expectations anchor to **external truth**, never to the game's
layout code (testing code against itself is the failure mode of the older
audits).

## Lane 1: world consistency model

Per sampled tile, three views must agree:

1. **Logic** (`get_tile_logic`): biome, walkable, block reason, prop, gate,
   encounter flag.
2. **Render**: headless — the tile node's composed texture equals the expected
   texture for that logic dict; windowed — the tile's screen region carries the
   texture's signature colors (region-color match, not pixel-perfect).
3. **Collision**: `is_tile_walkable` agrees under current unlocks; a movement
   probe from an adjacent walkable tile succeeds iff walkable.

Player contracts: during scripted movement the player sprite's world rect never
intersects a blocking prop's solid rect; z-order contract — north of a tall
prop, the prop draws over the player, south the reverse (render-order headless,
pixel-sampling windowed). Encounter alignment: every encounter-flagged tile
renders tall grass; no non-encounter tile does.

Sampling: fixed seed 20260717, rings around spawn covering every biome, 8
samples per category per biome (blocking prop, walkable, tall grass, water edge,
field-move gate). Logic/collision/scene-tree lane is a headless hard gate;
pixel signatures run windowed, quarantined at first.

## Lane 2: UI render model

- **States**: reuse the deterministic-state machinery (crafted save, fixed
  party, scripted battle). State list: battle action/moves/item/message, party
  list + action menu + summary, bag list + party picker, start menu, message
  box. Each state is a small spec: screen + data + expected art asset.
- **Model**: from baked PNG art (box regions, borders, text baselines — measured
  from the art), catalog/snapshot data (exact expected strings), and font
  metrics (ink extents), compute: *expected ink regions* (must be dark),
  *forbidden zones* (borders, padding, inter-row gaps — must be empty), and
  *structural pairs* (cursor rect ↔ selected row).
- **Verification**: headless half — expected strings live in the right Labels at
  model rects, no two Labels' text rects intersect, stage bounds hold.
  Windowed half — expected regions exceed an ink-density threshold, forbidden
  zones stay below noise threshold, and a garble detector (row-band analysis per
  text region flags the ink profile of overlapping text runs without knowing
  the strings).
- **Evidence**: on violation, the cropped offending region plus expected-vs-found
  coordinates land in `.godot-smoke/lint/` and the JSON report.

Scene-tree half is a hard gate; pixel half starts quarantined.

## Lane 3: soak upgrade

`playtest_bot` gains per-step spatial invariants (player rect vs blocking-prop
rects; tile-position agreement after every step) with violation counts in the
`playtest_soak_passed` payload. Any violation fails the soak (deterministic).

## Lane 4: agent vision review

Pixel oracles still only assert what someone thought to assert. The final lane
is a **multimodal agent that reads every captured screenshot itself** — the
same review a human playtester does, formalized:

- After each `visual_sweep` capture (compare or update mode), a vision-capable
  agent reviews each shot against a **structured per-state rubric** (not free
  freestyle judgment): battle states check sprite integrity/framing, HUD
  legibility, text fit and overlap, cursor placement; overworld states check
  tile/prop coherence, prop grounding, tall-grass visibility, day/night tint
  plausibility; menu states check panel framing, row alignment, bar legibility.
  The rubric lives in `docs/references/vision-review-rubric.md` so it is
  versioned with the suite.
- Findings are written to `.godot-smoke/vision-review.json` (per shot: defect
  class, region, severity, confidence) and summarized in the runner output.
- Tier: vision findings are judgment, not proof — they land in the quarantine
  tier (reported, never red) unless a deterministic oracle independently
  confirms the same defect, in which case that oracle's failure governs.
- Execution: run by the orchestrator (or a swarm agent) as a documented step of
  the playtesting workflow after any sweep whose shots change — see
  `docs/RELIABILITY.md`.

## Integration

- Scenarios `world_consistency_audit` and `ui_render_audit` dispatch through
  `scripts/app/qa_scenarios.gd`; `SCENARIO_REQUIREMENTS` entries; registry under
  `app_bootstrap`; trace events `world_consistency_audit_passed`,
  `ui_render_audit_passed`, and `quarantine_finding` (heuristic, non-failing).
- `tools/run_playtests.py` default set gains both audits; the JSON report gains
  a `quarantine` section.
- Graduation: each heuristic check carries a declared flag (`GRADUATED := false`
  warns; `true` gates). A check flips only after staying clean across repeated
  real runs.
- Budgets: headless audits < 30s each, windowed `ui_render_audit` < 60s, whole
  suite < ~6 minutes. Repo line budgets, layer rules, and contract docs apply.

## Non-goals (YAGNI)

- No pixel-perfect re-rendering of frames.
- No animation-frame verification.
- No audio assertions.

## Success criteria

- With the current codebase clean, the full suite stays green.
- Re-introducing any historical instance of the target classes (tree canopy
  overlap, blocked-tile walk-through, battle text overlap/overflow, sprite-into-
  frame bleed) turns the suite red without any new assertions being written for
  that specific bug.
- The agent vision review produces its structured findings file on every sweep
  whose shots change, and its rubric catches at least one seeded visual defect
  that all coded oracles miss in a validation pass.
- Suite runtime stays within the budget above; save-guard discipline unchanged.
