from __future__ import annotations

from pathlib import Path
import sys

from legibility_lib import format_issues, load_registry, registry_names


def _parse_quality_rows(path: Path) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("| `"):
            continue
        columns = [segment.strip() for segment in line.strip().strip("|").split("|")]
        if len(columns) < 8:
            continue
        rows[columns[0].strip("`")] = columns
    return rows


def run(root: Path | None = None) -> list[str]:
    root = root or Path(__file__).resolve().parents[1]
    issues: list[str] = []

    registry = load_registry(root)
    rows = _parse_quality_rows(root / "docs/QUALITY_SCORE.md")
    for name in registry_names(registry):
        if name not in rows:
            issues.append(f"QUALITY_SCORE.md is missing a row for subsystem `{name}`.")
            continue
        row = rows[name]
        for column_name, index in {
            "legibility": 3,
            "validation": 4,
            "architecture": 5,
            "product completeness": 6,
        }.items():
            try:
                value = int(row[index])
            except ValueError:
                issues.append(f"Subsystem `{name}` has a non-numeric {column_name} score.")
                continue
            if value < 0 or value > 3:
                issues.append(f"Subsystem `{name}` has an out-of-range {column_name} score: {value}.")
    return issues


def main() -> int:
    issues = run()
    if issues:
        print("Quality docs check failed:")
        print(format_issues(issues))
        return 1
    print("Quality docs check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
