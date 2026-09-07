---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: in-progress
---

# Alpha feedback without friend invitations

Date: 2026-09-07
Base: 8229812db24a9b7009a67cb53af796998509349a

## Outcome and evidence

Anyone running an alpha desktop build, including Windows, can press F, describe a problem, and receive a GitHub issue number without a friend invitation or GitHub login. The user reports failed/missing submissions on Windows; no Windows reproduction has yet been captured.

Read-only analysis found that public exports intentionally omit endpoint/invite metadata, FeedbackReporter requires an invite, and persisted friend identity can override current routing. Production D1 contains completed Windows reports through issue 68, and its Cursor enqueue run succeeded, so retain the existing issue pipeline. Cloudflare health rejects Python's default User-Agent with 403/1010 but accepts an explicit app User-Agent; that is transport evidence, not proof of the Windows cause. PR 57 already contains an unmerged Escape-only feedback fix.

## Implementation

1. Add explicit `feedback_mode: "public"`, `feedback_endpoint`, and anonymous tester label `PUBLIC-ALPHA` to public and shared alpha build metadata. No per-friend credential is needed. Keep public update endpoint empty so feedback does not enable the playtest updater. Preserve legacy personalized packaging and queued reports for compatibility.
2. Resolve public feedback directly from the embedded stamp before any persisted friend-identity merge. Controller availability, reporter validation, and durable private outbox routes must agree. Public uploads omit Authorization; legacy invited uploads retain it. Use an explicit `PokeWilds-feedback/1.0` User-Agent and bounded safe relay error identifiers.
3. Relay: absent Authorization selects anonymous alpha admission; any supplied credential still takes strict legacy invite authentication and cannot downgrade. Accept `PUBLIC-ALPHA` only on `public`/`playtest` channels, rate-limit before body parsing by hashed client address, and retain existing per-install/day and per-channel/day quotas. Reuse all multipart/ZIP/manifest/hash checks, private R2, D1 leases/idempotency, and sanitized GitHub issue creation. No D1 migration is required.
4. Repair the X-key text-input bug using the existing PR's intended behavior. Escape cancels; Enter sends; Shift+Enter inserts a newline. Retain the result until acknowledged so Windows testers can read whether a report was sent, queued, or rejected.
5. Update product/reliability/schema/registry/quality contracts and release checks to reflect public alpha intake. Keep GitHub App/admin credentials server-side and tokenless public releases free of deployment secrets.

## Validation and rollout

- Focused Godot feedback flow: public stamp, stale friend identity, no auth header, real X input, acknowledgement, retry success, permanent failure, and legacy routes.
- Relay TypeScript/Vitest: anonymous accepted, invalid supplied invite rejected, limits before parsing, malformed bundles rejected, duplicate report produces one issue.
- Python publisher/bundle/repository-contract tests; production and staging Wrangler dry-runs.
- Godot DAP feedback smoke and display matrix; appropriate full `verify_all.py` gate. Record pre-existing failures separately rather than accepting stale evidence.
- Deploy staging only after checks; verify live behavior before production. Any public test issue must have explicit authorization or use an existing user-authored submission. Do not silently resend old reports or create fabricated player feedback.
- Produce a Windows alpha artifact/configuration receipt; native Windows execution remains unverified until a Windows host/tester runs it. Do not describe Mac smoke results as Windows validation.

## Workspace safety

Work in the isolated `codex/alpha-feedback` worktree. Preserve the user's original checkout and its existing `project.godot` edit. Do not print, stage, or copy credentials or private report bundles.
