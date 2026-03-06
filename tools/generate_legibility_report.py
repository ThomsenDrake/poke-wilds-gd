from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import argparse
import sys

import check_architecture
import check_quality_docs
import check_repo_contracts


def generate(output_path: Path) -> int:
    checks = {
        "repo_contracts": check_repo_contracts.run(),
        "architecture": check_architecture.run(),
        "quality_docs": check_quality_docs.run(),
    }
    findings = sum(len(items) for items in checks.values())
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")

    lines = [
        "Status: generated",
        f"Last verified: {datetime.now(timezone.utc).date().isoformat()}",
        "Review cadence days: 7",
        "Source paths: tools/generate_legibility_report.py, tools/check_repo_contracts.py, tools/check_architecture.py, tools/check_quality_docs.py",
        "",
        "# Legibility Report",
        "",
        f"- Generated at: {timestamp}",
        f"- Total findings: {findings}",
        "",
    ]

    for check_name, issues in checks.items():
        lines.append(f"## {check_name.replace('_', ' ').title()}")
        lines.append("")
        if not issues:
            lines.append("No findings.")
            lines.append("")
            continue
        for issue in issues:
            lines.append(f"- {issue}")
        lines.append("")

    output_path.write_text("\n".join(lines), encoding="utf-8")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="Where to write the markdown report.")
    parser.add_argument("--fail-on-findings", action="store_true")
    args = parser.parse_args()

    findings = generate(Path(args.output))
    if findings and args.fail_on_findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
