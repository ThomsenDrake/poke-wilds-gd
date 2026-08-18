# Playtest feedback relay

Cloudflare Worker that accepts authenticated release-build reports, stores the
raw ZIP in a private R2 bucket, and opens one public GitHub issue through a
repository-scoped GitHub App. The game never receives GitHub credentials.

Production and staging are already provisioned. Their successful end-to-end
canaries created issues #32 and #33, which were closed after verification.
The repository workflow now deploys relay changes through staging and production;
it does not create or rerun canary issues.

## Automated deployment

`.github/workflows/feedback-relay-deploy.yml` owns the deployment sequence. Pull
requests changing this service run `npm ci`, `npm run check`, and staging plus
production Wrangler dry-runs without Cloudflare credentials. A push to `main`
changing this directory runs the same validation, then:

1. applies pending D1 migrations and deploys through `feedback-staging`;
2. verifies staging `/healthz` reports `ok`, environment `staging`, and schema 1;
3. applies pending D1 migrations and deploys through `feedback-production`; and
4. verifies the corresponding production health contract.

The workflow has one non-cancelling concurrency group, so migration/deploy runs do
not overlap. It passes `--strict` and `--keep-vars`: risky configuration drift
refuses deployment, while dashboard-managed non-secret vars remain intact. Worker
secrets are not replaced or copied into GitHub. The Cloudflare CI credential is
scoped to the four migration/deploy steps; lockfile installation, checks, dry-runs,
and health probes cannot read it.
Third-party GitHub Actions are pinned to full commit SHAs; dependency installation
continues to use the committed npm lockfile.

Each GitHub environment defines `CLOUDFLARE_ACCOUNT_ID` and a least-privilege
`CLOUDFLARE_API_TOKEN` restricted to this Cloudflare account with Workers Scripts
Edit and D1 Edit access. Never add `GITHUB_PRIVATE_KEY`, `ADMIN_TOKEN`, invite
tokens, or build metadata to GitHub Actions. A `workflow_dispatch` of `main`
provides the same staging-first recovery path when a deployment must be rerun
without a source change; dispatches of any other ref validate but cannot deploy.

D1 migrations in this service must use expand/contract sequencing: a migration
applied before a Worker deployment remains compatible with the currently running
Worker if that deployment refuses or fails.

## Provisioning

1. Create production and staging D1 databases and R2 buckets, then bind their
   IDs and names in `wrangler.jsonc`.
2. Apply `migrations/0001_initial.sql` with `wrangler d1 migrations apply` for
   each environment.
3. Create a GitHub App installed only on `ThomsenDrake/poke-wilds-gd`, granting
   Metadata read and Issues write. Convert its private key to unencrypted PKCS#8.
4. Set `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_PRIVATE_KEY`, and
   `ADMIN_TOKEN` with `wrangler secret put`; never place values in this repo.
5. Pre-create the `playtest-feedback` and `needs-triage` labels, deploy staging,
   run the canary, then deploy production.

The provisioned Workers are:

- Production: `https://poke-wilds-feedback-relay.drake-t.workers.dev`
- Staging: `https://poke-wilds-feedback-relay-staging.drake-t.workers.dev`

Set the R2 lifecycle on both buckets as defense in depth after bucket creation
(the scheduled handler also expires D1-linked objects):

```bash
npx wrangler r2 bucket lifecycle add poke-wilds-feedback-private feedback-artifacts-180d reports/ --expire-days 180 --abort-multipart-days 1
npx wrangler r2 bucket lifecycle add poke-wilds-feedback-private-staging feedback-artifacts-180d reports/ --expire-days 180 --abort-multipart-days 1
```

The daily scheduled handler deletes private bundles after their 180-day expiry in
deterministic 100-row pages, up to 1,000 objects per run. Each page bulk-deletes R2
only after an atomic D1 `expiring` claim returns the exact rows it owns, then finishes
with a guarded `expired` update. Uploads hold a short `uploading` lease before writing
R2, so either upload or cleanup wins the D1 transition; stale leases and interrupted
cleanup claims remain eligible for the next run. Stored ISO timestamps are normalized
through SQLite `datetime()` before comparison.
A full tenth page emits aggregate-only capacity telemetry. The provisioned R2 lifecycle is the
authoritative backstop if future global intake exceeds that bounded Worker capacity.
Expiring and expired report IDs are terminal for uploads and admin downloads, so a
late client retry cannot recreate or expose an object after cleanup takes ownership.
Worker logs contain identifiers, sizes, status, issue numbers, and aggregate cleanup
counts only.

Report uploads are invite-authorized and rate-limited before their multipart bodies
are read. The relay streams a hard body cap, validates only the EOCD-declared ZIP
directory and matching local headers before decompression, and compares all private
manifest identity and capture fields to the upload envelope. Public issues expose no
party, tile, area, time, battle, save, trace, screenshot, or diagnostics data.
