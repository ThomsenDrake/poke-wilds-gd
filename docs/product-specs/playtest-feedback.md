Status: current
Last verified: 2026-09-11
Review cadence days: 14
Source paths: .github/workflows/feedback-relay-deploy.yml, .github/workflows/playtest-release.yml, .github/workflows/enqueue-playtest-feedback.yml, scenes/ui/FeedbackDialog.tscn, scripts/app/feedback_controller.gd, scripts/app/feedback_flow_scenario.gd, scripts/app/feedback_flow_resilience_checks.gd, scripts/app/trace_cursor_checks.gd, scripts/app/feedback_flow_legacy_checks.gd, scripts/app/feedback_flow_stamp_checks.gd, scripts/app/display_matrix.gd, scripts/ui/feedback_dialog.gd, scripts/runtime/performance_monitors.gd, scripts/runtime/feedback_snapshot.gd, scripts/runtime/feedback_bundle.gd, scripts/runtime/feedback_outbox.gd, scripts/runtime/feedback_reporter.gd, scripts/core/bounded_jsonl.gd, scripts/core/feedback_redactor.gd, scripts/core/trace_logger.gd, scripts/app/ui_tree_dump_writer.gd, services/feedback-relay/src/errors.ts, services/feedback-relay/src/report_access.ts, services/feedback-relay/src/index.ts, services/feedback-relay/src/github.ts, services/feedback-relay/src/security.ts, services/feedback-relay/src/types.ts, services/feedback-relay/migrations/0001_initial.sql, services/feedback-relay/wrangler.jsonc, tools/feedback_endpoint.py, tools/package_playtest.py, tools/fetch_feedback_report.py, tools/inspect_feedback_bundle.py, tools/test_feedback_bundle.py, tools/play_agent_loop.py, tools/play_agent_findings.py, scripts/app/play_agent_loop_file.gd, docs/references/agent-step-bridge.md, export_presets.cfg, scripts/runtime/update_identity.gd, services/feedback-relay/src/updates.ts, services/feedback-relay/test/routes.test.ts, tools/publish_update.py

# Playtest Feedback

## Player contract

In every packaged alpha desktop build, `F` opens a pause-modal bug report from title,
overworld, menu (including storage, camp, and waystone), or battle. Public and shared
alpha stamps include `feedback_mode: "public"` and an HTTPS `feedback_endpoint`.
They need no friend invitation, invite token, or GitHub login. The separate feedback
endpoint does not enable the updater in a public build. A genuinely unconfigured
bare editor/export stamp remains silent; a partially configured invited stamp opens
but returns `feedback_not_configured` before writing an outbox entry. If a `LineEdit` or `TextEdit` already owns keyboard
focus, `F` remains text and does not open the report. The report captures the
screen, screenshot, UI tree, in-memory save, runtime/game summaries, current-session
trace, and sanitized engine-log tail before the modal becomes visible, then presents one
1–1000 character field. Enter sends, Shift+Enter inserts a newline, and Escape
cancels. X is ordinary text, including while the field owns focus. Submission ignores
further send/cancel/reopen input. Results stay visible until Enter or Escape dismisses
them, and that acknowledgement must not leak into gameplay input. The dialog says
that the message is public while the screenshot, save, and diagnostics stay
private, using the exact disclosure text shown in the dialog.

The exact prior `SceneTree.paused` value is restored after cancel, success, or
queueing. A network/429/5xx failure leaves the ZIP, public metadata, and a local-only
private route in `user://feedback_outbox`; the route retains that report's original
endpoint, feedback mode, and any legacy invite across a later package change and is never uploaded. An atomic metadata
commit makes only complete ZIP/route/metadata sets retry-visible, while malformed or
incomplete prior entries are preserved out of the retry queue and their orphaned route
is removed. The relay counts the same Unicode code points as the Godot field, so up to
1,000 astral characters remain valid. Network/408/429/5xx failures retry on a bounded
30s/2m/10m/1h schedule and at
the next launch. Direct submissions and retries serialize access to the shared
transport; after each upload owner finishes, a fresh outbox scan stops the timer only
when no retryable entry remains. Sidecar writes must complete and flush before their
atomic rename can publish the commit marker. A permanent 4xx keeps the local artifact without a retry loop and
reports that retained copy to the player. Bundle-build or outbox-commit failure returns
`unsaved` and instead says the report could not be saved; it never claims a local artifact.
Missing or invalid embedded relay configuration is refused before bundle creation or
outbox commit, so a non-personalized export cannot create a permanently unsendable
private route; a legacy malformed route is terminally blocked rather than retried forever.
Runtime parsing requires a nonempty DNS/IP host and an optional numeric port in the
1–65535 range, matching the package-time boundary for malformed authorities.
Runtime uploads reject redirects, send an explicit application User-Agent, and attach
Authorization only for legacy invited routes. Safe bounded relay error identifiers
remain available for diagnosis; raw response bodies are never shown or logged.
Bundle creation checks the result of each ZIP entry write, entry close, and final archive
close before the outbox can commit it. The stable install ID must be exactly 32 lowercase
hexadecimal characters; a missing or malformed persisted value is regenerated into a
same-directory temporary file and atomically renamed into place before bundle creation.
Success deletes all three outbox files and shows only the issue number. A tester
never sees raw logs, tokens, repository plumbing, or a GitHub login.
Before success is announced, the outbox atomically changes its metadata commit marker
to terminal `sent`, then checks private-route, ZIP, and metadata deletion in that order.
A deletion failure quarantines the retained files and returns a local cleanup failure;
the terminal marker or quarantine prevents a subsequent launch from uploading again.
The player sees that the numbered remote issue succeeded while local cleanup needs
attention, rather than the normal success copy or the local-only blocked copy.

