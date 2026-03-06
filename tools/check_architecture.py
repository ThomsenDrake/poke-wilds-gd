from __future__ import annotations

from pathlib import Path
import re
import sys

from legibility_lib import derive_layer, format_issues, relative_path, scene_files, script_files

SCRIPT_ALLOWED = {
    "app": {"app", "runtime", "ui", "core"},
    "runtime": {"runtime", "domain", "data", "core"},
    "ui": {"ui", "runtime", "core"},
    "domain": {"domain", "core"},
    "data": {"data", "core"},
    "core": {"core"},
}
SCENE_ALLOWED = {
    "app": {"app", "runtime", "ui"},
    "ui": {"ui"},
}
SCRIPT_LIMITS = {"app": 220, "ui": 220}
DEFAULT_SCRIPT_LIMIT = 320
SCENE_LIMIT = 250
RESOURCE_RE = re.compile(r'res://[^"\')\s]+')
SCENE_PATH_RE = re.compile(r'path="(res://[^"]+)"')


def run(root: Path | None = None) -> list[str]:
    root = root or Path(__file__).resolve().parents[1]
    issues: list[str] = []

    for path in script_files(root):
        rel = relative_path(path, root)
        source_layer = derive_layer(rel)
        if source_layer is None:
            issues.append(f"Script path is outside the allowed layer layout: {rel}")
            continue
        line_count = len(path.read_text(encoding="utf-8").splitlines())
        max_lines = SCRIPT_LIMITS.get(source_layer, DEFAULT_SCRIPT_LIMIT)
        if line_count > max_lines:
            issues.append(f"Script exceeds line budget ({line_count}>{max_lines}): {rel}")
        for target in RESOURCE_RE.findall(path.read_text(encoding="utf-8")):
            target_rel = target.replace("res://", "", 1)
            target_layer = derive_layer(target_rel)
            if target_layer is None:
                continue
            if target_layer not in SCRIPT_ALLOWED[source_layer]:
                issues.append(f"Forbidden script dependency {rel} -> {target_rel}")

    for path in scene_files(root):
        rel = relative_path(path, root)
        source_layer = derive_layer(rel)
        if source_layer is None:
            issues.append(f"Scene path is outside the allowed layer layout: {rel}")
            continue
        line_count = len(path.read_text(encoding="utf-8").splitlines())
        if line_count > SCENE_LIMIT:
            issues.append(f"Scene exceeds line budget ({line_count}>{SCENE_LIMIT}): {rel}")
        for match in SCENE_PATH_RE.findall(path.read_text(encoding="utf-8")):
            target_rel = match.replace("res://", "", 1)
            target_layer = derive_layer(target_rel)
            if target_layer is None:
                continue
            if target_layer not in SCENE_ALLOWED[source_layer]:
                issues.append(f"Forbidden scene dependency {rel} -> {target_rel}")

    return issues


def main() -> int:
    issues = run()
    if issues:
        print("Architecture check failed:")
        print(format_issues(issues))
        return 1
    print("Architecture check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
