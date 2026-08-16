#!/usr/bin/env python3
"""Download, verify, and extract a private playtest feedback report."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.error
import urllib.request

from inspect_feedback_bundle import extract_bundle

REPORT_ID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE
)
ISSUE_URL = re.compile(
    r"https://github\.com/(?P<owner>[A-Za-z0-9][A-Za-z0-9-]*)/"
    r"(?P<repo>[A-Za-z0-9_.-]+)/issues/(?P<number>[1-9][0-9]*)/?"
)
REPORT_MARKER = re.compile(r"<!--\s*feedback-report-id:(%s)\s*-->" % REPORT_ID.pattern, re.IGNORECASE)
SHA256 = re.compile(r"[0-9a-f]{64}")
USER_AGENT = "poke-wilds-feedback-fetch/1.0"


def resolve_report_id(report: str, *, urlopen=urllib.request.urlopen) -> str:
    """Return a report UUID directly or resolve it from a public GitHub issue."""
    if REPORT_ID.fullmatch(report):
        return report.lower()
    issue = ISSUE_URL.fullmatch(report)
    if not issue:
        raise ValueError("report must be a feedback report UUID or public GitHub issue URL")
    request = urllib.request.Request(
        "https://api.github.com/repos/%s/%s/issues/%s"
        % (issue["owner"], issue["repo"], issue["number"]),
        headers={"Accept": "application/vnd.github+json", "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise ValueError("GitHub issue lookup failed: HTTP %d" % exc.code) from exc
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("GitHub issue lookup failed") from exc
    body = payload.get("body") if isinstance(payload, dict) else None
    markers = REPORT_MARKER.findall(body) if isinstance(body, str) else []
    if len(markers) != 1:
        raise ValueError("GitHub issue is missing a unique feedback report marker")
    return markers[0].lower()


def transport_hash_matches(payload: bytes, expected: str) -> bool:
    return bool(SHA256.fullmatch(expected)) and hashlib.sha256(payload).hexdigest() == expected


def bundle_request(endpoint: str, report_id: str, token: str) -> urllib.request.Request:
    return urllib.request.Request(
        f"{endpoint.rstrip('/')}/v1/admin/reports/{report_id}/bundle",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/zip",
            "User-Agent": USER_AGENT,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", help="Report UUID or public GitHub issue URL")
    parser.add_argument("--endpoint", default=os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""))
    parser.add_argument("--output", type=Path, default=Path(".feedback-reports"))
    args = parser.parse_args()
    try:
        report_id = resolve_report_id(args.report)
    except ValueError as exc:
        parser.error(str(exc))
    token = os.environ.get("PLAYTEST_FEEDBACK_ADMIN_TOKEN", "")
    if not args.endpoint or not token:
        parser.error("set PLAYTEST_FEEDBACK_ENDPOINT and PLAYTEST_FEEDBACK_ADMIN_TOKEN")
    request = bundle_request(args.endpoint, report_id, token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read(17 * 1024 * 1024)
            expected = response.headers.get("X-Content-SHA256", "")
    except urllib.error.HTTPError as exc:
        print(f"feedback download failed: HTTP {exc.code}", file=sys.stderr)
        return 1
    if not transport_hash_matches(payload, expected):
        print("feedback download failed: transport checksum mismatch", file=sys.stderr)
        return 1
    destination = args.output / report_id
    with tempfile.NamedTemporaryFile(suffix=".zip") as temporary:
        temporary.write(payload)
        temporary.flush()
        report = extract_bundle(Path(temporary.name), destination)
    print(f"verified report {report['report_id']} -> {destination.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