## Capture and privacy contract

The v1 ZIP contract is [feedback-report-schema.md](../references/feedback-report-schema.md).
It contains `report.json`, current-launch `trace.jsonl`, the sanitized engine-log
tail, an in-memory save snapshot, the pre-dialog visible UI tree aggregated from
every visible sibling under the common UI parent, an optional
pre-dialog screenshot, and `README.txt`. Trace capture begins at the first event
written by this process even though `agent_trace.jsonl` remains append-only
across launches. Trace and engine logs are capped at 5 MiB and 2 MiB; the bundle
is capped at 16 MiB compressed and 24 MiB across uncompressed entries; if either cap
is exceeded, reduction removes old engine-log material first and then the middle of
the trace while preserving its beginning, newest complete records, and an explicit
truncation marker. If irreducible save/UI/screenshot data still exceeds either cap,
bundle creation fails locally instead of committing an artifact the relay will reject.

Redaction replaces home/user-data/application paths, semantically labeled machine
identity fields, and credential-shaped log material. It never performs unbounded
replacement of raw environment values, so short/common usernames cannot corrupt
ordinary report text. It never records an OS username, hostname, or device
identifier. Gameplay state and the in-game player name are retained because
they are necessary for reproduction and covered by the disclosure. Every
artifact named by `report.json` carries an exact byte count and SHA-256. The private
route is neither an artifact nor upload metadata and never enters the ZIP, trace, or log.

## Identity, relay, and issue contract

Public alpha feedback uses the fixed anonymous tester label `PUBLIC-ALPHA` and the
existing random per-install ID. It resolves its feedback endpoint directly from the
current build stamp, before any persisted friend identity is considered. An old
`user://playtest_identity.json` cannot redirect a new alpha report or reintroduce an
invite requirement. Public and shared alpha publishers do not register invites.

Requests without Authorization use anonymous admission for the `public` and `playtest`
channels. A hashed client-address limiter runs before body parsing; existing per-install
and per-channel daily quotas still apply. Client metadata is untrusted and does not
prove possession of an official build. Any supplied Authorization uses strict legacy
invite validation; an invalid/revoked credential never falls back to anonymous access.
GitHub App and maintainer credentials exist only as Worker secrets.

Previously distributed friend packages and queued reports remain compatible. Their
private route retains its original endpoint/invite, and no repair silently resends a
blocked report. A route-less legacy ZIP/metadata pair can use a saved identity only
when its tester and channel match; an explicit private route always wins. The optional legacy `tools/package_playtest.py` still creates revocable
personalized packages; it is not required for alpha feedback. Legacy identity/update
behavior remains described in [game-update.md](game-update.md).
The relay endpoint must be HTTPS without embedded credentials, a query, a fragment, or
an empty/malformed explicit port;
one shared validator runs before both the admin invite request and the maintainer bundle
fetch, the game revalidates the embedded route at its HTTP sink, and the normalized
endpoint is the one embedded into the package. A cross-platform advisory lock covers
the shared `generated/playtest_build.json` write/export/delete sequence, so a concurrent invocation
refuses without overwriting or deleting the active export's tester metadata.

Legacy invited tester handles use the `PKMN-<SPECIES>-<SUFFIX>` scheme and are derived
only from the opaque invite token. A friend's private nickname is never an input
to the public handle and remains solely in the ignored mode-0600 registry and
the relay's private D1 invite row.

