Status: current
Last verified: 2026-07-23
Review cadence days: 21
Source paths: scripts/app/world_consistency_audit.gd, scripts/app/ui_render_audit.gd, tools/vision_review.py, tools/vlm_reviewer.py, docs/registry/art-anchors.toml, .godot-smoke/shots

# Vision Review Rubric

After any `visual_sweep` run whose shots change, `tools/vision_review.py` auto-produces `.godot-smoke/vision-review.json` — the Lane-4 structured findings file (oracle spec: `docs/superpowers/specs/2026-07-18-autonomous-playtesting-oracles-design.md` § Lane 4). Its DEFAULT REVIEWER is a deterministic in-process sidecar-consistency checker — no model, CI-safe, byte-stable findings per seed; a model or human reviewer plugs in via `--reviewer-cmd` (§ Lane-4 automation). The model-reviewer lane is PLUGGED IN AND DEMONSTRATED: `tools/vlm_reviewer.py` (§ Reviewer parameters) implements the socket and is wired into the runner post-step as an OPT-IN (`VISION_REVIEWER_CMD`, default unset ⇒ the deterministic lane; CI never sets it), and answers the judgment and non-baked-UI questions no coded class can express. The first positive model-answered manifest is LIVE-VERIFIED — "Qwen 3.8" (hosted `qwen3.8-max-preview` via the user's token-plan MaaS endpoint, `DASHSCOPE_API_KEY` env-only) answered all 19 rubric questions across all 5 shot groups (`reviewer_kinds_ran` includes `model-qwen3-vl`, 19/19 answered, 0 findings on the aligned tree, exit 0); local `ollama pull qwen3-vl:8b` is the offline FALLBACK (this box has no model pulled). When the model is positively unavailable (no key, server down, not pulled, per-call timeout) the lane degrades to the deterministic pass with the reason recorded (exit 0) and its model-only questions below are counted UNANSWERED — honest, never faked. The art-anchor layer (§ Grounding contract, `anchor:<id>`) carries geometric truth — the two mechanisms TARGET G1 (no source-art anchor; mechanical, proven by plant) and G2 (no rubric answerer; mechanism landed and wired, model-answered demonstration LIVE-VERIFIED) as one slice, and the G1↔G2 bridge is now CODE: `tools/vision_review.py` reads the registry into `anchor:<id>` regions and its `anchor_drift` class (reviewer_kind `deterministic-art-anchor`) answers the HP-bar track-geometry question whenever a changed battle shot is reviewed — the recursive battle draw_order collection (render_introspection.gd) exposes the nested `PlayerHUD/PlayerHPBar` so BOTH bars are live-verifiable. The questions below are the rubric every reviewer answers for each shot's state group; any "no" is a finding.

Findings are quarantine-tier: reported, never failing, unless a coded oracle independently confirms the same defect. Only tool ERRORS (bad PNG decode, reviewer subprocess timeout/non-zero/invalid JSON, unwritable output) fail the run red (fail-closed). Every emitted finding MUST be grounded — cite a sidecar region id and intersect its bbox (§ Grounding contract); ungrounded reviewer output is dropped and counted, never emitted.

The output shape is schema `vision-review/2` (§ Finding schema). It REPLACES the pilot's bare array of `{shot, findings: [...]}` plus a `_review` pseudo-shot coverage-gap row: the first run unconditionally deletes/overwrites the gitignored July-2026 pilot file (its shape fails schema validation and is replaced, not repaired). The pilot `_review` observation — overworld y-sort has no pixel canary — survives as the per-shot-kind coverage table below plus the `ungroundable_deltas` count, never as a fake finding.

## Reviewer parameters (recorded discipline)

Every reviewer — model plugin or deterministic default — runs under a fixed parameter contract, recorded in the output's `reviewer.params` block (and shipped to `--reviewer-cmd` plugins in the stdin `reviewer_params`). The pipeline mechanically enforces GROUNDING after any reviewer returns (§ Grounding contract), but NOT the vote: n=2 / unanimity / order_shuffle are an honor-system contract a model plugin must honor (the pipeline calls a plugin ONCE per shot and takes its findings list), and for the deterministic default they are recorded but not spent:

| Parameter | Value | Meaning |
| --- | --- | --- |
| `temperature` | `0` | No sampling creativity. |
| `n` | `2` | Two independent passes (model reviewers). |
| `vote` | `both-passes-must-emit (unanimity)` | A finding survives only if BOTH passes emit it. |
| `order_shuffle` | `true` | The before/after frame order is shuffled per pass so a reviewer cannot key on position. |
| `runs` | `1` | The deterministic default runs ONCE — votes are meaningless when the reviewer is a pure function of its inputs. The n=2/shuffle parameters are recorded (the interface is honored) but not spent. |

The deterministic default is grounded by construction; model reviewers are held to the same grounding enforcement after they return (§ Grounding contract — enforcement is the gate, not a lint).

The model-reviewer lane is PLUGGED IN AND DEMONSTRATED (opt-in; the first model-answered manifest is LIVE-VERIFIED on hosted `qwen3.8-max-preview` — 19/19 rubric questions answered, exit 0 — with local `ollama` `qwen3-vl:8b` as the offline fallback, this box having none pulled; full runtime + offline behavior in [RELIABILITY.md](../RELIABILITY.md) § Agent vision review) by `tools/vlm_reviewer.py`, which HONORS this contract wrapper-side (the pipeline calls a plugin once and trusts it to spend the vote, so the wrapper enforces it): temperature 0; n=2 = two separate `/api/chat` calls (Ollama has no `n` field) intersected for unanimity (a finding survives only if BOTH passes emit the same class+region_id); before/after Set-of-Mark order shuffled per pass under a recorded seed. HONEST RECORDING: at strict temperature 0 the two calls are identical greedy decodes, so `reviewer_meta.vote_semantics` records n=2 as a DETERMINISM/REPRO GUARD, NOT an independent vote; `VLM_INDEPENDENT_VOTE=1` (or `--independent-vote`) switches to temperature 0.2 + two distinct seeds for a genuine two-sample vote (off by default). The model is never asked for `bbox` — it cites a `region_id` and the wrapper sets `bbox` to that region's rect (the pipeline owns geometry). Model findings are QUARANTINE-FOREVER and are never promoted to red; only byte-derived `anchor:<id>` findings graduate (§ Grounding contract). A model pass that is positively unavailable (server down, model not pulled, timeout) records the reason in `reviewer_meta` and degrades to the deterministic pass with exit 0 — coverage never depends on the model running.

## Overworld states (`01_`, `02_`, `03_biome_*`)

- Does every biome read as its intended terrain (water blue, sand tan, grass
  green, rock gray, snow white, lava red)?
- Do props sit ON their tiles (grounded at the tile's bottom edge, not floating
  between tiles, not sunk into the ground)?
- Does the player render behind tall prop canopies when standing north of them
  and in front when standing south?
- Are tall-grass patches visibly distinct from short grass, and do they appear
  in grass biomes only?
- Is anything rendered as an untextured solid-color or repeated-ghost blob?
- Is the player sprite intact (no clipped frames, no direction mismatch)?

## Day/night states (`04_night`, `05_dawn`)

- Is the tint plausibly nighttime (dark blue) / dawn (warm) without text or the
  player becoming unreadable?
- Does UI (hint bar) stay untinted?

## Menu states (`06_menu`, `07_party_screen`, `08_bag_screen`)

- Is the world uniformly dimmed behind the UI with no undimmed band?
- Are panels framed and readable against the dim?
- Does every row align its name, level, HP bar, and counts on one line?
- Are HP bars visible and color-graded (green/orange/red)?
- Is any text clipped, overlapping, or escaping its panel?

## Battle states (`09_battle` … `12_battle_items`)

- Is each Pokemon sprite a single clean frame (no strip bleed, no stretching,
  no slivers), positioned in its arena spot?
- Do name plates read fully (no garbled glyphs) with the level after the name
  and any status tag clear of the level?
- Is all text inside its box, with nothing crossing borders?
- Is the cursor vertically centered on the row it selects?
- Are HP bars on their baked tracks, and do HP numbers show a single slash?
  (needs: deterministic-art-anchor answers the track GEOMETRY — each anchored bar's
  live draw_order rect is compared byte-side to its art-anchors.toml stage_rect within
  tol_px whenever a changed battle shot is reviewed; model-qwen3-vl keeps the
  single-slash number JUDGMENT)

## Camping states (`15_camp_night_lit`, `16_craft_menu`, `17_dawn_after_rest`)

- In `15_camp_night_lit`, is a warm glow visible around the fire (campfire and
  torch) over the night tint, with no glow where the fire is extinguished?
- In `16_craft_menu`, are the recipe names + ingredient counts legible (no
  clipping, no overlap, affordable and missing rows distinct)?

## Display-matrix states (`matrix/<w>x<h>_battle.png`)

- At EVERY window size: is the text pixel-crisp (uniform stroke widths, no
  shimmering/uneven glyph columns), the surface centered with even margins,
  and nothing clipped at the surface edges?

## Grounding contract

Enforcement is mandatory and pipeline-side: it runs after ANY reviewer returns and BEFORE `vision-review.json` is written. A finding is GROUNDED iff:

1. it carries a `region_id` string resolvable in the shot's region table — the union of the FRESH + BASELINE sidecars, addressed per the namespace below; AND
2. its integer `bbox` `[x,y,w,h]` (native display px, w>0, h>0, inside the window frame) passes `visual_explain.rects_overlap(bbox, region_rect)` against at least one rect registered to that id.

`rects_overlap` is imported from `tools/visual_explain.py` via the sanctioned importlib pattern — the SINGLE geometry home (the same function `visual_region_diff._classify` uses), never re-implemented.

### Region-id namespace

All rects are DISPLAY-px except `draw:*` (stage px, mapped at grounding time):

| Region id | Sidecar source | Groundable rect(s) | Notes |
| --- | --- | --- | --- |
| `canary` | `canary_rect` | Battle 09-12 only: (640,68,224,224) | `[]` elsewhere → uncitable |
| `ink:<i>` | `expected_regions.ink[i]` | That ink rect | Battle only (e.g. `10_battle_moves` `ink:0`-`ink:2` = the three move-label rects) |
| `string:<TEXT>` | `expected_regions.strings` entries matched by text | Union of that text's entry rects | Anchor strings are unique per shot (PECK / RAZOR LEAF / SYNTHESIS, POKE BALL x5 / POTION x3 / BACK); the box-mode dup `'35'` shares one box rect (harmless) |
| `label:<i>` | `labels[i]` by ARRAY INDEX | That label's `display_rect` | Deterministic `UiRenderModel.visible_labels` traversal; disambiguates duplicate texts (the two `'DECIDUEYE'` on 09); the payload carries the text |
| `cursor:<id>` | `cursor_pairs` entry by id | Cursor cell ∪ row ∪ live (ANY of the three counts) | Ids: fight / pkmn / item / run, move_0..3, poke_ball / potion / back; the row is groundable for citation even though it is deliberately NOT a diff mask; an id present with `live []` is still citable (fresh cursor cell + row + baseline live remain) |
| `draw:<node>` | `draw_order` entries by node id | Stage rect mapped stage→display | Node ids are STAGE-RELATIVE PATHS — the recursive battle collection names a nested node `Parent/Child` (e.g. `draw:PlayerHUD/PlayerHPBar`); a direct child keeps its bare name. Mapping: the documented `battle_view` layout formula `k = floor(min((w-32)/160, (h-32)/144))`, centered in `window`; runtime-cross-checked (the mapped `draw:Cursor` rect must equal the `cursor_pairs` live rect whenever the cursor is visible). Ungroundable when the rect is `[]` (ALL overworld nodes: World/GroundLayer, World/PropLayer, Player carry rect [] with only y_sort/order semantics) or `draw_order` is `[]` (all menu shots) |
| `palette:canary` | `palettes.canary` | `canary_rect` (the scan covers the canary interior) | `palette:hud` has NO rect in the sidecar (the `palette_regions` intermediate is converted and dropped) → UNgroundable → context only, never findings |
| `anchor:<id>` | `art-anchors.toml` `[[anchors]]` by id | The anchor's `stage_rect` mapped stage→display via the single `_stage_to_display` home | The FIRST region whose rect is ART-TRUTH, not sidecar/code-output (the G1↔G2 bridge, IMPLEMENTED in `tools/vision_review.py`). Sourced from [art-anchors.toml](../registry/art-anchors.toml) via `art_geometry` (`load_registry` + `rects_close`); the `anchor_drift` class (reviewer_kind `deterministic-art-anchor`, quarantine-tier, graduating per-anchor) compares each anchored node's LIVE `draw_order` stage rect to the anchor `stage_rect` within the registry `tol_px` — drift emits a finding grounded by construction (bbox = the enclosing rect of the live mapped rect ∪ the registered anchor rect, so it intersects the anchor rect for drifts of any magnitude); a node absent from `draw_order` is counted UNVERIFIED in a warning, never a finding — and VLM fidelity findings on art features ground here through the existing `rects_overlap`. Seeded: `anchor:battle/enemy_hp_track` (32,18,48,4), `anchor:battle/player_hp_track` (96,74,48,4) — battle only |

Per-shot-kind coverage (verified from the committed sidecars):

| Shot kind | Groundable regions |
| --- | --- |
| Battle 09-12 | ALL kinds (richest; the validation plant lives here) |
| Menu 06-08 | `label:<i>` ONLY (06: MENU + hint labels; 07 party: 7 labels incl. the `'>'` cursor-label; 08 bag: 3 labels; cursor_pairs [], draw_order [], palettes empty) |
| Overworld 01-05 | ZERO groundable regions (canary [], labels [], expected_regions empty, cursor_pairs [], palettes empty, draw rects []) — reviewers emit NO findings there; sidecar deltas (e.g. 04_night Player y_sort/order) are counted as `ungroundable_deltas` context |
| Camping 15-17 | ZERO groundable regions (committed sidecars carry empty canary/labels/cursor_pairs/expected_regions) — the two camping questions are model-only judgment, counted UNANSWERED offline like every model-only question |

Consequence: Lane-4 coverage is battle-heavy by current sidecar contents (matching the pilot `_review` note that overworld y-sort has no pixel canary). Extending sidecars (e.g. a `dynamic_zones`/mapped overworld rect field) is a future slice, not a rubric change; the plant for any validation pass must live on a battle shot (or a menu label).

### Drop-and-count

Findings failing (1), (2), or schema validation that cannot be repaired are AUTO-DROPPED — excluded from the emitted findings array — and counted in file-level grounding stats `{emitted, grounded, dropped, dropped_reasons: {unknown_region_id, no_intersection, schema_invalid, bbox_out_of_frame}, dropped_samples[<=8]}`. The exit-2 invariant: 100% of EMITTED findings are grounded BY CONSTRUCTION because enforcement is the gate, not a lint — the deterministic default is grounded by construction and enforcement is defense-in-depth; a mock reviewer's garbage is dropped + counted with exit still 0 (drops are not errors; only tool errors exit 2 / fail the runner red).

Regions WITHOUT a rect (overworld draw nodes with rect [], `palette:hud` — no rect exists in the sidecar) are UNgroundable: the reviewer must never cite them; deltas there are recorded in bundle context and counted as `ungroundable_deltas`, never as findings. Silence is counted, never lost (the explicit-queue philosophy).

### What a finding must carry

`shot`, `class` (rubric defect-class vocabulary), `region_id`, `bbox`, `region` (the cited sidecar rect that grounded it), `severity` (low/medium/high), `confidence` (enum), `note` (rubric-compat), `explanation` (a sentence citing the sidecar evidence), `evidence_crop` (bundle-relative path), `sidecar_ref` (`{source: baseline|fresh|both, field, baseline, fresh}`), and `finding_id`.

## Finding schema (`vision-review/2`)

Top level (replaces the pilot's bare array; first run unconditionally overwrites the gitignored pilot):

```json
{
  "schema": "vision-review/2",
  "generated_by": "tools/vision_review.py",
  "generated_at": "<ISO8601>",
  "head_sha": "<str|null>",
  "rubric_ref": "docs/references/vision-review-rubric.md",
  "reviewer": {
    "kind": "deterministic-sidecar-consistency|cmd",
    "cmd": "<str|null>",
    "params": {"temperature": 0, "n": 2, "vote": "both-passes-must-emit (unanimity)", "order_shuffle": true, "runs": 1,
               "note": "n=2 vote honored only for model reviewers; deterministic default runs once — votes are meaningless when deterministic"}
  },
  "manifest": {
    "window": [1152, 648],
    "shots_covered": [{"shot": "...", "sha256": "...", "baseline_sha256": "...", "sidecar_fresh_sha256": "...", "sidecar_baseline_sha256": "...", "changed": false}]
  },
  "grounding": {"emitted": 0, "grounded": 0, "dropped": 0,
                "dropped_reasons": {"unknown_region_id": 0, "no_intersection": 0, "schema_invalid": 0, "bbox_out_of_frame": 0},
                "dropped_samples": [], "ungroundable_deltas": 0, "ungroundable_clusters": 0, "ungroundable_shots": []},
  "shots": [{"shot": "...", "changed": false, "bundle": "<dir or null>", "reviewer_raw_count": 0, "dropped_count": 0, "findings": []}],
  "warnings": []
}
```

Per finding (rubric fields kept + extensions) — the example below is the ACTUAL seeded-plant finding, byte-replayable (recomputing `finding_id` over `{bbox, baseline, fresh}` reproduces the hex in the crop filename):

```json
{
  "finding_id": "vr1-7327ba082213fd17",
  "shot": "10_battle_moves.png",
  "class": "cursor_missing",
  "region_id": "cursor:move_0",
  "region": [404, 452, 16, 16],
  "bbox": [404, 448, 128, 36],
  "severity": "medium",
  "confidence": "high",
  "note": "cursor 'move_0' missing",
  "explanation": "Cursor live rect present in baseline is gone in the fresh capture. Is the cursor vertically centered on the row it selects? (presence precondition)",
  "evidence_crop": "vision-review/10_battle_moves/crop_vr1-7327ba082213fd17_cursor_move_0.png",
  "sidecar_ref": {"source": "both", "field": "cursor_pairs[id=move_0].live", "baseline": [404, 452, 32, 32], "fresh": []},
  "reviewer_kind": "deterministic-sidecar-consistency"
}
```

Field notes:

- `region` — the cited sidecar rect that grounded the finding; `bbox` — the finding extent, which MUST intersect `region`.
- `evidence_crop` — bundle-relative path to a native-resolution base|fresh twin of the cited region.
- `sidecar_ref` — the exact sidecar field plus the baseline/fresh values the finding came from (the auditable join).
- UNCHANGED shots still get a `shots` entry (`changed: false`, `findings: []`) so the manifest is the complete freshness authority.

REPAIR rules: severity/confidence coerced to enum (bad → medium/low + repair note), bbox int-coerced; missing/unknown `region_id` or an unrepairable bbox → DROP (counted). `finding_id` is computed POST-repair by the pipeline — reviewers never mint it.

### finding_id (Slice-6 ledger join key)

Stable join key for the graduation ledger: `vr1-` + the first 16 hex chars of sha256 over canonical JSON (`json.dumps(sort_keys=True)`, compact separators) of exactly:

```json
{"v": 1, "shot": "...", "class": "...", "region_id": "...", "bbox": [0, 0, 0, 0],
 "sidecar_field": "<sidecar_ref.field or null>",
 "baseline": "<sidecar_ref.baseline>", "fresh": "<sidecar_ref.fresh>",
 "cluster": false}
```

`cluster` is true for `cluster_unexplained` findings, whose identity is the bbox alone. DELIBERATELY EXCLUDED: timestamps, head_sha, file paths, reviewer kind, severity/confidence, evidence_crop — so the SAME defect at the same shot/region/values hashes identically across re-runs, transports, and reviewer implementations (a model reviewer and the deterministic default reporting the same defect JOIN in the ledger). The versioned prefix (`vr1-`) lets Slice 6 rotate the scheme without silent collisions. Baseline regeneration changes the defect-free state — hence baseline/fresh values, hence ids; the ledger treats a baseline regen as a new epoch (the baseline sidecar sha is carried in `sidecar_ref` context, not the hash, so the epoch is auditable without destabilizing ids within an epoch). Every report quarantine entry of kind `vision_review` carries `finding_id`, so Slice 6's `graduation_ledger.py` joins a graduated coded oracle's finding to the quarantine finding it confirms.

## Lane-4 automation (`tools/vision_review.py`)

The pipeline runs on every `visual_sweep` compare run — as a `run_playtests.py` post-step (`apply_vision_review`) and standalone — with NO model required:

```bash
python3 tools/vision_review.py --shots-dir .godot-smoke/shots --baseline-dir docs/generated/visual-baselines
# optional model/human plugin:
python3 tools/vision_review.py --shots-dir .godot-smoke/shots --baseline-dir docs/generated/visual-baselines --reviewer-cmd "my-reviewer --flag"
```

Exit contract: 0 = review written (including with dropped findings — drops are not errors), 2 = tool error (fail-closed: bad PNG decode, reviewer subprocess timeout/non-zero/invalid JSON, unwritable output). Standalone use and the runner post-step share the contract; the runner records `vision_review_written` plus kind-`vision_review` quarantine entries (see [vision-fidelity.md](../product-specs/vision-fidelity.md) § Lane 4 automation and [RELIABILITY.md](../RELIABILITY.md)).

### Bundle (per CHANGED shot)

For each shot whose fresh PNG bytes differ from its baseline bytes (`visual_region_diff`'s byte-identical shortcut), the pipeline assembles `.godot-smoke/vision-review/<stem>/`:

1. `before.png` / `after.png` — raw byte COPIES of the baseline + fresh frames (native 1152x648; no re-encode).
2. `crop_NNN_<tag>.png` — NATIVE-RESOLUTION crops (capped full frames hide small diffs — the point of the crops): one base|fresh twin per `clusters.json` cluster (cluster bbox + 8px padding, clamped to frame, 4px gap, panels labeled via `png_canvas.text`), built with `visual_diff.decode_png_rgba` + `png_canvas` blit/box/text; region crops for grounded findings are added post-review as each finding's `evidence_crop` (cited region rect + padding, base|fresh twin).
3. `som_before.png` / `som_after.png` — Set-of-Mark overlays (arXiv 2310.11441): full-frame copies with EVERY groundable region outlined (1px box, color per kind: canary red, string/ink/label amber, cursor cyan, anchor green, draw gray, palette:canary magenta) plus a NUMBER at each box (`png_canvas` 3x5 font); numbering is deterministic (kind priority then region-id), and the number→region_id legend ships in the reviewer's stdin JSON (`som_legend`), not pixels-only. SoM frames require a decode→blit of 746,496 px (pure-Python loop, ~1-2 s/frame; bounded — only changed shots get SoM; never downscale SoM, since capped frames are the exact failure mode).
4. `expected_strings.json` — the expected-strings manifest: fresh sidecar `expected_regions.strings` + `labels[]` (text, region, mode, avoid).
5. `rubric.txt` — this rubric's section for the shot's state group (prefix map: 01-03 overworld, 04-05 day/night, 06-08 menu, 09-12 battle, matrix/ display-matrix).
6. `context.json` — shot kind, crafted_state, window, clusters summary (bbox + changed + tier + sentence), the computed sidecar delta list, the region table (id → {kind, rects, source sidecar}), and the number→region_id `som_legend` (the same dict that ships in the stdin JSON).

REVIEWER INVOCATION: a `--reviewer-cmd` plugin gets stdin JSON `{shot, shot_kind, paths{before, after, som_before, som_after, crops[], expected_strings, rubric, context}, reviewer_params, finding_schema, region_table, window, clusters, som_legend, grounding_rules}` and must return stdout `{"findings": [...]}` (subprocess with `shlex.split`, NO `shell=True`, timeout default 300s; non-zero/timeout/invalid JSON = tool error → exit 2 / runner exception red, fail-closed — a hung or garbage plugin is never a silent pass). `window` (frame bounds), `clusters` (change regions), and `som_legend` (the SoM number→region_id join) ride in stdin — not only the on-disk `context.json` — so the plugin can build in-frame, groundable bboxes from stdin alone. The deterministic default is an in-process function with the SAME (stdin-dict → findings-list) signature — the interface is honored, the subprocess is skipped. Returned findings then go through schema validate/repair → grounding enforcement → finding_id minting → write.

### Default reviewer (deterministic sidecar-consistency)

In-process, no model, CI-safe: a pure function of sidecar + clusters bytes → byte-stable findings per seed. It receives the SAME stdin dict a `--reviewer-cmd` plugin would (plus the rubric excerpt for the shot's state group), honoring the interface. Every finding cites a region BY CONSTRUCTION because each is generated FROM a sidecar field and `bbox` = that field's rect(s):

| Class | Trigger | Citation |
| --- | --- | --- |
| `label_deleted` | Baseline `labels[i].text` occurrence deleted — the fresh capture has fewer occurrences of the text (multiset: duplicate texts like the two `'35'` count per occurrence, so deleting ONE fires) | `label:<i>`, bbox = baseline display_rect |
| `label_moved` | Same text, display_rect differs | `label:<i>`, bbox = baseline rect, fresh rect in sidecar_ref |
| `label_text_changed` | Same index, text differs | `label:<i>` |
| `cursor_missing` / `cursor_moved` / `cursor_appeared` | `cursor_pairs` matched by id: live rect→[] / moved / []→rect | `cursor:<id>`, bbox = the enclosing rect of the pair's BASELINE cursor cell ∪ row ∪ live (`cursor_missing`) or the live rect (moved: baseline; appeared: fresh) — the validation plant produces exactly `cursor_missing` on move_0, bbox [404,448,128,36] |
| `draw_order_changed` | Node sequence, z, or y_sort order delta | `draw:<node>` ONLY when the rect is groundable, else ungroundable-context count |
| `anchor_drift` | Live `draw_order` rect of an anchored node off its `art-anchors.toml` `stage_rect` by more than `tol_px` (stage-to-stage compare; a node absent from `draw_order` is counted UNVERIFIED in a warning, never a finding) | `anchor:<id>`, bbox = the enclosing rect of the live rect mapped stage→display ∪ the registered anchor rect (contains the anchor rect, so it intersects by construction for drifts of any magnitude — a live-rect-only bbox would stop intersecting once the drift reaches the bar width); reviewer_kind `deterministic-art-anchor`; self-tags into the coverage ledger even on a zero-drift pass |
| `palette_dropped` | Baseline `palettes.canary` − fresh non-empty | `palette:canary` (bbox canary_rect); hud deltas never emit (ungroundable) |
| `canary_rect_changed` | Canary rect delta | `canary` |
| `expected_region_changed` | Ink/string rect-list deltas | `ink:<i>` / `string:<TEXT>` |
| `cluster_unexplained` | ONE finding per `clusters.json` cluster with `explained == false` | bbox = cluster bbox; region_id = MOST-SPECIFIC groundable region intersecting the bbox, priority cursor-live > string > label > ink > anchor > canary > draw (smallest mapped rect) > palette:canary; intersects NOTHING → not emitted, counted as `ungroundable_clusters` (explicit queue preserved) |

Deterministic severity/confidence map: sidecar deltas medium/high, canary + palette + anchor drift high/high, clusters low/medium. It emits NOTHING for byte-identical shots and NOTHING groundable for overworld/menu shots lacking regions — the coverage gap is counted, not faked.

### Staleness (shot-hash manifest)

`manifest.shots_covered[]` carries the sha256 of each FRESH PNG's bytes (content hash — mtime-independent) plus the baseline + both sidecar hashes; this is the freshness authority. `review_is_fresh(review_doc, shots_dir, baseline_dir)` returns false when any covered shot's current bytes mismatch ANY hash its manifest entry recorded (the fresh PNG sha always; the baseline PNG + both sidecar shas whenever recorded — a recorded hash whose file is gone is also stale; hashes the builder could not record, e.g. a missing sidecar at write time, are skipped), or a shot in shots_dir with a baseline PNG is absent from the manifest (the shot-scope predicate is the manifest builder's own — has-baseline-PNG; `baseline_dir=None` degrades to the legacy has-fresh-sidecar scope + fresh-PNG-only comparison for callers that know only the shots dir). The runner post-step passes `baseline_dir`, so all four recorded hashes gate freshness there. It REGENERATES the file on EVERY visual_sweep compare run (even 0 changed shots — full manifest, zero findings), so staleness cannot persist after a sweep; if the post-step is SKIPPED (a transport-skip run) and a stale file exists on disk, the runner REFUSES it — does not record `vision_review_written`, prints a warn — and `tools/verify_all.py` (Workstream L.1, IMPLEMENTED) refuses-on-mismatch the same way the report `head_sha` hook does: its R6 post-refusal calls `review_is_fresh` (importlib-loaded from this module) over `.godot-smoke/shots` vs `docs/generated/visual-baselines` and REFUSES (exit 2) on a stale `.godot-smoke/vision-review.json`, degrading to a WARN under `--skip-windowed`. Lane-4 staleness is never red (quarantine tier): refuse = ignore + warn + regenerate, never fail.

## Validation plant record (Slice 5)

CONCRETE SEEDED DEFECT — "moves-menu cursor missing" on `10_battle_moves`. TEMPORARY EDIT: `scripts/ui/battle_surface.gd` line 123, inside `_render_moves`: `_place_cursor(selected)` → `_place_cursor({})` (one line; `_place_cursor({})` sets `_cursor.visible=false` via the `option.is_empty()` branch at :154). `visual_sweep` captures shot 10 right after entering the moves menu (`visual_sweep.gd:152-156`), so the fresh capture + fresh sidecar show PECK/RAZOR LEAF/SYNTHESIS labels + FLYING/35/35 info ALL PRESENT, cursor GONE.

Why EVERY coded oracle is silent (measured geometry from the committed baseline `10_battle_moves.png` + sidecars):

- (a) canary ~0: the arrow ink lives at x404..435 — the canary is (640,68,224,224), untouched.
- (b) ink/string/label regions RED gate: the nearest coded rect is PECK [436,448,96,28]; measured arrow-ink max x = 435, a 1px gap; `rects_overlap` is strict → zero overlap; the erased ink x404..435 y452..483 intersects no ink/string/label rect.
- (c) region-diff mask: the erased arrow lies ENTIRELY inside the baseline cursor mask (cursor cell [404,452,16,16] + live [404,452,32,32]) → analysis set empty → ZERO clusters → no region_drift, no unexplained queue entry, no region_quarantine record at all (this is why the strict "no coded finding, red or quarantine, references it" holds vacuously).
- (d) glyph oracle: ANCHOR strings start at x436; zero XOR delta inside their rects; T_str=2 / T_glyph=1 untouched; `text_oracle_passed` still fires with unchanged states/strings/glyphs counts.
- (e) `ui_render_audit._check_pairs`: the model-vs-row check is unchanged; the live-position check is SKIPPED for the hidden cursor (`not live.visible` at :121 → no cursor_misplaced).
- (f) `layout_audit._audit_cursors`: consumes the layout MODEL (option cursor_pos from `battle_surface_layout._move_model`), never the live node's visibility → drift/cover checks unchanged.
- (g) contrast_check: fresh `labels[]` rects unchanged, cursor intersects none.
- (h) CVD: `palettes.canary` unchanged; hud set changes are invisible to every coded gate (cvd_sim reads canary + the hardcoded HP triple only).
- (i) global 0.5% backstop (unmasked, tol 8): ~600 erased px ≪ 3,732.

`visual_sweep` compare passes; `visual_sweep_passed` fires; the run stays GREEN.

Why the DEFAULT deterministic reviewer catches it: fresh `cursor_pairs[move_0].live = []` vs baseline `[404,452,32,32]` → a `cursor_missing` finding citing `cursor:move_0` (the id is present in BOTH sidecars; bbox = the enclosing rect of the pair's baseline cursor cell ∪ row ∪ live, [404,448,128,36], grounded on the cursor cell [404,452,16,16] it intersects); `evidence_crop` = the base|fresh native twin of the cited region showing the arrow gone; the explanation quotes the battle question above — "Is the cursor vertically centered on the row it selects?" (presence precondition) — a defect class NO coded oracle implements (`cursor_pairs` exists in the coded layer ONLY as a diff mask, which is precisely what blinds every pixel gate to it — Lane 4's unique value). Recorded as a `quarantine_finding`-class entry kind `vision_review` in the report + a vision-review.json finding with `finding_id`.

REVERT + PROOF: `git checkout -- scripts/ui/battle_surface.gd` (the file is not otherwise co-modified in Slice 5) → `git diff -- scripts/ui/battle_surface.gd` empty; the post-revert windowed sweep's fresh sidecar is byte-identical to the baseline sidecar modulo {ts_msec, trace_cursor} (canonical byte-stability, Slice-3 evidence). Validation commands (windowed, 600000 ms timeout, never concurrent): `python3 tools/run_playtests.py --scenario visual_sweep` then `--scenario ui_render_audit` then `--scenario layout_audit` under the plant; assert run green + zero coded findings on shot 10 + exactly the `cursor_missing` vision_review finding grounded on `cursor:move_0`; plus a mock-reviewer drop-and-count run (exit stays 0, drops counted).

## Rubric coverage semantics

The mechanized version of the pilot's RETIRED `_review` coverage-gap pseudo-row (implemented in `tools/vision_review.py`): instead of a fake finding, "the rubric's art-fidelity questions were answered" is a checkable, freshness-gated, HONESTLY-COUNTED fact. `parse_rubric_questions` parses the per-shot-group `## ` sections above into a stable inventory (the SAME heading markers the bundle excerpter uses, so the ledger and the per-shot rubric excerpt never disagree); `QUESTION_ANSWERERS` declares which reviewer KIND can answer each question; and the manifest's `rubric_coverage` block (schema `rubric-coverage/1`) records, per shot-group, which kinds ran a fresh pass and which questions are therefore answered.

- **Stable question ids.** `question_id = "q1-"` + the first 8 hex of sha256 over the canonical (whitespace-collapsed) question text — stable across REORDERING; REWORDING rotates the id (surfaced as an UNASSIGNED question, never a silent loss), and a brand-new question nobody mapped is likewise counted. (The `vr1-` `finding_id` convention applied to questions.)
- **Answered predicate.** A question is `answered` iff a CAPABLE reviewer kind RAN this pass (`_kinds_that_ran`: the configured reviewer plus every kind that self-tagged an emitted finding or a returned answer — a composite VLM/art-anchor wrapper self-tags, so its coverage registers without any pipeline change), OR a returned `answers[]` entry addressed its id.
- **Unanswered is a first-class COUNTED state** — never faked as answered, never red (advisory-loud). A shot-group with unanswered questions emits a `rubric_coverage_gap [<group>]: N of M rubric question(s) have no fresh reviewer pass (needs [...])` line that rides the manifest `warnings[]`, the legibility report, and `verify_all`'s WARN surface (degrading under `--skip-windowed` like R6). Overworld reports its reason as "no fresh reviewer of kind [model-qwen3-vl] ran this pass; overworld shots carry zero groundable regions" — the honest, mechanized form of the pilot's "overworld y-sort has no pixel canary" note.
- **Question-count backstop.** `EXPECTED_QUESTION_COUNTS` pins the inventory — overworld 6, day_night 2, menu 5, battle 5, camping 2, display_matrix 1 (21 total) — so editing the rubric cannot SILENTLY EMPTY a question list: a drift records a loud advisory warning AND fails the RED `check_repo_contracts` backstop (`rubric_inventory_issues`, folded into `check_repo_contracts.run()`) — both forcing a deliberate re-map. **Do not add, remove, or reword the bullets in the five shot-group sections above without re-mapping `QUESTION_ANSWERERS` / `EXPECTED_QUESTION_COUNTS`.**
- **Freshness.** `rubric_coverage` rides the sha256 manifest, so `review_is_fresh` covers it; the lane-4 staleness refusal (§ Staleness) applies unchanged.

### Answerers table (`QUESTION_ANSWERERS`)

Matching is by CONTENT (a distinctive lowercase fingerprint substring of the canonical question text), so the join is robust to reordering and a reword breaks its fingerprint → unassigned (counted). Reviewer kinds: `deterministic-sidecar-consistency` (the default), `deterministic-art-anchor` (the art-anchor drift class), `model-qwen3-vl` (Qwen3-VL).

| Shot group | Question fingerprint | Capable reviewer kinds |
| --- | --- | --- |
| battle | cursor vertically centered | deterministic-sidecar-consistency, model-qwen3-vl |
| battle | name plates read fully | deterministic-sidecar-consistency, model-qwen3-vl |
| battle | hp bars on their baked tracks | deterministic-art-anchor, model-qwen3-vl |
| battle | single clean frame | model-qwen3-vl |
| battle | text inside its box | model-qwen3-vl |
| overworld | biome read as its intended terrain | model-qwen3-vl |
| overworld | props sit on their tiles | model-qwen3-vl |
| overworld | render behind tall prop canopies | model-qwen3-vl |
| overworld | tall-grass patches visibly distinct | model-qwen3-vl |
| overworld | untextured solid-color | model-qwen3-vl |
| overworld | player sprite intact | model-qwen3-vl |
| day_night | tint plausibly | model-qwen3-vl |
| day_night | hint bar | model-qwen3-vl |
| menu | uniformly dimmed | model-qwen3-vl |
| menu | panels framed and readable | model-qwen3-vl |
| menu | every row align its name | model-qwen3-vl |
| menu | hp bars visible and color-graded | model-qwen3-vl |
| menu | clipped, overlapping, or escaping | model-qwen3-vl |
| camping | glow visible around the fire | model-qwen3-vl |
| camping | recipe names + ingredient counts legible | model-qwen3-vl |
| display_matrix | every window size | model-qwen3-vl |

Consequence: the deterministic sidecar-consistency reviewer answers ONLY the two battle questions its classes mechanically implement; the HP-bar trigger question ("hp bars on their baked tracks") is ANSWERED by the art-anchor class (geometric truth — the `anchor_drift` comparison runs whenever a changed battle shot is reviewed, and the kind self-tags into the ran set even on a zero-drift tree), with the model keeping the single-slash number judgment; and the 15 judgment / non-baked-UI questions are model-only — exactly the questions an art anchor is structurally blind to (the two camping questions ride the same model-only tier: the 15-17 sidecars carry zero groundable regions). Offline (no model run), those 15 are counted UNANSWERED with reason, never faked.

### `answers[]` contract (additive `--reviewer-cmd` seam)

A `--reviewer-cmd` plugin may ANSWER rubric questions explicitly by returning `answers` alongside `findings`:

```json
{"findings": [...], "answers": [{"question_id": "q1-<hex8>", "verdict": "yes|no",
  "region_id": "anchor:battle/enemy_hp_track", "bbox": [128, 108, 192, 16],
  "note": "...", "reviewer_kind": "model-qwen3-vl"}]}
```

`_validate_answer` validates/repairs each answer (`verdict ∈ {yes, no}`, `question_id` a non-empty `q1-` id; `region_id` + `bbox` optional). A verdict-`no` answer that cites a resolvable region becomes a quarantine finding via the existing `_mk` path (reviewer_kind carried through); an answer without a resolvable region is COUNTED, never a finding; a malformed `answers` field is a TOOL ERROR (never a silent drop), and dropped invalid answers are counted in the coverage warnings. The deterministic lanes need not emit explicit answers — their coverage registers because a capable kind RAN (§ Answered predicate).
