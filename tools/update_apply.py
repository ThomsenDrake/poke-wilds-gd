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
        return _apply_file(target, artifact, keep_old=False)
    if os_name == "macOS":
        return _apply_macos(target, artifact)
    return {"ok": False, "error": "unknown_os"}


def cleanup_old(target: Path) -> None:
    old = Path(str(target) + ".old")
    if old.is_dir():
        shutil.rmtree(old)
    elif old.exists():
        old.unlink()


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
    helper = target.with_name("PokeWilds-update.cmd")
    helper.write_text(
        _windows_helper_body(target, staged, os.getpid()),
        encoding="ascii",
        newline="\r\n",
    )
    return {"ok": True, "deferred": True, "helper": str(helper), "old_path": str(target) + ".old"}


def _windows_helper_body(target: Path, staged: Path, pid: int) -> str:
    old = Path(str(target) + ".old")
    return "\r\n".join([
        "@echo off",
        ":wait",
        "timeout /t 1 /nobreak >nul",
        f'tasklist /FI "PID eq {pid}" | find "{pid}" >nul',
        "if not errorlevel 1 goto wait",
        f'if exist "{old}" del /f /q "{old}"',
        f'if exist "{target}" move /y "{target}" "{old}"',
        f'move /y "{staged}" "{target}"',
        f'start "" "{target}"',
        "",
    ])


def _apply_file(target: Path, artifact: Path, *, keep_old: bool) -> dict:
    old = Path(str(target) + ".old")
    cleanup_old(target)
    if target.exists():
        target.replace(old)
    shutil.copy2(artifact, target)
    if target.name.endswith(".x86_64") or not keep_old:
        target.chmod(0o755)
    if not keep_old and old.exists():
        old.unlink()
    return {"ok": True, "old_path": str(old) if keep_old else ""}


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