`POST /v1/reports` applies the five-per-minute hashed-client edge limit for
anonymous alpha reports, or strict invite authorization and the existing tester/token
limit for legacy reports, before consuming the bounded multipart body. Typed relay
errors carry their public status from the validation source, so permanent schema/ZIP
failures cannot fall into the retryable 5xx class. The relay verifies the
client hash, EOCD-declared ZIP central directory with matching local headers and CRCs,
exact entry allowlist, v1 manifest, tester identity, and full bundle/manifest agreement
before private R2 storage. Idempotent report lookup occurs before an atomic D1 daily
quota admission, so retries are never rejected solely because the quota filled later. D1
owns idempotency and the received→uploading→stored→issuing→completed lifecycle. The
uploading lease and cleanup's atomic `expiring` claim are mutually exclusive D1
transitions; interrupted/stale leases are recoverable, and cleanup never deletes R2
before it owns the row. A
conditional issuing claim plus the hidden `feedback-report-id` GitHub marker
prevents retries or crash recovery from opening a second issue.
An `expiring` or `expired` receipt is terminal: a matching late retry receives HTTP
410 before R2 or GitHub work, and admin download refuses the bundle as soon as cleanup
owns the row, so cleanup cannot be undone by a retained local bundle.

An `issuing` report remains issuing across ambiguous GitHub/R2/D1 failures, so an
immediate retry receives in-progress rather than risking a second issue. Stale issuing
reports reconcile by searching the hidden marker before create.

The public issue contains only the sanitized player sentence, tester handle,
report/build/commit/platform/captured-screen fields, artifact expiry, and the authenticated
`tools/fetch_feedback_report.py` command. It never links raw artifacts publicly.
Every untrusted display field is HTML-encoded and Markdown-escaped before issue
composition, so player comments, headings, fences, or table separators cannot hide or
restructure the fixed agent handoff.
R2 objects expire after 180 days through the scheduled cleanup; the issue and D1
receipt remain. Each daily invocation atomically claims deterministic 100-row pages in
D1 before bulk-deleting R2 and marking the claim expired, up to 1,000 objects, and emits aggregate-only cap telemetry if a
full tenth page suggests more work. The provisioned R2 lifecycle is the authoritative
backstop if future global intake ever exceeds that bounded daily capacity. Relay logs
contain only report/build identifiers, byte counts, status, and issue number.

## Release and agent workflow

The relay is deployed as repository-owned infrastructure. Pull requests changing
`services/feedback-relay/**` must pass the Worker lockfile install, checks, and
production/staging Wrangler dry-runs without deployment credentials. The merge to
`main` applies migrations and deploys staging first; a typed `/healthz` check must
pass before the workflow can apply production migrations or deploy production.
The two GitHub deployment environments hold only a least-privilege Cloudflare CI
token and account ID. Runtime GitHub App, admin, and invite secrets stay solely in
Cloudflare and never enter GitHub Actions.

Production and staging infrastructure were provisioned before this port. Their
end-to-end canaries opened issues #32 and #33 and those issues were closed after
successful verification; routine source validation must not redeploy or create
replacement canary issues.

A labeled `playtest-feedback` issue starts the maintainer Cursor Automation
through `.github/workflows/enqueue-playtest-feedback.yml`. That workflow POSTs
only `issue_url`, number, and title; the webhook auth key is the
`CURSOR_AUTOMATION_API_KEY` GitHub Actions secret and never the relay admin
token. The agent fetches the private bundle with
`tools/fetch_feedback_report.py` after it starts. Closed canaries and
`feedback_not_configured` reports are not a reason to rerun this enqueue.

### Maintainer: distribute an alpha build

Use the release publisher on a green, committed SHA. Godot's bare Export Project does
not create the build stamp. Both public `v*` releases and shared `playtest-*` releases
embed public feedback configuration and produce one file per desktop OS. An alpha
player needs no personalized package or code. Confirm that a release job actually
exported rather than only reporting `already_published=true`.

`public-release` uses `publish_update.py --channel public --embed-public`; its updater
endpoint stays empty. The public feedback endpoint defaults to the production relay
and may be supplied with `--feedback-endpoint` / `ALPHA_FEEDBACK_ENDPOINT`. It contains
no secret and requires no Cloudflare credential for export. Public exports also verify
the deployed production feedback relay revision before building artifacts. Shared `playtest-release`
publishes the update artifacts through R2 and waits for production relay readiness,
without consuming or registering a cohort invite. Publisher administration still
requires server-side publish credentials; these never enter a public build.

