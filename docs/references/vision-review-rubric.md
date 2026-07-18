Status: current
Last verified: 2026-07-18
Review cadence days: 21
Source paths: scripts/app/world_consistency_audit.gd, scripts/app/ui_render_audit.gd, .godot-smoke/shots

# Vision Review Rubric

After any `visual_sweep` run whose shots change, a vision-capable reviewer (human
or agent) reads every shot and answers each question for its state group. Any
"no" is a finding: record it in `.godot-smoke/vision-review.json` as
`{"shot": String, "findings": [{"class": String, "region": [x,y,w,h], "severity": "low|medium|high", "confidence": "low|medium|high", "note": String}]}`.
Findings are quarantine-tier: reported, never failing, unless a coded oracle
confirms the same defect.

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

## Display-matrix states (`matrix/<w>x<h>_battle.png`)

- At EVERY window size: is the text pixel-crisp (uniform stroke widths, no
  shimmering/uneven glyph columns), the surface centered with even margins,
  and nothing clipped at the surface edges?
