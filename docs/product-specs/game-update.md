Status: current
Last verified: 2026-08-19
Review cadence days: 14
Source paths: scripts/domain/update_manifest.gd, scripts/runtime/update_identity.gd, scripts/runtime/update_applier.gd, scripts/runtime/update_runtime.gd, scripts/ui/title_update.gd, scripts/ui/title_screen.gd, scripts/app/update_flow_scenario.gd, scripts/app/update_flow_checks.gd, scripts/app/qa_scenarios.gd, scripts/runtime/feedback_bundle.gd, tools/update_manifest.py, tools/update_apply.py, tools/publish_update.py, tools/test_publish_update.py, services/feedback-relay/src/updates.ts, services/feedback-relay/src/index.ts, services/feedback-relay/test/routes.test.ts, export_presets.cfg, project.godot

# Game Update

## Player contract

A packaged desktop build checks a **shared** latest channel (not a per-friend
binary) on player boot. Scenario/editor boots skip the network check so the
gated suite stays byte-identical. Check failure is silent: the title still
shows `CONTINUE` / `NEW GAME`.

When a newer shared build exists for this OS, the title list gains `UPDATE` as
the first row. `Z` opens a MessageBox confirm
("Download and install the latest build? Your save stays on this computer.").
`X` cancels and stays on the title. Confirm downloads that OS's artifact into
`user://updates/`, verifies SHA-256, stages a pending apply, swaps the install,
and relaunches. The title keeps a held "Downloading update…" toast for the
whole apply (it does not auto-hide at 30s) and only then shows success hide
or the fail banner. Hash mismatch, a missing pending file, or an unwritable
install/user dir refuses apply, leaves the old binary in place, and shows a
MessageBox. A successful apply deletes `user://updates/pending.json` and the
downloaded artifact (keeping `applied.json`) so later builds cannot pile up
under unique filenames. The updater never writes `user://godot_port_save.json*`.

Saves stay in Godot `user://` for `config/name="PokeWilds-Godot"`. Replacing
the executable does not touch that path. The application name and macOS
`application/bundle_identifier="com.drakethomsen.pokewildsgodot"` stay pinned;
changing either forks `user://` and looks like a lost save. Schema migration
stays on the existing load path. The updater never downgrades: comparison is
monotonic `published_at` then `build_id`. A running build with a `build_id` but
no resolvable timestamp (embedded `published_at` or a compact UTC tail on the
`build_id`) is not treated as older. Friend packages embed `published_at` so
they can still move forward to a newer shared latest.

First install stays one file per OS (Linux `.x86_64`, Windows `.exe`, macOS
`.zip` → `.app`; PCK remains embedded). v1 is a full artifact replace.

## Shared channel

Publish writes **one artifact per OS** with public build metadata only:
`channel`, `build_id`, `commit_sha`, `version`, `endpoint`, `published_at`.
No per-friend `invite_token` rides the update binary. Friend-specific
`tools/package_playtest.py` stays optional first-contact packaging and is not
on the update path.

Feedback identity is sticky in `user://playtest_identity.json`. A friend
package copies `tester_id` / `invite_token` / `endpoint` / `channel` on first
run (atomic temp+rename). After a shared update, `load_build_info()` prefers
that persisted route for new `F` reports; the new embedded `playtest_build.json`
supplies version/commit/build_id. Shared builds may embed a cohort invite so a
player who never had a friend package can still report. Persisted friend
identity wins when present. Editor smoke build-info overrides are not merged
with disk identity. The latest check always queries the shared `playtest`
channel and the **embedded** relay `endpoint`; the persisted friend `channel`
and `endpoint` are only for `F` reports.

## Manifest

`GET /v1/updates/latest?channel=playtest` (HTTPS, no auth, no redirects) returns:

```json
{
  "schema_version": 1,
  "channel": "playtest",
  "published_at": "2026-08-19T18:00:00Z",
  "build_id": "playtest-<sha10>-<utc>",
  "commit_sha": "<40 hex>",
  "min_save_version": 6,
  "builds": {
    "linux":   {"url": "https://…", "sha256": "…", "bytes": 1, "filename": "PokeWilds-…-linux.x86_64"},
    "windows": {"url": "https://…", "sha256": "…", "bytes": 1, "filename": "PokeWilds-…-windows.exe"},
    "macos":   {"url": "https://…", "sha256": "…", "bytes": 1, "filename": "PokeWilds-…-macos.zip"}
  }
}
```

OS key comes from `OS.get_name()` (`Linux`/`Windows`/`macOS`). The title
offers `UPDATE` only when `is_newer` is true **and** that OS has a non-empty
manifest build (`is_offerable`). Unknown OS: no `UPDATE` row. Artifacts live
under R2 `updates/<channel>/<build_id>/<os>`.
Publish uploads via the R2 S3 API / wrangler, never a Worker POST. Wrangler
`r2 object put` uses `{bucket}/{object_key}` from the REPORTS binding
(`poke-wilds-feedback-private`, or `PLAYTEST_UPDATE_R2_BUCKET`) under the
`updates/` prefix only. A staging relay host, `--wrangler-env staging`, or
`PLAYTEST_UPDATE_WRANGLER_ENV=staging` selects
`poke-wilds-feedback-private-staging`. An explicit production env with a
staging endpoint is refused. The public download URL is the prefix-restricted
Worker route `GET /v1/updates/artifacts/<channel>/<build_id>/<os>` (or
`PLAYTEST_UPDATE_PUBLIC_BASE/<channel>/<build_id>/<os>`), never an R2 public
domain on the reports bucket. Report ZIPs stay admin-only. The game
trusts only the manifest SHA-256. `PUT /v1/admin/updates` writes the latest
pointer only after all three object checksums exist.

## Apply

`scripts/runtime/update_applier.gd` is the only OS-specific player code.

- Windows: copy the verified artifact to a sibling `*.new` and write
  `PokeWilds-update.cmd`. The game launches that helper and quits; the helper
  waits for the PID to exit, then moves the live `.exe` to `.old`, promotes
  `*.new`, and starts the new binary. If promotion fails, the helper restores
  `.old` before launch. `applied.json` is not written for a deferred Windows
  apply, so a rolled-back install can still be offered UPDATE. If the helper
  process cannot start (`create_process` returns a negative PID), the game
  refuses, stays open, and shows the update-failed banner. Next boot
  deletes `.old`. The running image is never renamed in-process.
- Linux: copy and `chmod 0755` the verified artifact to a sibling `*.new`,
  then promote it over the live path. A failed `chmod` refuses before the
  live path is renamed. If promotion fails, the previous binary is restored
  from `.old`. The live path is not removed until the staged file is ready.
- macOS: unzip the new `.app` to a sibling `*.new`, swap with the live bundle,
  relaunch. Unsigned Gatekeeper "Open" stays a documented one-time step;
  codesign/notarization stay 0.

## Smoke validation

`update_flow` drives the title `UPDATE` row through an injected transport (no
network). It covers no-update default entries, update-available first row,
confirm/cancel, hash-mismatch refuse, scenario/editor check skip, identity
persist across a fake new `build.json`, and no UPDATE offer on an unknown OS.
Default title fixtures stay `CONTINUE` / `NEW GAME` so existing title
baselines do not churn.

## Traces

`update_check_started`, `update_available`, `update_verified`,
`update_apply_started`, `update_apply_refused`, `update_relaunching`,
`update_flow_passed`, `update_flow_failed`.
