#!/usr/bin/env python3
"""Create one friend-specific release package without printing its invite token."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import sys
from datetime import datetime, timezone
import urllib.error
import urllib.request

from feedback_endpoint import open_no_redirect, validated_endpoint as _validated_endpoint

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / ".playtest" / "invites.json"
BUILD_INFO = ROOT / "generated" / "playtest_build.json"
BUILD_LOCK = ROOT / "generated" / ".playtest-package.lock"
TARGETS = {
    "macos": ("macOS", ".zip"),
    "windows": ("Windows Desktop", ".exe"),
    "linux": ("Linux", ".x86_64"),
}
USER_AGENT = "poke-wilds-playtest-package/1.0"

# Public handles are derived only from the opaque invite token. Friend names remain
# confined to the ignored private registry and the relay's private D1 record.
POKEMON_HANDLE_SPECIES = (
    "BULBASAUR", "CHARMANDER", "SQUIRTLE", "CATERPIE", "PIKACHU", "SANDSHREW",
    "VULPIX", "ODDISH", "MEOWTH", "PSYDUCK", "GROWLITHE", "ABRA", "MACHOP",
    "GEODUDE", "PONYTA", "SLOWPOKE", "MAGNEMITE", "FARFETCHD", "DODUO",
    "SEEL", "SHELLDER", "GASTLY", "DROWZEE", "KRABBY", "CUBONE", "HORSEA",
    "GOLDEEN", "STARYU", "SCYTHER", "EEVEE", "PORYGON", "SNORLAX",
)


def run(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def worktree_is_dirty() -> bool:
    """Include untracked exportable resources; ignored private/output paths stay hidden."""
    return bool(run("git", "status", "--porcelain"))


def validated_endpoint(endpoint: str) -> str:
    try:
        return _validated_endpoint(endpoint)
    except ValueError as exc:
        raise RuntimeError(str(exc)) from exc


@contextmanager
def build_metadata_lock():
    """Refuse concurrent exports before either process can touch shared metadata."""
    BUILD_LOCK.parent.mkdir(parents=True, exist_ok=True)
    handle = BUILD_LOCK.open("a+b")
    try:
        try:
            if os.name == "nt":
                import msvcrt
                handle.seek(0)
                if not handle.read(1):
                    handle.write(b"\0")
                    handle.flush()
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise RuntimeError("another playtest package export is already running") from exc
        yield
    finally:
        handle.close()


def load_registry() -> dict:
    if not REGISTRY.exists():
        return {"schema_version": 1, "friends": {}}
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def _windows_account_identity() -> str:
    """Return the current Windows account without a console-code-page round trip."""
    import ctypes
    from ctypes import wintypes

    name_sam_compatible = 2
    get_username_ex = ctypes.WinDLL("secur32", use_last_error=True).GetUserNameExW
    get_username_ex.argtypes = (
        wintypes.ULONG,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.ULONG),
    )
    get_username_ex.restype = wintypes.BOOL

    size = wintypes.ULONG(0)
    get_username_ex(name_sam_compatible, None, ctypes.byref(size))
    if not size.value:
        raise ctypes.WinError(ctypes.get_last_error())
    account_buffer = ctypes.create_unicode_buffer(size.value)
    if not get_username_ex(name_sam_compatible, account_buffer, ctypes.byref(size)):
        raise ctypes.WinError(ctypes.get_last_error())
    return account_buffer.value.strip()


def _secure_private_file(path: Path, *, platform: str | None = None,
                         identity: str | None = None, runner=subprocess.run) -> None:
    """Restrict a private file to its owner on POSIX and Windows."""
    platform = os.name if platform is None else platform
    if platform != "nt":
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        return
    try:
        account = identity or _windows_account_identity()
    except OSError as exc:
        raise RuntimeError("could not identify the Windows account for the private invite registry") from exc
    if not account:
        raise RuntimeError("could not identify the Windows account for the private invite registry")
    try:
        runner(
            ["icacls", str(path), "/inheritance:r", "/grant:r", f"{account}:(F)"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("timed out securing the private invite registry") from exc


def save_registry(registry: dict) -> None:
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    temporary = REGISTRY.with_name(f".{REGISTRY.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IRUSR | stat.S_IWUSR)
    try:
        _secure_private_file(temporary)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            json.dump(registry, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, REGISTRY)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def public_tester_id(token: str) -> str:
    """Return a stable Pokemon-themed handle without incorporating private names."""
    digest = hashlib.sha256(f"pokemon-handle-v1:{token}".encode()).hexdigest().upper()
    species = POKEMON_HANDLE_SPECIES[int(digest[:8], 16) % len(POKEMON_HANDLE_SPECIES)]
    return f"PKMN-{species}-{digest[8:14]}"


def invite_for(friend: str, cohort: str) -> dict:
    registry = load_registry()
    key = friend.casefold().strip()
    invite = registry["friends"].get(key)
    if invite and invite.get("cohort_id") == cohort:
        tester_id = public_tester_id(invite["token"])
        if invite.get("tester_id") != tester_id:
            invite["tester_id"] = tester_id
            save_registry(registry)
        return invite
    token = secrets.token_urlsafe(32)
    invite = {"nickname": friend.strip(), "tester_id": public_tester_id(token),
              "token": token, "cohort_id": cohort}
    registry["friends"][key] = invite
    save_registry(registry)
    return invite


def register_invite(endpoint: str, admin_token: str, invite: dict, *, urlopen=open_no_redirect) -> None:
    endpoint = validated_endpoint(endpoint)
    payload = json.dumps({"tester_id": invite["tester_id"], "nickname": invite["nickname"],
                          "cohort_id": invite["cohort_id"],
                          "token_hash": hashlib.sha256(invite["token"].encode()).hexdigest()}).encode()
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v1/admin/invites", data=payload, method="POST",
        headers={"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json",
                 "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=20) as response:
            if response.status not in (200, 201):
                raise RuntimeError(f"invite registration returned HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"invite registration returned HTTP {exc.code}") from exc


def godot_binary() -> str:
    configured = os.environ.get("GODOT_BIN", "")
    if configured:
        return configured
    found = shutil.which("godot") or shutil.which("godot4")
    if found:
        return found
    mac = Path("/Applications/Godot.app/Contents/MacOS/Godot")
    if mac.exists():
        return str(mac)
    raise RuntimeError("Godot binary not found; set GODOT_BIN")


def build_package(args: argparse.Namespace, admin_token: str) -> tuple[Path, str]:
    """Create an export while guaranteeing generated token metadata is removed."""
    endpoint = validated_endpoint(args.endpoint)
    with build_metadata_lock():
        try:
            invite = invite_for(args.friend, args.channel)
            register_invite(endpoint, admin_token, invite)
            commit = run("git", "rev-parse", "HEAD")
            version = run("git", "describe", "--tags", "--always")
            published_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            timestamp = published_at.replace(":", "").replace("-", "")
            build_id = f"{args.channel}-{commit[:10]}-{timestamp}"
            BUILD_INFO.parent.mkdir(parents=True, exist_ok=True)
            BUILD_INFO.write_text(json.dumps({
                "schema_version": 1, "version": version, "commit_sha": commit,
                "build_id": build_id, "channel": args.channel, "endpoint": endpoint,
                "published_at": published_at,
                "tester_id": invite["tester_id"], "invite_token": invite["token"],
            }, indent=2) + "\n", encoding="utf-8")
            output_dir = ROOT / "dist" / "playtest" / invite["tester_id"]
            output_dir.mkdir(parents=True, exist_ok=True)
            preset, extension = TARGETS[args.target]
            output = output_dir / f"PokeWilds-{build_id}-{args.target}{extension}"
            subprocess.run([godot_binary(), "--headless", "--path", str(ROOT),
                            "--export-release", preset, str(output)], check=True, cwd=ROOT)
            return output, invite["tester_id"]
        finally:
            BUILD_INFO.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--friend", required=True)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--channel", default="friends-1")
    parser.add_argument("--endpoint", default=os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""))
    parser.add_argument("--allow-dirty", action="store_true", help="Local validation only; never use for distributed builds")
    args = parser.parse_args()
    admin_token = os.environ.get("PLAYTEST_FEEDBACK_ADMIN_TOKEN", "")
    if not args.endpoint or not admin_token:
        parser.error("set PLAYTEST_FEEDBACK_ENDPOINT and PLAYTEST_FEEDBACK_ADMIN_TOKEN")
    if not args.allow_dirty and worktree_is_dirty():
        parser.error("worktree is dirty; commit or ignore every release input first")
    output, tester_id = build_package(args, admin_token)
    print(f"created {tester_id} {args.target} package: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"playtest packaging failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
