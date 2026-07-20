from __future__ import annotations

import json
from pathlib import Path
import sys

from legibility_lib import (
    METADATA_FIELDS,
    REQUIRED_DOC_DIRS,
    REQUIRED_DOC_FILES,
    code_and_scene_files,
    derive_layer,
    docs_markdown,
    format_issues,
    internal_links,
    load_registry,
    metadata_due,
    parse_metadata,
    relative_path,
    registry_paths,
    resolve_link,
    source_paths_from_metadata,
    trace_event_docs,
    trace_literals,
)


def report_stamp_issues(root: Path) -> list[str]:
    """Validate the playtest-report stamp schema (freshness-refusal hook).

    Presence-only: when .godot-smoke/playtest-report.json exists it must carry
    the head_sha and godot_version keys. Null values are allowed for fields
    only windowed runs can supply; an absent report is not an issue.
    """
    report_path = root / ".godot-smoke" / "playtest-report.json"
    if not report_path.exists():
        return []
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"playtest-report.json is unreadable: {exc}"]
    if not isinstance(report, dict):
        return ["playtest-report.json is missing required stamp keys: head_sha, godot_version"]
    missing = [key for key in ("head_sha", "godot_version") if key not in report]
    if missing:
        return [f"playtest-report.json is missing required stamp keys: {', '.join(missing)}"]
    return []


def run(root: Path | None = None) -> list[str]:
    root = root or Path(__file__).resolve().parents[1]
    issues: list[str] = []

    for rel in REQUIRED_DOC_DIRS:
        if not (root / rel).is_dir():
            issues.append(f"Missing required docs directory: {rel}")

    for rel in REQUIRED_DOC_FILES:
        if not (root / rel).exists():
            issues.append(f"Missing required repo artifact: {rel}")

    agents_path = root / "AGENTS.md"
    if agents_path.exists():
        line_count = len(agents_path.read_text(encoding="utf-8").splitlines())
        if line_count > 120:
            issues.append(f"AGENTS.md is too long ({line_count} lines); keep it under 120 lines.")

    registry = load_registry(root)
    covered_paths = registry_paths(registry)
    documented_events = trace_event_docs(root)
    code_text = trace_literals(root)

    for subsystem in registry:
        name = subsystem.get("name", "<unnamed>")
        for key in (
            "layer",
            "code_paths",
            "scene_paths",
            "spec_doc",
            "validation_commands",
            "required_trace_events",
            "quality_bucket",
        ):
            if key not in subsystem:
                issues.append(f"Subsystem `{name}` is missing required key `{key}`.")
        layer = str(subsystem.get("layer", ""))
        if layer and layer not in {"app", "runtime", "domain", "data", "ui", "core"}:
            issues.append(f"Subsystem `{name}` declares unknown layer `{layer}`.")
        for rel in list(subsystem.get("code_paths", [])) + list(subsystem.get("scene_paths", [])):
            if not (root / rel).exists():
                issues.append(f"Subsystem `{name}` references a missing path: {rel}")
        spec_doc = subsystem.get("spec_doc")
        if spec_doc and not (root / str(spec_doc)).exists():
            issues.append(f"Subsystem `{name}` references a missing spec doc: {spec_doc}")
        if not subsystem.get("validation_commands"):
            issues.append(f"Subsystem `{name}` must declare at least one validation command.")
        for event_name in subsystem.get("required_trace_events", []):
            if event_name not in documented_events:
                issues.append(f"Required trace event `{event_name}` for `{name}` is missing from docs/references/trace-events.md.")
            if f'"{event_name}"' not in code_text and f"'{event_name}'" not in code_text:
                issues.append(f"Required trace event `{event_name}` for `{name}` does not appear in runtime code.")

    for path in code_and_scene_files(root):
        rel = relative_path(path, root)
        if derive_layer(rel) is None:
            issues.append(f"File is outside the allowed layer layout: {rel}")
        if rel not in covered_paths:
            issues.append(f"Registry coverage is missing for: {rel}")

    for path in docs_markdown(root):
        rel = relative_path(path, root)
        metadata = parse_metadata(path)
        missing_fields = [field for field in METADATA_FIELDS if field not in metadata]
        if missing_fields:
            issues.append(f"Doc metadata missing for {rel}: {', '.join(missing_fields)}")
            continue
        try:
            if metadata_due(metadata):
                issues.append(f"Doc is stale and must be re-verified: {rel}")
        except Exception as exc:
            issues.append(f"Doc metadata is invalid for {rel}: {exc}")
        for source in source_paths_from_metadata(metadata):
            if not (root / source).exists():
                issues.append(f"Doc {rel} references a missing source path: {source}")
        for target in internal_links(path):
            if not resolve_link(path, target, root).exists():
                issues.append(f"Broken internal link in {rel}: {target}")

    issues.extend(report_stamp_issues(root))

    return issues


def main() -> int:
    issues = run()
    if issues:
        print("Repo contract check failed:")
        print(format_issues(issues))
        return 1
    print("Repo contract check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