Distribute the Windows `.exe`, Linux `.x86_64`, or macOS `.zip` from the matching release
receipt. `--allow-dirty` is only for local validation. Commit every `.gd.uid` sidecar so
Godot import does not make the release checkout dirty. Legacy personalized exports
remain supported by `tools/package_playtest.py --friend ... --target ...`, but do not
use that workflow to onboard ordinary alpha players.

A successful local smoke run is not Windows runtime certification. Validate a Windows
artifact on Windows and confirm its issue number against the GitHub issue and D1
receipt. Live test submissions must be explicitly authorized; unit/smoke tests use
injected transports and never publish fabricated player reports.

The three committed export presets are Linux x86-64, Windows x86-64, and macOS
Universal 2. Linux and Windows embed the PCK so the single reported executable
is the complete distributable; macOS exports one ZIP. The packaging command refuses
tracked or untracked worktree changes unless
`--allow-dirty` is deliberately supplied for local validation. The legacy personalized command registers an
invite through the admin API; all publishers create temporary build metadata, export
the release, and remove the generated metadata in a lock-owned `finally` block. Raw invite
tokens remain only in the ignored mode-0600 `.playtest/invites.json` and inside
their revocable packages; commands never print them. Private/generated/output paths
remain excluded through `.gitignore`, while an untracked exportable resource blocks
distribution so the embedded commit SHA describes every packaged input. The admin
registration request rejects redirects rather than forwarding its credential to a
different origin or downgraded transport.

An authorized agent reads the public issue, runs the supplied fetch command,
and starts at `report.json`. The fetcher refuses an unsafe endpoint before constructing
the admin-authenticated request and rejects redirects before any credential-bearing
follow-up, then streams through the private admin route,
checks the transport hash, safely extracts the allowlisted files into a temporary sibling
and atomically publishes them only after success, and verifies
every manifest checksum. The focused `feedback_flow` scenario drives real `F`
input with text-focus suppression from title/menu/storage/camp/waystone/battle/overworld,
asserts the capture label for every surface, and parses the resulting ZIP through an
injected transport; it never contacts the relay. `display_matrix` opens the report at
all six supported window sizes, including 438x383, and asserts the panel and editor stay
inside the viewport before continuing its battle-pixel checks.
One retry pass also leaves an unavailable old route queued while sending a later
independently routed report, so cross-package outbox entries cannot starve each other.
The injected scenario transport leaves reports from prior runs queued and untouched;
only report IDs created by the current journey affect its counters or assertions.
The journey also submits from an unconfigured synthetic build and proves no transport,
ZIP, metadata marker, or private route is created.
Both trace-reduction stages preserve the canonical runtime record shape: their
`feedback_trace_truncated` marker carries `event`, numeric boot-clock `ts_msec`,
`source`, and `payload`. The focused journey forces and parses both marker producers.
When the bounded engine-log tail begins mid-line, capture advances past that partial
line before UTF-8 decoding and redaction. This prevents a tail boundary from retaining
a sensitive suffix after discarding the label that would have triggered redaction.

`feedback_flow` also runs isolated trace-cursor fixtures: prior history with empty
lines and UTF-8, append, uncapped sessions larger than the feedback slice, earlier
absolute cursors, and observed log reset. These checks preserve exact oracle event
coverage while the separately bounded feedback ZIP keeps its existing limits.
The fixture never truncates or deletes the player's trace log.

## Agent-play closed loop (optional)

`play_agent_loop` is an optional windowed driver, not a change to human F.
The default explorer stays in the overworld long enough to attempt harvest
(`Z` / `action_a`), build (`C` / `build_toggle`, then `Z` to place), and a
contact battle (overworld mons are live for this scenario). After that it
plays through the same capture/dialog/relay path: real `feedback_report`
input, a 1–1000 character public sentence that starts with `[agent-play]`,
Enter to send. Default runs inject a mock transport. Live production POST
requires `PLAY_AGENT_LIVE_FILE=1` plus a public stamp. Novelty is checked
before F so a repeat signature does not open a second dialog. The dedicated
install-id path is `user://feedback-agent-play-install-id.txt`. Windowed runs
also write `.godot-smoke/play_agent_loop.mp4` (ffmpeg of the live window). That
recording is operator evidence, not part of the public F ZIP or GitHub issue.
`--no-video` skips it. Human focus, pause, disclosure, and acknowledgement
behavior are unchanged. Contract:
[../references/agent-step-bridge.md](../references/agent-step-bridge.md).
