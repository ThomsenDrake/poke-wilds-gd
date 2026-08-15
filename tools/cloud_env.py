#!/usr/bin/env python3
"""Load Linux Cloud display/Vulkan exports written by ensure_cloud_display.sh.

`.cursor/start.sh` is a short-lived child of environment.json `start`, so
sourcing ~/.pokewilds-cloud.env there does not reach later agent shells or
`python3 tools/verify_all.py`. This helper fills unset allowlisted keys from
that file. A nonempty but dead inherited DISPLAY is replaced by the persisted
live value (base Cloud images often export a stale desktop). It never applies
secrets (COMMAND_CODE_API_KEY is refused even if someone added it) and never
overwrites a live DISPLAY or any other key the current process already has.
"""

from __future__ import annotations

from collections.abc import Callable
import os
import re
from pathlib import Path
import shutil
import subprocess

DEFAULT_ENV_FILE = Path.home() / ".pokewilds-cloud.env"
DEFAULT_LOCAL_BIN = Path.home() / ".local" / "bin"
ALLOWED_KEYS = frozenset({
    "DISPLAY",
    "VK_ICD_FILENAMES",
    "GODOT_BIN",
    "COMMANDCODE_SKIP_UPDATES",
    "GODOT_AUDIO_DRIVER",
})
REFUSED_KEYS = frozenset({
    "COMMAND_CODE_API_KEY",
    "DASHSCOPE_API_KEY",
})
_EXPORT_RE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def env_file_path() -> Path:
    override = os.environ.get("POKEWILDS_CLOUD_ENV_FILE", "").strip()
    return Path(override) if override else DEFAULT_ENV_FILE


def local_bin_dir() -> Path:
    override = os.environ.get("POKEWILDS_LOCAL_BIN", "").strip()
    return Path(override) if override else DEFAULT_LOCAL_BIN


def ensure_local_bin_on_path(environ: dict[str, str] | None = None) -> bool:
    """Prepend ~/.local/bin when cmd is installed there and PATH omits it.

    start.sh / install.sh export PATH in a child shell. A later
    `python3 tools/verify_all.py` does not inherit that, so shutil.which('cmd')
    fails even with COMMAND_CODE_API_KEY set. Never replace PATH wholesale.
    """
    target = os.environ if environ is None else environ
    local_bin = str(local_bin_dir())
    current = target.get("PATH", "")
    parts = [p for p in current.split(os.pathsep) if p] if current else []
    if local_bin in parts:
        return False
    cmd_path = Path(local_bin) / "cmd"
    if not os.access(cmd_path, os.X_OK):
        return False
    target["PATH"] = local_bin + (os.pathsep + current if current else "")
    return True


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        inner = value[1:-1]
        if value[0] == '"':
            inner = inner.replace('\\"', '"').replace("\\\\", "\\")
        return inner
    return value


def _display_num(display: str) -> str:
    """`:99`, `:1.0`, and `localhost:10.0` all yield the X11 socket number."""
    text = (display or "").strip()
    if ":" not in text:
        return ""
    return text.rsplit(":", 1)[-1].split(".", 1)[0]


def display_alive(display: str, *, x11_dir: Path | None = None) -> bool:
    """True when xdpyinfo or the X11 unix socket says this DISPLAY is live.

    Mirrors tools/ensure_cloud_display.sh `_display_alive`: prefer xdpyinfo
    when installed, else `/tmp/.X11-unix/X<n>`.
    """
    text = (display or "").strip()
    if not text:
        return False
    xdpyinfo = shutil.which("xdpyinfo")
    if xdpyinfo:
        env = os.environ.copy()
        env["DISPLAY"] = text
        try:
            proc = subprocess.run(
                [xdpyinfo], env=env, capture_output=True, timeout=2, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        return proc.returncode == 0
    num = _display_num(text)
    if not num.isdigit():
        return False
    return ((x11_dir or Path("/tmp/.X11-unix")) / f"X{num}").is_socket()


def parse_export_line(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    match = _EXPORT_RE.match(stripped)
    if match is None:
        return None
    key, raw = match.group(1), match.group(2)
    if "$(" in raw or "`" in raw or raw.startswith("$'"):
        return None
    return key, _unquote(raw)


def load_cloud_env(environ: dict[str, str] | None = None,
                   path: Path | None = None,
                   display_probe: Callable[[str], bool] | None = None) -> list[str]:
    """Fill unset allowlisted keys from the Cloud env file. Returns applied keys.

    DISPLAY is the exception: a nonempty dead inherited value is replaced by
    the persisted live display so later verify_all does not launch Godot
    against a stale Cloud desktop.
    """
    target = os.environ if environ is None else environ
    env_path = path if path is not None else env_file_path()
    probe = display_probe if display_probe is not None else display_alive
    applied: list[str] = []
    try:
        text = env_path.read_text(encoding="utf-8")
    except OSError:
        text = None
    if text:
        for line in text.splitlines():
            parsed = parse_export_line(line)
            if parsed is None:
                continue
            key, value = parsed
            if key in REFUSED_KEYS or key not in ALLOWED_KEYS:
                continue
            current = target.get(key, "")
            if current:
                if key != "DISPLAY" or current == value or probe(current):
                    continue
            target[key] = value
            applied.append(key)
    if ensure_local_bin_on_path(target):
        applied.append("PATH")
    return applied


def apply_cloud_env() -> list[str]:
    """Import-time entry: load ~/.pokewilds-cloud.env into os.environ."""
    return load_cloud_env()
