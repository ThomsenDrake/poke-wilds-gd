#!/usr/bin/env python3
"""OS install-swap helpers for shared desktop updates."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import zipfile


SAVE_NAME = "godot_port_save.json"


def apply(os_name: str, artifact: Path, target: Path) -> dict:
    artifact = Path(artifact)
    target = Path(target)
    if not artifact.is_file():
        return {"ok": False, "error": "pending_missing"}
    if SAVE_NAME in target.name:
        return {"ok": False, "error": "save_path_refused"}
    if os_name == "Windows":
        return _apply_windows(target, artifact)
    if os_name == "Linux":
        return _apply_linux(target, artifact)
    if os_name == "macOS":
        return _apply_macos(target, artifact)
    return {"ok": False, "error": "unknown_os"}


def cleanup_old(target: Path) -> None:
    old = Path(str(target) + ".old")
    if old.is_dir():
        shutil.rmtree(old)
    elif old.exists():
        old.unlink()


def launch_deferred(applied: dict, *, create_process=None) -> bool:
    helper = str(applied.get("helper", ""))
    path = Path(helper)
    if not helper or not path.is_file():
        return False
    starter = create_process or (lambda _path: -1)
    return int(starter(path)) >= 0


def complete_windows_swap(target: Path, staged: Path | None = None) -> dict:
    target = Path(target)
    staged = Path(staged) if staged is not None else Path(str(target) + ".new")
    old = Path(str(target) + ".old")
    if old.exists():
        old.unlink()
    if target.exists():
        target.replace(old)
    staged.replace(target)
    return {"ok": True, "old_path": str(old)}


def _apply_windows(target: Path, artifact: Path) -> dict:
    staged = Path(str(target) + ".new")
    if staged.exists():
        staged.unlink()
    shutil.copy2(artifact, staged)
    body = _windows_helper_body(target, staged, os.getpid())
    if not body:
        staged.unlink(missing_ok=True)
        return {"ok": False, "error": "helper_failed"}
    helper = target.with_name("PokeWilds-update.cmd")
    helper.write_text(body, encoding="ascii", newline="\r\n")
    return {"ok": True, "deferred": True, "helper": str(helper), "old_path": str(target) + ".old"}


def _ascii_file_name(path: Path) -> str:
    name = path.name
    if not name or not name.isascii() or any(char in name for char in "\"%/\\"):
        return ""
    return name


def _windows_helper_body(target: Path, staged: Path, pid: int) -> str:
    name = _ascii_file_name(target)
    if not name or _ascii_file_name(staged) != f"{name}.new":
        return ""
    return "\r\n".join([
        "@echo off",
        ":wait",
        "timeout /t 1 /nobreak >nul",
        f'tasklist /FI "PID eq {pid}" | find "{pid}" >nul',
        "if not errorlevel 1 goto wait",
        f'if exist "%~dp0{name}" (',
        f'move /y "%~dp0{name}" "%~dp0{name}.old"',
        "if errorlevel 1 goto launch",
        ")",
        f'move /y "%~dp0{name}.new" "%~dp0{name}"',
        "if errorlevel 1 (",
        f'if exist "%~dp0{name}.old" move /y "%~dp0{name}.old" "%~dp0{name}"',
        ")",
        ":launch",
        f'if exist "%~dp0{name}" start "" "%~dp0{name}"',
        "",
    ])


def _apply_linux(target: Path, artifact: Path) -> dict:
    staged = Path(str(target) + ".new")
    old = Path(str(target) + ".old")
    if staged.exists():
        staged.unlink()
    try:
        shutil.copy2(artifact, staged)
    except OSError:
        if staged.exists():
            staged.unlink()
        return {"ok": False, "error": "write_failed"}
    try:
        staged.chmod(0o755)
    except OSError:
        if staged.exists():
            staged.unlink()
        return {"ok": False, "error": "chmod_failed"}
    cleanup_old(target)
    try:
        if target.exists():
            target.replace(old)
        staged.replace(target)
    except OSError:
        if old.exists() and not target.exists():
            old.replace(target)
        if staged.exists():
            staged.unlink()
        return {"ok": False, "error": "write_failed"}
    if old.exists():
        old.unlink()
    return {"ok": True, "old_path": ""}


def _apply_macos(target: Path, artifact: Path) -> dict:
    staged = Path(str(target) + ".new")
    if staged.exists():
        shutil.rmtree(staged)
    staged.mkdir(parents=True)
    with zipfile.ZipFile(artifact) as archive:
        archive.extractall(staged)
    apps = [path for path in staged.iterdir() if path.name.endswith(".app")]
    if not apps:
        shutil.rmtree(staged)
        return {"ok": False, "error": "app_missing"}
    old = Path(str(target) + ".old")
    cleanup_old(target)
    if target.exists():
        target.replace(old)
    apps[0].replace(target)
    shutil.rmtree(staged, ignore_errors=True)
    if old.exists():
        shutil.rmtree(old)
    return {"ok": True, "old_path": ""}
