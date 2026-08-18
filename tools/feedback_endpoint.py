"""Shared validation for feedback relay endpoints that receive bearer tokens."""

from __future__ import annotations

import urllib.error
import urllib.parse
import urllib.request


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect before urllib can copy a privileged header."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        if fp is not None:
            fp.close()
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, None)


_NO_REDIRECT_OPENER = urllib.request.build_opener(_RejectRedirects())


def open_no_redirect(request: urllib.request.Request, *, timeout: int):
    return _NO_REDIRECT_OPENER.open(request, timeout=timeout)


def validated_endpoint(endpoint: str) -> str:
    candidate = endpoint.strip().rstrip("/")
    try:
        parsed = urllib.parse.urlsplit(candidate)
        parsed.port  # Force validation of a malformed explicit port.
    except ValueError as exc:
        raise ValueError("feedback endpoint must be a valid HTTPS URL") from exc
    if (parsed.scheme != "https" or not parsed.hostname or parsed.netloc.endswith(":") or
            parsed.username is not None or
            parsed.password is not None or "?" in candidate or "#" in candidate or "\\" in candidate or
            any(char.isspace() for char in candidate)):
        raise ValueError("feedback endpoint must be an HTTPS URL without credentials, query, or fragment")
    return candidate
