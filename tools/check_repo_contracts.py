from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import re
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
    the head_sha, godot_version, window, and renderer keys. Null values are
    allowed for fields only windowed runs can supply; an absent report is not
    an issue.
    """
    report_path = root / ".godot-smoke" / "playtest-report.json"
    if not report_path.exists():
        return []
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"playtest-report.json is unreadable: {exc}"]
    if not isinstance(report, dict):
        return ["playtest-report.json is missing required stamp keys: head_sha, godot_version, window, renderer"]
    missing = [key for key in ("head_sha", "godot_version", "window", "renderer") if key not in report]
    if missing:
        return [f"playtest-report.json is missing required stamp keys: {', '.join(missing)}"]
    return []


BASELINE_DIR = "docs/generated/visual-baselines"
SIDECAR_SUFFIX = ".sidecar.json"
CORE_TOOLS_DIR = "tools"
# Third-party modules permitted in core tools. Deliberately EMPTY: the optional
# vision extra stays a SEPARATE non-core tool (see OPTIONAL_TOOL_EXEMPTIONS
# below) so the core verification tooling never needs a pip install. Keeping
# this set empty is a PINNED INVARIANT — a module-level third-party allowlist
# would defeat the leak guard in _check_import.
THIRD_PARTY_EXEMPTIONS: set[str] = set()

# Optional non-core tools exempt from the stdlib-only rule — the documented
# registry of exempt optional tools. vision_metrics.py is the ONE entry: the
# pyproject [project.optional-dependencies] vision = ["scikit-image"] extra.
# It degrades gracefully when scikit-image is absent (SKIMAGE_AVAILABLE guard)
# and NEVER gates CI. Core tools remain stdlib-only; add no other names here.
OPTIONAL_TOOL_EXEMPTIONS: set[str] = {"vision_metrics.py"}


def _is_battle_shot(stem: str) -> bool:
    """Shot naming convention is NN_name; battle shots are pinned to 09-12."""
    digits = ""
    for ch in stem:
        if ch.isdigit():
            digits += ch
        else:
            break
    return bool(digits) and 9 <= int(digits) <= 12


def region_coverage_issues(root: Path) -> list[str]:
    """Every committed baseline PNG must have a well-formed sibling sidecar with
    region entries (incl. canary_rect); battle shots (09-12) need a non-empty
    canary_rect and non-empty labels.

    Enforcement is progressive: the full "every baseline has a sidecar" rule only
    arms once the baseline dir contains at least one sidecar. That keeps the
    pre-feature tree (baselines committed before the sidecar writer +
    visual_sweep_update regeneration landed) from being a false red, while a
    PARTIAL sidecar set -- the real desync this guard exists to catch -- fails
    immediately.
    """
    baseline_dir = root / BASELINE_DIR
    if not baseline_dir.is_dir():
        return []
    baselines = sorted(baseline_dir.glob("*.png"))
    if not baselines:
        return []
    have_any_sidecar = any(baseline_dir.glob("*.png" + SIDECAR_SUFFIX))
    issues: list[str] = []
    for png in baselines:
        sidecar_name = png.name + SIDECAR_SUFFIX
        sidecar_path = baseline_dir / sidecar_name
        if not sidecar_path.exists():
            if have_any_sidecar:
                issues.append(
                    f"Baseline {png.name} has no sibling {sidecar_name} (sidecars are "
                    "partially committed — run visual_sweep_update to regenerate)")
            continue
        try:
            data = json.loads(sidecar_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            issues.append(f"Baseline sidecar {sidecar_name} is unreadable: {exc}")
            continue
        if not isinstance(data, dict):
            issues.append(f"Baseline sidecar {sidecar_name} is not a JSON object")
            continue
        for key in ("expected_regions", "canary_rect"):
            if key not in data:
                issues.append(f"Baseline sidecar {sidecar_name} is missing region key `{key}`")
        if _is_battle_shot(png.stem):
            canary = data.get("canary_rect")
            if not (isinstance(canary, list) and len(canary) == 4 and any(canary)):
                issues.append(f"Battle baseline sidecar {sidecar_name} must have a non-empty canary_rect")
            labels = data.get("labels")
            if not (isinstance(labels, list) and labels):
                issues.append(f"Battle baseline sidecar {sidecar_name} must have non-empty labels")
    return issues


def _check_import(tool_name: str, top: str, local_modules: set[str], issues: list[str]) -> None:
    if top in THIRD_PARTY_EXEMPTIONS:
        return
    if top in local_modules:
        # HARDENING: the local-sibling whitelist above would otherwise let a
        # core tool write `import vision_metrics` and smuggle the scikit-image
        # extra into the core path. A non-exempt core tool importing an exempt
        # optional tool's stem is therefore an issue, making the file-scoped
        # exemption auditable and leak-proof.
        if top + ".py" in OPTIONAL_TOOL_EXEMPTIONS and tool_name not in OPTIONAL_TOOL_EXEMPTIONS:
            issues.append(
                f"Core tool {tool_name} imports optional extra tool `{top}` (extras must not leak into core tools)")
        return
    if top not in sys.stdlib_module_names:
        issues.append(
            f"Core tool {tool_name} imports third-party module `{top}` (core tools are stdlib-only)")


def core_tools_stdlib_issues(root: Path) -> list[str]:
    """Core tools must be stdlib-only (no third-party imports). Local sibling
    tools (imported via importlib or a bare `from x import`) are whitelisted by
    filename; every other top-level module must be in sys.stdlib_module_names.
    Tools named in OPTIONAL_TOOL_EXEMPTIONS are the documented optional extras
    and are skipped entirely — their third-party imports are their own."""
    tools_dir = root / CORE_TOOLS_DIR
    if not tools_dir.is_dir():
        return []
    local_modules = {path.stem for path in tools_dir.glob("*.py")}
    issues: list[str] = []
    for tool in sorted(tools_dir.glob("*.py")):
        if tool.name in OPTIONAL_TOOL_EXEMPTIONS:
            continue  # documented optional extra (pyproject vision = [scikit-image])
        try:
            tree = ast.parse(tool.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            issues.append(f"Core tool {tool.name} is unparseable: {exc}")
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    _check_import(tool.name, alias.name.split(".")[0], local_modules, issues)
            elif isinstance(node, ast.ImportFrom) and not node.level and node.module:
                _check_import(tool.name, node.module.split(".")[0], local_modules, issues)
    return issues


def _load_tool(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Fixed 4-pixel RGBA fixture: p0 red +100, p1 red +5, p2 red+blue +200 (two
# channels on ONE pixel, so the index SET must count it once), p3 unchanged.
_SYNC_BUF_A = bytes([10, 10, 10, 255, 50, 50, 50, 255, 20, 20, 20, 255, 5, 5, 5, 255])
_SYNC_BUF_B = bytes([110, 10, 10, 255, 55, 50, 50, 255, 220, 20, 220, 255, 5, 5, 5, 255])
# Tolerance -> expected changed-pixel count for the fixture above.
_SYNC_EXPECTED = {0: 3, 1: 3, 8: 2, 255: 0}


def region_diff_backstop_sync_issues(root: Path) -> list[str]:
    """Pin the region diff's verbatim changed-pixel builder to visual_diff's
    untouched original. `visual_region_diff.changed_pixel_set` is a line-for-line
    copy of `visual_diff.changed_pixel_count` (returning the index SET instead of
    its length); nothing else ties the two together, so a future change to
    visual_diff's per-channel/tolerance semantics would make the recomputed
    global backstop silently disagree with the in-engine number. Run both on a
    fixed fixture and assert len(set) == count at every tolerance the gate uses.
    """
    tools_dir = root / CORE_TOOLS_DIR
    visual_diff_path = tools_dir / "visual_diff.py"
    region_diff_path = tools_dir / "visual_region_diff.py"
    if not visual_diff_path.exists() or not region_diff_path.exists():
        return []
    try:
        visual_diff = _load_tool("visual_diff", visual_diff_path)
        region_diff = _load_tool("visual_region_diff", region_diff_path)
    except Exception as exc:  # a load failure is a contract failure, not a skip
        return [f"cannot load the diff tools for the backstop sync check: {exc}"]
    issues: list[str] = []
    for tolerance, expected in _SYNC_EXPECTED.items():
        count = visual_diff.changed_pixel_count(_SYNC_BUF_A, _SYNC_BUF_B, tolerance)
        set_size = len(region_diff.changed_pixel_set(_SYNC_BUF_A, _SYNC_BUF_B, tolerance))
        if count != expected:
            issues.append(
                f"visual_diff.changed_pixel_count fixture drift at tolerance {tolerance}: "
                f"got {count}, expected {expected} (fixture no longer exercises the builder)")
        if set_size != count:
            issues.append(
                f"region diff backstop desync at tolerance {tolerance}: "
                f"len(changed_pixel_set) == {set_size} but changed_pixel_count == {count}")
    return issues


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
    issues.extend(region_coverage_issues(root))
    issues.extend(core_tools_stdlib_issues(root))
    issues.extend(region_diff_backstop_sync_issues(root))
    issues.extend(art_anchor_issues(root))
    issues.extend(rubric_question_inventory_issues(root))
    issues.extend(miss_postmortem_issues(root))

    return issues


def art_anchor_issues(root: Path) -> list[str]:
    """Source-art anchor RED gate (docs/registry/art-anchors.toml): schema
    violations + art_sha256 pin + recompute==stage_rect. Loaded from
    tools/check_art_anchors.py via the sanctioned importlib pattern so the
    geometry/derivation stays single-sourced in tools/art_geometry.py. An absent
    registry returns [] (the rule arms once the file exists, mirroring
    region_coverage_issues' progressive arming)."""
    tool_path = Path(__file__).resolve().with_name("check_art_anchors.py")
    if not tool_path.exists():
        return []
    checker = _load_tool("check_art_anchors", tool_path)
    return checker.art_anchor_issues(root)


def rubric_question_inventory_issues(root: Path) -> list[str]:
    """RED backstop pinning the rubric question inventory (docs/references/
    vision-review-rubric.md) that the Lane-4 rubric-coverage ledger is built on:
    a rubric edit cannot silently empty a shot-group's question list or rotate a
    question id out of its answerer mapping. Delegates to the domain logic in
    tools/vision_review.py (the sanctioned importlib pattern; the parser +
    EXPECTED_QUESTION_COUNTS pin + QUESTION_ANSWERERS fingerprints stay single-
    sourced there). Distinct from the coverage GAP (unanswered questions), which is
    advisory and never red."""
    tool_path = Path(__file__).resolve().with_name("vision_review.py")
    rubric_path = root / "docs" / "references" / "vision-review-rubric.md"
    if not tool_path.exists() or not rubric_path.exists():
        return []
    try:
        vision_review = _load_tool("vision_review", tool_path)
        rubric_text = rubric_path.read_text(encoding="utf-8")
    except (OSError, RuntimeError):
        return []
    return vision_review.rubric_inventory_issues(rubric_text)


MISS_LEDGER_REL = "docs/generated/miss-postmortems.json"
ART_ANCHORS_REL = "docs/registry/art-anchors.toml"


def _load_miss_ledger(root: Path) -> tuple[list | None, list[str]]:
    """Parse the miss-postmortem ledger with REFUSE-ON-UNREADABLE semantics
    (mirrors graduation_ledger's LedgerUnreadable): a present-but-corrupt
    ledger is a HARD error, never reset to empty — tracked evidence survives.
    An ABSENT ledger returns (None, []) so the rule arms progressively once the
    file lands (mirrors region_coverage_issues' have_any_sidecar)."""
    ledger_path = root / MISS_LEDGER_REL
    if not ledger_path.exists():
        return None, []
    try:
        data = json.loads(ledger_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return None, [f"{MISS_LEDGER_REL} is present but unreadable "
                      f"(refuse-on-unreadable; never reset to empty): {exc}"]
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        return None, [f"{MISS_LEDGER_REL} is corrupt: expected a JSON object with an "
                      "`entries` list (refuse-on-unreadable; never reset to empty)"]
    return data["entries"], []


def _mechanism_targets(text: str) -> tuple[list[str], list[str]]:
    """Resolution targets named by a mechanism_added string: repo-relative file
    paths (contain '/', final segment has an extension) and art-anchor ids
    (bare lowercase `scene/name` slugs, no extension). res:// URLs name
    submodule ART bytes (policed by the art_sha256 pin), not repo artifacts."""
    paths: list[str] = []
    anchor_ids: list[str] = []
    for token in re.findall(r"[A-Za-z0-9_./-]+", text):
        if "/" not in token or token.startswith("//"):
            continue  # "//…" is the tail of a res:// URL, not a repo path
        if "." in token.rsplit("/", 1)[-1]:
            if ("res://" + token) not in text and ("res://" + token.lstrip("/")) not in text:
                paths.append(token)
        elif re.fullmatch(r"[a-z][a-z0-9_]*/[a-z][a-z0-9_]*", token):
            anchor_ids.append(token)
    return paths, anchor_ids


def miss_postmortem_issues(root: Path) -> list[str]:
    """The BOTH-DIRECTIONS backstop claimed by docs/references/miss-postmortem-
    protocol.md § Enforcement and RELIABILITY.md § Miss-postmortem protocol:

      - every recorded mechanism_added MUST resolve to a landed check — each
        named repo path exists and each named art-anchor id is in the registry;
        a claimed-but-missing mechanism is RED;
      - every EXECUTED plant's revert_proof MUST hold — the plant scope's
        recorded revert sha256 pins still match the tree; an un-reverted (or
        later re-perturbed) plant scope is RED, like a broken internal link.
        The pins are recorded at the byte-identical revert, so the check is
        position-independent: it holds mid-slice (uncommitted) exactly as
        post-commit, where a live `git status` would false-red on unrelated
        in-flight edits to the scope files.

    Refuse-on-unreadable applies (a corrupt ledger is RED, never emptied).
    Incomplete entries are ADVISORY (miss_postmortem_advisories), never a wave
    of false reds — the house progressive-arming style."""
    entries, hard = _load_miss_ledger(root)
    if entries is None:
        return hard
    issues: list[str] = []
    # Art-anchor ids for the registry half of mechanism resolution; the rule
    # arms once the registry exists (a mechanism that names ids without the
    # registry is caught by the missing-path rule on the registry file itself).
    registry_ids: set[str] | None = None
    if (root / ART_ANCHORS_REL).exists():
        try:
            geometry = _load_tool("art_geometry",
                                  Path(__file__).resolve().with_name("art_geometry.py"))
            registry_ids = {str(a.get("id")) for a in geometry.load_registry(root)
                            if isinstance(a, dict)}
        except Exception as exc:  # a load failure is a contract failure, not a skip
            issues.append(f"miss-postmortem backstop cannot load {ART_ANCHORS_REL}: {exc}")
    for entry in entries:
        if not isinstance(entry, dict):
            issues.append(f"{MISS_LEDGER_REL}: an entry is not a JSON object")
            continue
        mid = entry.get("id") or "<no-id>"
        mechanism = entry.get("mechanism_added")
        if isinstance(mechanism, str) and mechanism.strip():
            paths, anchor_ids = _mechanism_targets(mechanism)
            for rel in paths:
                if not (root / rel).exists():
                    issues.append(
                        f"miss-postmortem `{mid}`: mechanism_added names a missing artifact "
                        f"`{rel}` (claimed-but-missing mechanism is RED; land it or correct the entry)")
            if registry_ids is not None:
                for aid in anchor_ids:
                    if aid not in registry_ids:
                        issues.append(
                            f"miss-postmortem `{mid}`: mechanism_added names art-anchor `{aid}` "
                            f"absent from {ART_ANCHORS_REL} (claimed-but-missing mechanism is RED)")
        plant = entry.get("plant")
        if isinstance(plant, dict) and plant.get("executed") is True:
            scope = plant.get("revert_scope")
            if not (isinstance(scope, dict) and scope):
                continue  # advisory: executed without a verifiable scope
            for rel, pin in scope.items():
                target = root / str(rel)
                if not target.exists():
                    issues.append(
                        f"miss-postmortem `{mid}`: executed plant revert_proof broken — scope "
                        f"file `{rel}` is missing (un-reverted plant is RED; re-run the plant "
                        "and re-stamp the ledger)")
                    continue
                actual = hashlib.sha256(target.read_bytes()).hexdigest()
                if str(pin) != actual:
                    issues.append(
                        f"miss-postmortem `{mid}`: executed plant revert_proof broken — `{rel}` "
                        f"drifted from the byte-identical revert (pin {str(pin)[:12]}… vs tree "
                        f"{actual[:12]}…); the plant scope was re-perturbed (RED; re-run the "
                        "plant and re-stamp the ledger)")
    return issues


def miss_postmortem_advisories(root: Path | None = None) -> list[str]:
    """Counted incompleteness for the miss-postmortem ledger (never fails the
    gate; surfaced on stderr like the art-anchor advisories): an entry missing
    its silence enumeration or its mechanism, an executed plant without a
    verifiable revert_scope, or a plant never executed (the entry counts as
    open/incomplete). Advisory, matching the protocol's progressive arming."""
    root = root or Path(__file__).resolve().parents[1]
    entries, hard = _load_miss_ledger(root)
    if entries is None or hard:
        return []
    advisories: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        mid = entry.get("id") or "<no-id>"
        missing = [key for key in ("classes_silent", "mechanism_added") if not entry.get(key)]
        if missing:
            advisories.append(
                f"miss-postmortem `{mid}` is incomplete (advisory): missing {', '.join(missing)}")
        plant = entry.get("plant")
        if not isinstance(plant, dict):
            advisories.append(f"miss-postmortem `{mid}` is incomplete (advisory): no plant block")
        elif plant.get("executed") is True:
            if not (isinstance(plant.get("revert_scope"), dict) and plant.get("revert_scope")):
                advisories.append(
                    f"miss-postmortem `{mid}`: executed plant records no verifiable revert_scope "
                    "(advisory; record path→sha256 pins at the byte-identical revert so the "
                    "backstop can hold it)")
        else:
            advisories.append(
                f"miss-postmortem `{mid}`: plant not executed (advisory; the entry counts as "
                "open/incomplete, not closed)")
    return advisories


def main() -> int:
    issues = run()
    for advisory in miss_postmortem_advisories():
        print(f"advisory: {advisory}", file=sys.stderr)
    if issues:
        print("Repo contract check failed:")
        print(format_issues(issues))
        return 1
    print("Repo contract check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
