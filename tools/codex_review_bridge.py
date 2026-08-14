#!/usr/bin/env python3
"""Mac-side Codex review bridge.

Cloud Agents' `gh` is the Cursor GitHub App (`cursor`). Codex ignores
`@codex review` from that identity and replies "create a Codex account".
This script must run where `gh` is logged in as the human GitHub user.
It posts `@codex review` once per new PR head SHA so a Cloud Agent can
fix, push, and wait without a human in the loop.

  python3 tools/codex_review_bridge.py --pr 37 --dry-run
  python3 tools/codex_review_bridge.py --pr 37
  python3 tools/codex_review_bridge.py --pr 37 --install-launchd
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

FORBIDDEN_LOGINS = frozenset({"cursor"})
STATE_PATH = Path.home() / ".pokewilds-codex-bridge.json"
LAUNCHD_LABEL = "com.pokewilds.codex-review-bridge"
COMMENT_BODY = "@codex review"


def _run_gh(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=check,
    )


def gh_login() -> str:
    """Return the active gh account login, or raise if it is the Cursor app."""
    status = _run_gh(["auth", "status"], check=False)
    text = (status.stdout or "") + (status.stderr or "")
    match = re.search(r"Logged in to github\.com account (\S+)", text)
    login = match.group(1) if match else ""
    if not login:
        who = _run_gh(["api", "user", "--jq", ".login"], check=False)
        if who.returncode == 0:
            login = who.stdout.strip()
    if not login:
        raise SystemExit(
            "codex_review_bridge: gh is not logged in. On the Mac: gh auth login"
        )
    if login in FORBIDDEN_LOGINS:
        raise SystemExit(
            f"codex_review_bridge: gh is {login!r} (Cursor GitHub App). "
            "Codex will ignore @codex review from that identity. "
            "Run this on your Mac where `gh auth status` is your GitHub user."
        )
    return login


def pr_head(pr: int) -> dict:
    raw = _run_gh(
        ["pr", "view", str(pr), "--json", "number,url,headRefOid,headRefName,title"]
    )
    return json.loads(raw.stdout)


def load_state() -> dict:
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(data: dict) -> None:
    STATE_PATH.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def already_commented(pr: int, sha: str) -> bool:
    state = load_state()
    return state.get("pr") == pr and state.get("sha") == sha


def post_review(pr: int, sha: str, login: str, *, dry_run: bool) -> None:
    if dry_run:
        print(f"dry-run: would comment {COMMENT_BODY!r} on PR {pr} as {login} for {sha[:12]}")
        return
    _run_gh(["pr", "comment", str(pr), "--body", COMMENT_BODY])
    save_state({"pr": pr, "sha": sha, "login": login})
    print(f"posted {COMMENT_BODY!r} on PR {pr} as {login} for {sha[:12]}")


def run_once(pr: int, *, dry_run: bool) -> int:
    login = gh_login()
    info = pr_head(pr)
    sha = str(info.get("headRefOid") or "")
    if not sha:
        raise SystemExit(f"codex_review_bridge: PR {pr} has no head SHA")
    if already_commented(pr, sha):
        print(f"already triggered {sha[:12]} on PR {pr}; no-op")
        return 0
    post_review(pr, sha, login, dry_run=dry_run)
    return 0


def install_launchd(pr: int) -> int:
    login = gh_login()
    script = Path(__file__).resolve()
    python = sys.executable
    dest = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCHD_LABEL}.plist"
    log = Path.home() / "Library" / "Logs" / f"{LAUNCHD_LABEL}.log"
    dest.parent.mkdir(parents=True, exist_ok=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string>
    <string>{script}</string>
    <string>--pr</string>
    <string>{pr}</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"""
    dest.write_text(plist, encoding="utf-8")
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LAUNCHD_LABEL}"],
                   capture_output=True, check=False)
    loaded = subprocess.run(
        ["launchctl", "bootstrap", f"gui/{uid}", str(dest)],
        capture_output=True, text=True, check=False,
    )
    if loaded.returncode != 0 and "already" not in (loaded.stderr or "").lower():
        # Older macOS: load instead of bootstrap.
        subprocess.run(["launchctl", "load", "-w", str(dest)], check=False)
    print(f"installed launchd {LAUNCHD_LABEL} as {login}; logs: {log}")
    print(f"plist: {dest}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True, help="Pull request number")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--install-launchd", action="store_true",
                        help="Install a 60s macOS LaunchAgent (run this on the Mac)")
    args = parser.parse_args(argv)
    if args.install_launchd:
        return install_launchd(args.pr)
    return run_once(args.pr, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
