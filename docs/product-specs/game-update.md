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
and relaunches. Hash mismatch, a missing pending file, or an unwritable
install/user dir refuses apply, leaves the old binary in place, and shows a
MessageBox. The updater never writes `user://godot_port_save.json*`.

Saves stay in Godot `user://` for `config/name="PokeWilds-Godot"`. Replacing
the executable does not touch that path. The application name and macOS
`application/bundle_identifier="com.drakethomsen.pokewildsgodot"` stay pinned;
changing either forks `user://` and looks like a lost save. Schema migration
stays on the existing load path. The updater never downgrades: comparison is
monotonic `published_at` then `build_id`.

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
with disk identity.

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

OS key comes from `OS.get_name()` (`Linux`/`Windows`/`macOS`). Unknown OS: no
`UPDATE` row. Artifacts live under R2 `updates/<channel>/<build_id>/<os>`.
Publish uploads via the R2 S3 API / wrangler, never a Worker POST. The game
trusts only the manifest SHA-256. `PUT /v1/admin/updates` writes the latest
pointer only after all three object checksums exist.

## Apply

`scripts/runtime/update_applier.gd` is the only OS-specific player code.

- Windows: rename the running `.exe` to `.old`, write the new file, relaunch,
  delete `.old` on the next successful boot.
- Linux: unlink the running binary, write the new file, `chmod 0755`, relaunch.
- macOS: unzip the new `.app` to a sibling `*.new`, swap with the live bundle,
  relaunch. Unsigned Gatekeeper "Open" stays a documented one-time step;
  codesign/notarization stay 0.

## Smoke validation

`update_flow` drives the title `UPDATE` row through an injected transport (no
network). It covers no-update default entries, update-available first row,
confirm/cancel, hash-mismatch refuse, scenario/editor check skip, and identity
persist across a fake new `build.json`. Default title fixtures stay
`CONTINUE` / `NEW GAME` so existing title baselines do not churn.

## Traces

`update_check_started`, `update_available`, `update_verified`,
`update_apply_started`, `update_apply_refused`, `update_relaunching`,
`update_flow_passed`, `update_flow_failed`.
