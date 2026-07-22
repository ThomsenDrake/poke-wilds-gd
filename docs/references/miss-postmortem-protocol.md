Status: current
Last verified: 2026-07-22
Review cadence days: 30
Source paths: tools/graduation_ledger.py, tools/check_repo_contracts.py, docs/references/vision-review-rubric.md, docs/registry/art-anchors.toml, docs/product-specs/vision-fidelity.md, docs/generated/miss-postmortems.json

# Miss-Postmortem Protocol

> **Governing directive (verbatim intent):** When the playtest suite misses a bug, fix the REASON it was missed at a SYSTEMIC level — never the specific miss. The deliverable is a new check CLASS; the instance is the specimen.

This protocol is that directive made mechanical. Every escaped defect triggers a structured postmortem whose output is a class-level mechanism (a new anchor class, reviewer class, rubric answerer, or gate) that fixes the instance AS A SIDE EFFECT of closing the whole class — plus a recorded, byte-reverted class-level plant proving the class is closed. Postmortems are tracked in the ledger `docs/generated/miss-postmortems.json` (schema `miss-postmortem/1`), a sibling of `docs/generated/graduation-ledger.json`; a `check_repo_contracts` backstop cross-checks the ledger in BOTH directions so a claimed-but-missing mechanism or an un-reverted plant is RED, not prose.

