Status: current
Last verified: 2026-08-16
Review cadence days: 14
Source paths: scripts/runtime/feedback_bundle.gd, scripts/core/feedback_redactor.gd, services/feedback-relay/src/security.ts, tools/inspect_feedback_bundle.py, tools/test_feedback_bundle.py

# Feedback Report Schema

Bundle v1 is a ZIP with this exact entry allowlist:

| Entry | Required | Meaning |
| --- | --- | --- |
| `report.json` | yes | Canonical entrypoint and artifact checksums. |
| `trace.jsonl` | yes | Current process only; explicit gap record if truncated. |
| `engine.log` | yes | Sanitized newest 2 MiB of the release log. |
| `save.json` | yes | Read-only in-memory save payload at capture time. |
| `ui-tree.json` | yes | Visible pre-dialog Control-tree snapshot. |
| `screenshot.png` | no | Pre-dialog root viewport; omitted when unavailable. |
| `README.txt` | yes | One-paragraph agent handoff. |

`report.json` is a JSON object with `schema_version: 1`, `report_id` (UUID text),
`created_at_utc`, `message`, `tester_id`, `install_id`, `build`, `runtime`,
`game`, `capture`, and `artifacts`. `artifacts` excludes `report.json` to avoid a
self-hash and contains `{path, bytes, sha256, truncated}` for every other entry.
`build` contains only version/SHA/build/channel—never endpoint or invite token.

`POST /v1/reports` metadata repeats the private manifest identity/capture fields, including
`capture.screen` and `capture.screenshot_available`, and adds
`bundle_sha256`/`bundle_bytes`. The relay requires schema, report UUID, message,
tester/install IDs, build, runtime, game, and capture values inside the ZIP to agree with this
envelope. Maximums are 64 KiB metadata,
16 MiB compressed ZIP, 24 MiB total uncompressed entries, and seven entries.

Agents must reject duplicate or unexpected paths, nested paths, traversal segments,
symlink-prone entries, compressed input above 16 MiB, unsupported ZIP methods, central/local
or computed CRC mismatch, checksum mismatch, unsupported schema, or envelope/manifest
disagreement. `capture.screenshot_available` must exactly match `screenshot.png` presence
and `capture.screen` must equal `game.current_screen`. Extraction requires a new empty destination and atomically publishes only a
fully written temporary sibling tree.
`python3 tools/inspect_feedback_bundle.py <zip> --extract <dir>` is the canonical
stdlib validator.
