from __future__ import annotations

from pathlib import Path
import argparse
import os
import subprocess
import sys

from legibility_lib import format_issues, load_registry


def _git(repo_root: Path, *args: str) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def _changed_files(repo_root: Path, base: str | None) -> set[str]:
    changed: set[str] = set()
    if base:
        changed.update(_git(repo_root, "diff", "--name-only", f"{base}...HEAD"))
    else:
        changed.update(_git(repo_root, "diff", "--name-only", "HEAD"))
    changed.update(_git(repo_root, "ls-files", "--others", "--exclude-standard"))
    return changed


def run(root: Path | None = None, base: str | None = None) -> list[str]:
    root = root or Path(__file__).resolve().parents[1]
    base = base or os.environ.get("GITHUB_BASE_REF")
    issues: list[str] = []

    changed = _changed_files(root, base)
    code_changes = {path for path in changed if path.endswith(".gd") or path.endswith(".tscn")}
    if not code_changes:
        return issues

    registry = load_registry(root)
    changed_docs = set(changed)
    for subsystem in registry:
        touched_paths = set(subsystem.get("code_paths", [])) | set(subsystem.get("scene_paths", []))
        if not (touched_paths & code_changes):
            continue
        required_docs = {
            "docs/registry/subsystems.toml",
            str(subsystem["spec_doc"]),
            "docs/QUALITY_SCORE.md",
            "docs/RELIABILITY.md",
        }
        missing = sorted(required_docs - changed_docs)
        if missing:
            issues.append(
                f"Subsystem `{subsystem['name']}` has code changes but is missing required doc updates: {', '.join(missing)}"
            )
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Optional git base ref for diffing.")
    args = parser.parse_args()

    issues = run(base=args.base)
    if issues:
        print("Change contract check failed:")
        print(format_issues(issues))
        return 1
    print("Change contract check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
