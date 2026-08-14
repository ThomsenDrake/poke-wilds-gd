---
name: codex-review-bridge
description: Install or run the Mac-side Codex review bridge so Cloud Agents can loop on @codex review as the human GitHub user.
---

# Codex review bridge

Cloud Agents' `gh` is the Cursor GitHub App (`cursor`). Codex ignores
`@codex review` from that identity. A Cursor dashboard Automation's
"Comment on pull request" tool also posts as `cursor`.

The working bridge is the human's local `gh` on the Mac.

## Install (once, on the Mac)

```bash
gh auth status   # must be ThomsenDrake, not cursor
python3 tools/codex_review_bridge.py --pr 37 --install-launchd
```

That writes `~/Library/LaunchAgents/com.pokewilds.codex-review-bridge.plist`
and polls PR 37 every 60s. Each new head SHA gets one `@codex review` comment
as you. Logs: `~/Library/Logs/com.pokewilds.codex-review-bridge.log`.

## One-shot

```bash
python3 tools/codex_review_bridge.py --pr 37 --dry-run
python3 tools/codex_review_bridge.py --pr 37
```

## Do not

- Do not post `@codex review` from a Cloud Agent or via ManagePullRequest.
- Do not enable a Cursor Automation whose only action is "Comment on pull request" for this loop — Codex will reject `cursor`.
