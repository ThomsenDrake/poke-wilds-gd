#!/usr/bin/env python3
"""Secret-safe, bounded Command Code API/model connectivity probe."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


API_HOST = "api.commandcode.ai"
DEFAULT_MODEL = "gpt-5.6-luna"
SUCCESS_TOKEN = "COMMAND_CODE_CONNECTIVITY_OK"


def _cmd_executable() -> str | None:
    found = shutil.which("cmd")
    if found:
        return found
    candidate = Path.home() / ".local" / "bin" / "cmd"
    if os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def _diagnostic(returncode: int, stderr: str) -> str:
    lowered = stderr.lower()
    if any(marker in lowered for marker in (
        "unable to connect", "network connection", "econnrefused",
        "enetwork", "enetunreach", "dns", "getaddrinfo",
    )):
        return (
            f"API connectivity failed (cmd exit {returncode}). Codex Cloud agent "
            f"internet access must allow {API_HOST} over HTTPS, including POST."
        )
    if any(marker in lowered for marker in (
        "not authenticated", "unauthorized", "invalid api key", "authentication",
    )):
        return f"authentication failed (cmd exit {returncode}); verify runtime credentials."
    if "model" in lowered and any(marker in lowered for marker in (
        "not found", "unavailable", "unsupported", "access",
    )):
        return f"the selected model is unavailable (cmd exit {returncode})."
    return f"API/model probe failed with cmd exit {returncode}; underlying output was withheld."


def probe(model: str, timeout: int) -> tuple[bool, str]:
    cmd = _cmd_executable()
    if not cmd:
        return False, "Command Code CLI is unavailable."
    argv = [
        cmd,
        "-p",
        f"Return only this exact token: {SUCCESS_TOKEN}",
        "--model",
        model,
        "--no-session",
        "--skip-onboarding",
        "--permission-mode",
        "plan",
        "--max-turns",
        "1",
        "--effort",
        "low",
        "--output-format",
        "text",
    ]
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, f"API/model probe timed out after {timeout}s."
    except OSError as exc:
        return False, f"Command Code could not start ({type(exc).__name__})."
    if proc.returncode != 0:
        return False, _diagnostic(proc.returncode, proc.stderr)
    if proc.stdout.strip() != SUCCESS_TOKEN:
        return False, "API/model probe returned an unexpected response; response content was withheld."
    return True, f"API/model connectivity ready (model={model}, host={API_HOST})."


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=os.environ.get("COMMAND_CODE_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("COMMAND_CODE_CONNECTIVITY_TIMEOUT", "60")),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    if args.timeout <= 0:
        print("probe_command_code: --timeout must be positive.", file=sys.stderr)
        return 2
    ok, detail = probe(args.model, args.timeout)
    stream = sys.stdout if ok else sys.stderr
    print(f"probe_command_code: {detail}", file=stream)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
