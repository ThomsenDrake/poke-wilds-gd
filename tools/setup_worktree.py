#!/usr/bin/env python3
"""Bootstrap an existing PokeWilds-Godot worktree without touching its branch.

The setup is intentionally separate from ``git worktree add``.  Local editor
hooks use ``--quick`` to verify the runtime without taking the repository-wide
cache/import lock.  The default full preparation creates ignored per-worktree
caches, imports Godot resources, and can run the cheap static gates.  It never
refreshes the committed PokeAPI pin or reverts tracked files.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
from typing import Iterator


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
MIN_PYTHON = (3, 12)
GODOT_VERSION_RE = re.compile(r"^4\.6\.1\.")
POKEAPI_SENTINEL = Path("tools/.cache/api-data/data/api/v2/pokemon/index.json")
POKEAPI_STAMP = Path("tools/.cache/setup-pin.sha")
STATIC_CHECKS = (
    "check_repo_contracts.py",
    "check_architecture.py",
    "check_quality_docs.py",
    "check_change_contract.py",
)


class SetupError(RuntimeError):
    def __init__(self, code: str, detail: str, *, retryable: bool, hint: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.retryable = retryable
        self.hint = hint

    def envelope(self) -> dict[str, object]:
        return {
            "ok": False,
            "error": {
                "code": self.code,
                "retryable": self.retryable,
                "hint": self.hint,
                "detail": self.detail,
            },
        }


def _display_command(argv: list[str]) -> str:
    return shlex.join(argv)


def _run(
    argv: list[str],
    *,
    cwd: Path = ROOT,
    timeout: float | None = None,
    capture: bool = False,
    dry_run: bool = False,
    code: str = "command_failed",
    retryable: bool = True,
    hint: str = "Fix the reported command failure, then re-run setup_worktree.py.",
) -> subprocess.CompletedProcess[str] | None:
    print(f"+ {_display_command(argv)}")
    if dry_run:
        return None
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            text=True,
            capture_output=capture,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SetupError(
            code,
            f"Command timed out after {timeout:g}s: {_display_command(argv)}",
            retryable=True,
            hint=hint,
        ) from exc
    except OSError as exc:
        raise SetupError(
            code,
            f"Could not launch {_display_command(argv)}: {exc}",
            retryable=retryable,
            hint=hint,
        ) from exc
    if result.returncode != 0:
        captured = ""
        if capture:
            captured = (result.stderr or result.stdout or "").strip()
        detail = f"Command exited {result.returncode}: {_display_command(argv)}"
        if captured:
            detail += f"\n{captured}"
        raise SetupError(code, detail, retryable=retryable, hint=hint)
    return result


def _git_output(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", *args], cwd=root, capture_output=True, text=True, check=True
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SetupError(
            "git_worktree_invalid",
            f"Cannot inspect Git worktree at {root}: {exc}",
            retryable=False,
            hint="Run this command from a valid checkout of this repository.",
        ) from exc
    return result.stdout.strip()


def _worktree_root(path: Path) -> Path:
    return Path(_git_output(path, "rev-parse", "--show-toplevel")).resolve()


def _common_git_dir(root: Path) -> Path:
    raw = Path(_git_output(root, "rev-parse", "--git-common-dir"))
    return (raw if raw.is_absolute() else root / raw).resolve()


def _resolve_executable(value: str) -> str:
    candidate = Path(value).expanduser()
    if candidate.is_file():
        return str(candidate.resolve())
    found = shutil.which(value)
    if found:
        return found
    raise SetupError(
        "godot_binary_missing",
        f"Godot binary not found: {value}",
        retryable=True,
        hint="Install Godot 4.6.1 or pass --godot-bin PATH (GODOT_BIN is also supported).",
    )


def is_supported_godot_version(version: str) -> bool:
    return bool(GODOT_VERSION_RE.match(version.strip()))


def _check_versions(godot_value: str) -> str:
    if sys.version_info < MIN_PYTHON:
        raise SetupError(
            "python_version_mismatch",
            f"Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ is required; found "
            f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}.",
            retryable=False,
            hint="Re-run the setup script with Python 3.12 or newer.",
        )
    print(
        "Python version: "
        f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    )
    godot_bin = _resolve_executable(godot_value)
    result = _run(
        [godot_bin, "--version"],
        capture=True,
        code="godot_version_probe_failed",
        hint="Run the Godot binary directly, fix the launch failure, then re-run setup.",
    )
    assert result is not None
    version = result.stdout.strip()
    print(f"Godot version: {version}")
    if not is_supported_godot_version(version):
        raise SetupError(
            "godot_version_mismatch",
            f"Godot 4.6.1.x is required; found {version or '<empty version>'}.",
            retryable=False,
            hint="Point --godot-bin or GODOT_BIN at the pinned Godot 4.6.1 binary.",
        )
    return godot_bin


def _api_cache_complete(root: Path) -> bool:
    return (root / POKEAPI_SENTINEL).is_file()


def _pin_sha(root: Path) -> str:
    pin_path = root / "tools/api_data_pin.json"
    try:
        value = json.loads(pin_path.read_text(encoding="utf-8")).get("sha")
    except (OSError, ValueError, AttributeError) as exc:
        raise SetupError(
            "pokeapi_pin_invalid",
            f"Cannot read the committed PokeAPI pin at {pin_path}: {exc}",
            retryable=False,
            hint="Restore tools/api_data_pin.json from the intended branch, then re-run setup.",
        ) from exc
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise SetupError(
            "pokeapi_pin_invalid",
            f"Committed PokeAPI pin has an invalid sha: {value!r}",
            retryable=False,
            hint="Restore tools/api_data_pin.json from the intended branch, then re-run setup.",
        )
    return value


def _pinned_api_cache_ready(root: Path) -> bool:
    if not _api_cache_complete(root):
        return False
    try:
        return (root / POKEAPI_STAMP).read_text(encoding="utf-8").strip() == _pin_sha(root)
    except OSError:
        return False


def _pins_match(source: Path, target: Path) -> bool:
    source_pin = source / "tools/api_data_pin.json"
    target_pin = target / "tools/api_data_pin.json"
    try:
        return source_pin.read_bytes() == target_pin.read_bytes()
    except OSError:
        return False


def _directory_has_entries(path: Path) -> bool:
    try:
        next(path.iterdir())
    except (FileNotFoundError, NotADirectoryError, StopIteration):
        return False
    return True


def _refuse_shared_cache_links(root: Path) -> None:
    linked = [relative for relative in (Path(".godot"), Path("tools/.cache"))
              if (root / relative).is_symlink()]
    if linked:
        rendered = ", ".join(str(path) for path in linked)
        raise SetupError(
            "shared_cache_symlink_refused",
            f"Writable worktree caches must be independent, not symlinks: {rendered}",
            retryable=False,
            hint="Replace the listed symlink with an independent directory, or use --seed-from to clone a missing cache.",
        )


def _copy_cache_tree(source: Path, target: Path, *, dry_run: bool) -> None:
    if source.is_symlink() or target.is_symlink():
        raise SetupError(
            "shared_cache_symlink_refused",
            f"Refusing to seed through a cache symlink: {source} -> {target}",
            retryable=False,
            hint="Use independent cache directories in both worktrees, then re-run setup.",
        )
    if target.exists():
        if not target.is_dir():
            raise SetupError(
                "cache_destination_invalid",
                f"Cache destination exists but is not a directory: {target}",
                retryable=False,
                hint="Move the conflicting path aside, then re-run setup.",
            )
        if _directory_has_entries(target):
            print(f"Cache already exists; not replacing: {target}")
            return
        if not dry_run:
            target.rmdir()
    if not dry_run:
        target.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin" and shutil.which("cp"):
        _run(
            [shutil.which("cp") or "cp", "-cR", str(source), str(target)],
            dry_run=dry_run,
            code="cache_seed_failed",
            hint="Remove the incomplete destination cache or omit --seed-from, then re-run setup.",
        )
        return
    print(f"Copying cache tree: {source} -> {target}")
    if not dry_run:
        try:
            shutil.copytree(source, target)
        except OSError as exc:
            raise SetupError(
                "cache_seed_failed",
                f"Could not copy {source} to {target}: {exc}",
                retryable=True,
                hint="Remove the incomplete destination cache or omit --seed-from, then re-run setup.",
            ) from exc


def _seed_from_worktree(source_value: str, target: Path, *, dry_run: bool) -> None:
    source = _worktree_root(Path(source_value).expanduser().resolve())
    if source == target:
        raise SetupError(
            "cache_seed_source_invalid",
            "--seed-from must name a different worktree.",
            retryable=False,
            hint="Pass the path to another worktree with warm caches, or omit --seed-from.",
        )
    if _common_git_dir(source) != _common_git_dir(target):
        raise SetupError(
            "cache_seed_source_invalid",
            f"Seed source is from a different Git repository: {source}",
            retryable=False,
            hint="Use another worktree from this repository as --seed-from.",
        )

    source_godot = source / ".godot"
    if _directory_has_entries(source_godot):
        _copy_cache_tree(source_godot, target / ".godot", dry_run=dry_run)
    else:
        print(f"Seed source has no warm Godot cache; skipping: {source_godot}")

    source_api_cache = source / "tools/.cache"
    if not _pins_match(source, target):
        print("PokeAPI pins differ; not seeding tools/.cache from the source worktree.")
    elif _api_cache_complete(source):
        _copy_cache_tree(source_api_cache, target / "tools/.cache", dry_run=dry_run)
    else:
        print(f"Seed source has no complete PokeAPI cache; skipping: {source_api_cache}")


@contextmanager
def _setup_lock(common_git_dir: Path, timeout: float, *, dry_run: bool) -> Iterator[None]:
    lock_path = common_git_dir / "codex-worktree-setup.lock"
    if dry_run:
        print(f"Would acquire setup lock: {lock_path}")
        yield
        return
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        deadline = time.monotonic() + timeout
        announced = False
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not announced:
                    print(f"Another worktree setup is running; waiting for {lock_path}...")
                    announced = True
                if time.monotonic() >= deadline:
                    raise SetupError(
                        "setup_lock_timeout",
                        f"Timed out waiting {timeout:g}s for {lock_path}.",
                        retryable=True,
                        hint="Let the other worktree import finish, then re-run setup.",
                    )
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _modified_tracked_paths(root: Path) -> set[str]:
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "-z", "HEAD", "--"],
            cwd=root,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SetupError(
            "git_state_unreadable",
            f"Could not read tracked worktree state: {exc}",
            retryable=True,
            hint="Repair the Git worktree, then re-run setup.",
        ) from exc
    return {
        item.decode("utf-8", errors="surrogateescape")
        for item in result.stdout.split(b"\0")
        if item
    }


def _fingerprint_paths(root: Path, paths: set[str]) -> dict[str, str]:
    fingerprints: dict[str, str] = {}
    for relative in sorted(paths):
        path = root / relative
        if path.is_symlink():
            payload = os.readlink(path).encode("utf-8", errors="surrogateescape")
            fingerprints[relative] = "symlink:" + hashlib.sha256(payload).hexdigest()
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            executable = bool(path.stat().st_mode & 0o111)
            fingerprints[relative] = f"file:{int(executable)}:{digest.hexdigest()}"
        else:
            fingerprints[relative] = "missing"
    return fingerprints


def _tracked_state(root: Path) -> dict[str, str]:
    return _fingerprint_paths(root, _modified_tracked_paths(root))


def changed_tracked_state(
    before: dict[str, str], after: dict[str, str]
) -> list[str]:
    return sorted(
        path
        for path in before.keys() | after.keys()
        if before.get(path) != after.get(path)
    )


def _prepare_pokeapi_cache(root: Path, *, dry_run: bool) -> None:
    if _pinned_api_cache_ready(root):
        print("Pinned PokeAPI cache: ready")
        return
    _run(
        [sys.executable, "tools/import_pokeapi.py", "--fetch-pinned"],
        cwd=root,
        dry_run=dry_run,
        code="pokeapi_cache_fetch_failed",
        hint="Check network access and tools/api_data_pin.json, then re-run setup.",
    )
    if not dry_run and not _api_cache_complete(root):
        raise SetupError(
            "pokeapi_cache_incomplete",
            f"Pinned cache is still incomplete after fetch: {root / POKEAPI_SENTINEL}",
            retryable=True,
            hint="Remove tools/.cache/api-data and re-run setup_worktree.py.",
        )
    if not dry_run:
        (root / POKEAPI_STAMP).write_text(_pin_sha(root) + "\n", encoding="utf-8")
        print("Pinned PokeAPI cache: repaired and stamped")


def _import_resources(
    root: Path, godot_bin: str, *, timeout: float, dry_run: bool
) -> None:
    _run(
        [godot_bin, "--quiet", "--headless", "--path", str(root), "--import"],
        cwd=root,
        timeout=timeout,
        dry_run=dry_run,
        code="godot_import_failed",
        hint="Inspect the Godot import error, fix it, and re-run this setup command before testing.",
    )


def _run_static_checks(root: Path, *, dry_run: bool) -> None:
    for tool in STATIC_CHECKS:
        _run(
            [sys.executable, f"tools/{tool}"],
            cwd=root,
            dry_run=dry_run,
            code="static_preflight_failed",
            retryable=False,
            hint=f"Fix the reported {tool} findings, then re-run setup with --check.",
        )


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot-bin",
        default=os.environ.get("GODOT_BIN", DEFAULT_GODOT_BIN),
        help="Godot 4.6.1 binary (default: GODOT_BIN or the macOS app path)",
    )
    parser.add_argument(
        "--seed-from",
        metavar="WORKTREE",
        help="optionally clone missing .godot and pinned tools/.cache from another worktree",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help=(
            "local Cursor/Codex hook: verify Python, Godot, Git, and cache safety "
            "without copying/fetching caches, importing resources, or taking the "
            "repository-wide setup lock"
        ),
    )
    parser.add_argument(
        "--skip-cache",
        action="store_true",
        help="do not fetch a missing pinned PokeAPI cache",
    )
    parser.add_argument(
        "--skip-import", action="store_true", help="do not run the Godot resource import"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="run the four canonical static checks after setup",
    )
    parser.add_argument(
        "--import-timeout",
        type=float,
        default=3000,
        help="Godot import timeout in seconds (default: 3000)",
    )
    parser.add_argument(
        "--lock-timeout",
        type=float,
        default=3600,
        help="wait limit for another worktree setup in seconds (default: 3600)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print mutating commands without running them"
    )
    args = parser.parse_args(argv)
    if args.quick and args.seed_from:
        parser.error("--quick cannot be combined with --seed-from")
    if args.quick:
        args.skip_cache = True
        args.skip_import = True
    if args.import_timeout <= 0 or args.lock_timeout <= 0:
        parser.error("timeouts must be greater than zero")
    return args


def run(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    root = _worktree_root(ROOT)
    if root != ROOT:
        raise SetupError(
            "git_worktree_invalid",
            f"Script root {ROOT} does not match Git worktree root {root}.",
            retryable=False,
            hint="Run the setup script from an intact repository worktree.",
        )
    print(f"Worktree: {root}")
    before = _tracked_state(root)
    godot_bin = _check_versions(args.godot_bin)
    _refuse_shared_cache_links(root)

    operation_error: SetupError | None = None

    def _prepare() -> None:
        nonlocal operation_error
        try:
            if args.seed_from:
                _seed_from_worktree(args.seed_from, root, dry_run=args.dry_run)
            if not args.skip_cache:
                _prepare_pokeapi_cache(root, dry_run=args.dry_run)
            else:
                print("Pinned PokeAPI cache: skipped by request")
            if not args.skip_import:
                _import_resources(
                    root, godot_bin, timeout=args.import_timeout, dry_run=args.dry_run
                )
            else:
                print("Godot resource import: skipped by request")
        except SetupError as exc:
            operation_error = exc

    serialized_work = bool(args.seed_from or not args.skip_cache or not args.skip_import)
    if serialized_work:
        with _setup_lock(_common_git_dir(root), args.lock_timeout, dry_run=args.dry_run):
            _prepare()
    else:
        print("Repository setup lock: not needed (cache and import work skipped)")
        _prepare()

    if not args.dry_run:
        after = _tracked_state(root)
        changed = changed_tracked_state(before, after)
        if changed:
            rendered = "\n".join(f"  - {path}" for path in changed)
            raise SetupError(
                "tracked_files_changed",
                "Setup changed tracked working-tree bytes; nothing was reverted:\n" + rendered,
                retryable=False,
                hint="Inspect and resolve the listed tracked changes before continuing development.",
            )
    if operation_error is not None:
        raise operation_error

    if args.check:
        _run_static_checks(root, dry_run=args.dry_run)

    print("Worktree setup complete." if not args.dry_run else "Dry run complete; no setup writes ran.")
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        return run(argv)
    except SetupError as exc:
        print(f"setup_worktree: {exc.detail}", file=sys.stderr)
        print(json.dumps(exc.envelope(), sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
