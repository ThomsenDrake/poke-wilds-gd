Status: current
Last verified: 2026-08-17
Review cadence days: 14
Source paths: scenes/ui/FeedbackDialog.tscn, scripts/app/feedback_controller.gd, scripts/app/feedback_flow_scenario.gd, scripts/ui/feedback_dialog.gd, scripts/runtime/feedback_snapshot.gd, scripts/runtime/feedback_bundle.gd, scripts/runtime/feedback_outbox.gd, scripts/runtime/feedback_reporter.gd, scripts/core/bounded_jsonl.gd, scripts/core/feedback_redactor.gd, scripts/core/trace_logger.gd, scripts/app/ui_tree_dump_writer.gd, services/feedback-relay/src/errors.ts, services/feedback-relay/src/index.ts, services/feedback-relay/src/github.ts, services/feedback-relay/src/security.ts, services/feedback-relay/src/types.ts, services/feedback-relay/migrations/0001_initial.sql, tools/package_playtest.py, tools/fetch_feedback_report.py, tools/inspect_feedback_bundle.py, tools/test_feedback_bundle.py, export_presets.cfg

# Playtest Feedback

## Player contract

In a packaged desktop build, `F` opens a pause-modal bug report from title,
overworld, menu, or battle. If a `LineEdit` or `TextEdit` already owns keyboard
focus, `F` remains text and does not open the report. The report captures the
screen, screenshot, UI tree, in-memory save, runtime/game summaries, current-session
trace, and sanitized engine-log tail before the modal becomes visible, then presents one
1–1000 character field. Enter sends, Shift+Enter inserts a newline, and Escape or X
cancels even while the field owns focus. Submission and result display ignore further
send/cancel/reopen input. The dialog says
that the message is public while the screenshot, save, and diagnostics stay
private, using the exact disclosure text shown in the dialog.

The exact prior `SceneTree.paused` value is restored after cancel, success, or
queueing. A network/429/5xx failure leaves the ZIP and metadata in
`user://feedback_outbox`; an atomic metadata commit makes only complete ZIP/sidecar
pairs retry-visible, while malformed or incomplete prior entries are preserved out
of the retry queue. Retry runs on a bounded 30s/2m/10m/1h schedule and at
the next launch. A permanent 4xx keeps the local artifact without a retry loop.
Success deletes both outbox files and shows only the issue number. A tester
never sees raw logs, tokens, repository plumbing, or a GitHub login.

## Capture and privacy contract

The v1 ZIP contract is [feedback-report-schema.md](../references/feedback-report-schema.md).
It contains `report.json`, current-launch `trace.jsonl`, the sanitized engine-log
tail, an in-memory save snapshot, the pre-dialog visible UI tree aggregated from
every visible sibling under the common UI parent, an optional
pre-dialog screenshot, and `README.txt`. Trace capture begins at the first event
written by this process even though `agent_trace.jsonl` remains append-only
across launches. Trace and engine logs are capped at 5 MiB and 2 MiB; the bundle
is capped at 16 MiB; if compression ever exceeds the cap, reduction removes
old engine-log material first and then the middle of the trace while preserving
its beginning, newest complete records, and an explicit truncation marker.

Redaction replaces home/user-data/application paths and credential-shaped log
material. It never records an OS username, hostname, or device
identifier. Gameplay state and the in-game player name are retained because
they are necessary for reproduction and covered by the disclosure. Every
artifact named by `report.json` carries an exact byte count and SHA-256.

## Identity, relay, and issue contract

`tools/package_playtest.py` creates one package per friend and platform. The
friend never types a code: the export embeds a public-safe tester handle and a
revocable opaque invite token in generated, ignored build metadata. The relay
stores only the token hash and private nickname. The package token is treated as
extractable and is protected by revocation, cohort scoping, per-minute edge
limiting, and D1 daily limits—not as a durable secret. GitHub App and maintainer
credentials exist only as Worker secrets.

Public tester handles use the `PKMN-<SPECIES>-<SUFFIX>` scheme and are derived
only from the opaque invite token. A friend's private nickname is never an input
to the public handle and remains solely in the ignored mode-0600 registry and
the relay's private D1 invite row.

`POST /v1/reports` authorizes the invite and applies the five-per-minute
tester/token edge limit before consuming the bounded multipart body. Typed relay
errors carry their public status from the validation source, so permanent schema/ZIP
failures cannot fall into the retryable 5xx class. The relay verifies the
client hash, EOCD-declared ZIP central directory with matching local headers and CRCs,
exact entry allowlist, v1 manifest, tester identity, and full bundle/manifest agreement
before private R2 storage. Idempotent report lookup occurs before an atomic D1 daily
quota admission, so retries are never rejected solely because the quota filled later. D1
owns idempotency and the received→stored→issuing→completed lifecycle. A
conditional issuing claim plus the hidden `feedback-report-id` GitHub marker
prevents retries or crash recovery from opening a second issue.

An `issuing` report remains issuing across ambiguous GitHub/R2/D1 failures, so an
immediate retry receives in-progress rather than risking a second issue. Stale issuing
reports reconcile by searching the hidden marker before create.

The public issue contains only the sanitized player sentence, tester handle,
report/build/commit/platform/captured-screen fields, artifact expiry, and the authenticated
`tools/fetch_feedback_report.py` command. It never links raw artifacts publicly.
R2 objects expire after 180 days through the scheduled cleanup; the issue and D1
receipt remain. Relay logs contain only report/build identifiers, byte counts,
status, and issue number.

## Release and agent workflow

Production and staging infrastructure were provisioned before this port. Their
end-to-end canaries opened issues #32 and #33 and those issues were closed after
successful verification; routine source validation must not redeploy or create
replacement canary issues.

The three committed export presets are Linux x86-64, Windows x86-64, and macOS
Universal 2. Linux and Windows embed the PCK so the single reported executable
is the complete distributable; macOS exports one ZIP. The packaging command refuses dirty tracked source unless
`--allow-dirty` is deliberately supplied for local validation. It registers an
invite through the admin API, creates temporary build metadata, exports the
release, and removes the generated metadata in a `finally` block. Raw invite
tokens remain only in the ignored mode-0600 `.playtest/invites.json` and inside
their revocable packages; commands never print them.

An authorized agent reads the public issue, runs the supplied fetch command,
and starts at `report.json`. The fetcher streams through the private admin route,
checks the transport hash, safely extracts the allowlisted files into a temporary sibling
and atomically publishes them only after success, and verifies
every manifest checksum. The focused `feedback_flow` scenario drives real `F`
input with text-focus suppression from title/menu/battle/overworld and parses the
resulting ZIP through an injected transport; it never contacts the relay.
