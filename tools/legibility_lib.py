from __future__ import annotations

from datetime import date, timedelta
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]
DOCS_ROOT = ROOT / "docs"
METADATA_FIELDS = [
    "Status",
    "Last verified",
    "Review cadence days",
    "Source paths",
]
VALID_LAYERS = {"app", "runtime", "domain", "data", "ui", "core"}
REQUIRED_DOC_DIRS = [
    "docs/design-docs",
    "docs/product-specs",
    "docs/references",
    "docs/exec-plans/active",
    "docs/exec-plans/completed",
    "docs/generated",
    "docs/registry",
]
REQUIRED_DOC_FILES = [
    "README.md",
    "AGENTS.md",
    "ARCHITECTURE.md",
    "docs/QUALITY_SCORE.md",
    "docs/RELIABILITY.md",
    "docs/tech-debt-tracker.md",
    "docs/registry/subsystems.toml",
]
TRACE_EVENTS_DOC = "docs/references/trace-events.md"


def repo_root() -> Path:
    return ROOT


def relative_path(path: Path, root: Path = ROOT) -> str:
    return path.relative_to(root).as_posix()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_registry(root: Path = ROOT) -> list[dict]:
    registry_path = root / "docs/registry/subsystems.toml"
    data = tomllib.loads(read_text(registry_path))
    return list(data.get("subsystems", []))


def registry_names(registry: list[dict]) -> list[str]:
    return [str(entry["name"]) for entry in registry]


def registry_paths(registry: list[dict]) -> set[str]:
    covered: set[str] = set()
    for entry in registry:
        covered.update(str(path) for path in entry.get("code_paths", []))
        covered.update(str(path) for path in entry.get("scene_paths", []))
    return covered


def docs_markdown(root: Path = ROOT) -> list[Path]:
    return sorted((root / "docs").rglob("*.md"))


def parse_metadata(path: Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for line in read_text(path).splitlines():
        if not line.strip():
            break
        if ":" not in line:
            break
        key, value = line.split(":", 1)
        metadata[key.strip()] = value.strip()
    return metadata


def source_paths_from_metadata(metadata: dict[str, str]) -> list[str]:
    raw = metadata.get("Source paths", "")
    if not raw:
        return []
    return [item.strip() for item in raw.split(",") if item.strip()]


def metadata_due(metadata: dict[str, str], today: date | None = None) -> bool:
    today = today or date.today()
    status = metadata.get("Status", "").lower()
    if status == "generated":
        return False
    verified = date.fromisoformat(metadata["Last verified"])
    cadence = int(metadata["Review cadence days"])
    return verified + timedelta(days=cadence) < today


def internal_links(path: Path) -> list[str]:
    targets: list[str] = []
    for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", read_text(path)):
        target = match.group(1).strip()
        if not target or target.startswith(("http://", "https://", "mailto:")):
            continue
        target = target.split("#", 1)[0]
        if target:
            targets.append(target)
    return targets


def resolve_link(source: Path, target: str, root: Path = ROOT) -> Path:
    if target.startswith("/"):
        return Path(target)
    return (source.parent / target).resolve()


def code_and_scene_files(root: Path = ROOT) -> list[Path]:
    files: list[Path] = []
    for folder in ("scripts", "scenes"):
        files.extend(path for path in (root / folder).rglob("*") if path.suffix in {".gd", ".tscn"})
    return sorted(files)


def derive_layer(rel_path: str) -> str | None:
    parts = Path(rel_path).parts
    if len(parts) < 2:
        return None
    if parts[0] == "scripts" and parts[1] in VALID_LAYERS:
        return parts[1]
    if parts[0] == "scenes" and parts[1] in {"app", "ui"}:
        return parts[1]
    return None


def scene_files(root: Path = ROOT) -> list[Path]:
    return sorted((root / "scenes").rglob("*.tscn"))


def script_files(root: Path = ROOT) -> list[Path]:
    return sorted((root / "scripts").rglob("*.gd"))


def trace_event_docs(root: Path = ROOT) -> set[str]:
    events: set[str] = set()
    trace_doc = root / TRACE_EVENTS_DOC
    for line in read_text(trace_doc).splitlines():
        if not line.startswith("| `"):
            continue
        columns = [segment.strip() for segment in line.strip().strip("|").split("|")]
        if columns:
            events.add(columns[0].strip("`"))
    return events


def trace_literals(root: Path = ROOT) -> str:
    return "\n".join(read_text(path) for path in script_files(root))


def format_issues(issues: list[str]) -> str:
    return "\n".join(f"- {issue}" for issue in issues)
