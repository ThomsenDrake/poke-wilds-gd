"""Shared validation for feedback relay endpoints that receive bearer tokens."""

from __future__ import annotations

import urllib.parse


def validated_endpoint(endpoint: str) -> str:
    candidate = endpoint.strip().rstrip("/")
    try:
        parsed = urllib.parse.urlsplit(candidate)
        parsed.port  # Force validation of a malformed explicit port.
    except ValueError as exc:
        raise ValueError("feedback endpoint must be a valid HTTPS URL") from exc
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or
            parsed.password is not None or "?" in candidate or "#" in candidate or "\\" in candidate or
            any(char.isspace() for char in candidate)):
        raise ValueError("feedback endpoint must be an HTTPS URL without credentials, query, or fragment")
    return candidate