The protocol exists because the HP-bar 11 stage-px escape (entry #1 in the ledger) proved that a suite can be fully green and fully self-consistent and still ship a misalignment: every automated check class returned the correct answer to the question it was built to answer ("did anything change?" / "does the render match the model?"), and none was built to answer "does the overlay sit on the art feature it belongs on?". The fix is not an HP-bar test; it is the source-art anchor class ([vision-fidelity.md](../product-specs/vision-fidelity.md) § Source-art anchor registry) plus this protocol, which binds every FUTURE miss to a class-level mechanism.

## Anchor-class taxonomy

Every check class is classified by what its truth is ANCHORED to. A postmortem names the missing anchor class so the gap is structural, not incidental:

| Code | Anchor kind | Truth is… | Examples |
| --- | --- | --- | --- |
| `CO` | code-output-anchored | the code's own earlier output / render | pixel baselines, sidecar-diff, determinism pins, display-matrix round-trip, the deterministic sidecar-consistency reviewer |
| `HM` | hand-model-anchored | rects a human measured and transcribed | `ui_render_model`/`ui_render_art` geometry, visual_lint regions |
| `SA` | source-art-anchored | derived from `res://pokewilds/**` bytes at check time | world tiles (Lane 1); **the art-anchor registry (this slice)** |
| `XS` | external-standard-anchored | an independent published spec | WCAG contrast, Machado-2009 CVD |
| `EA` | external-agent-anchored | a reviewer answering rubric questions | the Lane-4 `--reviewer-cmd` socket (populated this slice by Qwen3-VL) |

An escaped defect means the class that COULD have seen it was either absent or anchored to the wrong thing. The 11px HP-bar miss was an `SA` gap: programmatic-on-baked elements had no source-art anchor (`G1`), and the rubric question that would have caught it had no answering agent (`G2`, an `EA` gap).

## Required steps

1. **INSTANCE (subject, not deliverable).** Fix and freeze the concrete defect, recording `head_sha`, the perturbation, and which shots/baselines were affected. The instance is the specimen the class mechanism is derived from — never the deliverable. (For entry #1: `scenes/ui/BattleView.tscn` `EnemyHPBar` offset_left 43→32, `PlayerHPBar` 107→96, plus the four regenerated battle baselines 09-12.)

2. **NAME THE MISSING ANCHOR CLASS.** Classify the miss against the taxonomy above, then ENUMERATE every existing check class that was present and WHY each was silent, in the [vision-review-rubric.md](../references/vision-review-rubric.md) validation-plant `(a)`-`(i)` table format. This enumeration is the proof of the taxonomy: for the HP-bar trigger every class — pixel baseline (the wrong render WAS the baseline), region diff (no clusters vs its own baseline), sidecar-consistency reviewer (draw_order delta checks z/y_sort/presence, never rects), `ui_render_model`/`ui_render_art` (bars never modeled), `text_oracle` (HP numbers are not ANCHOR strings), `layout_audit` (name/level overlap only), contrast/CVD (rects/palettes unchanged), `display_matrix` (self-consistent at every window), rubric line 63 (asked, answered by no agent) — was silent AND correct for the question it was built to answer.

3. **MECHANISM.** Add the class-level mechanism (registry entry + derivation + check, or a reviewer class, or a rubric answerer) such that the instance is fixed BY the mechanism, not beside it. The ledger entry's `mechanism_added` MUST name the landed artifact (a registry entry, a reviewer class, a ledger flip) — a `check_repo_contracts` backstop resolves it to a real check in the tree.

4. **PLANT — a class-level regression, not an instance test.** Perturb the instance's KIND (HP-bar offset ±11px; delete the anchor; mutate the art) and prove (i) the new mechanism fires and (ii) every class enumerated silent in step 2 STAYS silent at its recorded tier (validating the taxonomy — quarantine-tier corroboration on the planted break is EXPECTED and recorded, the escape is defined by the frozen-baseline state), then revert BYTE-IDENTICAL (`git diff` empty as proof) and record `revert_scope` — sha256 pins of the scope files taken at the revert, which the backstop holds mechanically from then on. Plants are recorded as PROOF and EXCLUDED from organic statistics (the `graduation_ledger.py` `exit4_proof` pattern).

5. **RECORD.** Append the entry to `docs/generated/miss-postmortems.json` (schema below). The ledger is TRACKED canonical JSON; counts are COMPUTED from entries (misses-closed-by-new-anchor-class, recurring-class-misses), never narrated.

## Ledger schema (`miss-postmortem/1`)

```json
{
  "schema": "miss-postmortem/1",
  "entries": [
    {
      "id": "miss-001-hp-bar-11px",
      "date": "2026-07-22",
      "head_sha": "<the HEAD the fix sits on>",
      "instance": {"description": "...", "shots": ["..."], "perturbation": "..."},
      "missing_anchor_class": "SA",
      "classes_silent": [{"class": "...", "anchor_kind": "CO|HM|SA|XS|EA", "why_silent": "..."}],
      "mechanism_added": "<must resolve to a real landed check>",
      "plant": {
        "perturbation": "...",
        "executed": true,
        "mechanism_caught": true,
        "classes_silent_confirmed": true,
        "revert_proof": "git diff empty",
        "revert_scope": {"<repo-relative scope file>": "<sha256 at the byte-identical revert>"}
      },
      "plants_recorded_but_excluded_from_stats": true
    }
  ]
}
```

## Enforcement (mechanical, not prose)

- **Refuse-on-unreadable.** Like `graduation_ledger.py`'s `LedgerUnreadable`, the ledger is never clobbered by a fresh empty one: a present-but-corrupt ledger is a hard error, not a reset. Tracked evidence survives.
- **Both-directions backstop** (`check_repo_contracts.miss_postmortem_issues`, folded into `run()`): every recorded `mechanism_added` MUST resolve to a landed check in the tree — each repo-relative path it names must exist and each named art-anchor id must be in [art-anchors.toml](../registry/art-anchors.toml) (a claimed-but-missing mechanism is RED); and every executed plant's `revert_proof` MUST hold — the plant records `revert_scope` (path→sha256 pins taken AT the byte-identical revert) and a drifted or missing scope file is RED, like a broken internal link. The pins are position-independent, so the check holds mid-slice (uncommitted) exactly as post-commit — a live `git status` would false-red on unrelated in-flight edits to the scope files, so the durable proof is the recorded pins, not the live diff. An entry MISSING its plant, its silence-enumeration, or (when executed) its `revert_scope` is advisory "incomplete" on stderr (never a wave of false reds), matching the house's progressive-arming style; an unreadable ledger is RED (refuse-on-unreadable), never reset to empty.
- **Tier map.** Protocol/process is WARN; a claimed-but-missing mechanism or an un-reverted plant is RED.
- **Ritual, never a runner post-step.** The ledger is written by a deliberate human/agent ritual, NOT mutated on every run — mutating a committed artifact per run creates git noise and accidental-commit hazards (the explicit rationale in `graduation_ledger.py`'s module docstring for keeping `record` off the runner).

## Relationship to the other lanes

The protocol consumes the same machinery the systemic fix adds: source-art anchors ([art-anchors.toml](../registry/art-anchors.toml)) are the `SA` mechanism class; the populated Qwen3-VL reviewer answers the `EA` rubric questions; the rubric-coverage ledger counts "unanswered" honestly so an `EA` gap is visible before it escapes; and the baseline-regeneration refusal gate keeps a wrong baseline from ever being frozen green again (the exact hole that held the 11px defect for 3+ days). Entry #1's step-4 plant is the living proof the escape class is closed. See [vision-fidelity.md](../product-specs/vision-fidelity.md) § Source-art anchor registry and [RELIABILITY.md](../RELIABILITY.md) § Source-art anchors.
