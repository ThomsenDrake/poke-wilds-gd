from __future__ import annotations

import ast
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import socket
import sys
import tempfile
import tomllib

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


# Build-phased spec exemption: a FROZEN multi-build spec (docs/product-specs/world-depth.md)
# lists its whole-phase source set in the "Source paths" metadata up front, but the later
# builds' files legitimately do not exist yet. An entry explicitly marked "(Build N)" (N >= 2)
# is exempt from the missing-path rule until its build lands; the stale-marker backstop below
# forces the marker OFF the moment the path exists, so the exemption can never outlive the gap.
BUILD_STAGED_SOURCE_MARKER = re.compile(r"^(.+?)\s*\(Build ([2-9]|\d{2,})\)$")


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

POKEAPI_CI_WORKFLOWS = (
    ".github/workflows/repo-contracts.yml",
    ".github/workflows/playtests-headless.yml",
)
POKEAPI_CACHE_KEY = "key: pokeapi-api-data-v2-${{ hashFiles('tools/api_data_pin.json') }}"
POKEAPI_FETCH_COMMAND = "run: python3 tools/import_pokeapi.py --fetch-pinned"
POKEAPI_CI_CONSUMERS = {
    ".github/workflows/repo-contracts.yml": "python3 tools/import_pokeapi.py --check",
    ".github/workflows/playtests-headless.yml": "python3 tools/verify_all.py --skip-windowed",
}

FEEDBACK_RELAY_DEPLOY_WORKFLOW = ".github/workflows/feedback-relay-deploy.yml"


def _workflow_step_blocks(text: str) -> list[list[str]]:
    """Return active lines for actual six-space GitHub Actions step blocks."""
    starts = [match.start() for match in re.finditer(r"(?m)^      - ", text)]
    blocks: list[list[str]] = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(text)
        lines = []
        for line in text[start:end].splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            lines.append(line.strip())
        blocks.append(lines)
    return blocks


def _active_yaml_text(text: str) -> str:
    """Remove YAML comments without treating hashes inside quotes as comments."""
    active_lines: list[str] = []
    for original_line in text.splitlines():
        line = original_line
        quote = ""
        escaped = False
        index = 0
        while index < len(line):
            char = line[index]
            if quote == '"':
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quote = ""
            elif quote == "'":
                if char == "'" and index + 1 < len(line) and line[index + 1] == "'":
                    index += 1
                elif char == "'":
                    quote = ""
            elif char in ('"', "'"):
                quote = char
            elif char == "#" and (index == 0 or line[index - 1].isspace()):
                line = line[:index]
                break
            index += 1
        active_lines.append(line.rstrip())
    return "\n".join(active_lines)


def _workflow_job_blocks(text: str) -> dict[str, list[str]]:
    """Return top-level job blocks keyed by job name, retaining duplicates."""
    jobs_at = text.find("\njobs:\n")
    if jobs_at < 0:
        return {}
    jobs_text = text[jobs_at + len("\njobs:\n"):]
    starts = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):(?:\n|$)", jobs_text))
    blocks: dict[str, list[str]] = {}
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(jobs_text)
        blocks.setdefault(match.group(1), []).append(jobs_text[match.start():end])
    return blocks


def pokeapi_ci_cache_issues(root: Path) -> list[str]:
    """Keep CI freshness checks tied to the committed PokeAPI pin.

    Actions caches are immutable.  The v2 key invalidates the one cache that
    the former ``--refresh`` step populated from a newer upstream revision,
    while the unconditional ``--fetch-pinned`` step repairs any restored
    directory before ``--check`` consumes it.
    """
    issues: list[str] = []
    for rel in POKEAPI_CI_WORKFLOWS:
        path = root / rel
        if not path.exists():
            issues.append(f"Missing PokeAPI CI workflow: {rel}")
            continue
        steps = _workflow_step_blocks(path.read_text(encoding="utf-8"))
        cache_steps = [
            index for index, lines in enumerate(steps)
            if "uses: actions/cache@v4" in lines and "path: tools/.cache" in lines
        ]
        fetch_steps = [
            index for index, lines in enumerate(steps) if POKEAPI_FETCH_COMMAND in lines
        ]
        consumer_command = POKEAPI_CI_CONSUMERS[rel]
        consumer_steps = [
            index for index, lines in enumerate(steps)
            if any(consumer_command in line for line in lines)
        ]

        if len(cache_steps) != 1:
            issues.append(f"{rel} must contain exactly one tools/.cache restore step")
        elif POKEAPI_CACHE_KEY not in steps[cache_steps[0]]:
            issues.append(f"{rel} must use the versioned pinned PokeAPI cache key")
        if len(fetch_steps) != 1:
            issues.append(f"{rel} must run --fetch-pinned before catalog freshness")
        elif any(line.startswith("if:") for line in steps[fetch_steps[0]]):
            issues.append(f"{rel} must run --fetch-pinned unconditionally after cache restore")
        if len(consumer_steps) != 1:
            issues.append(f"{rel} must contain exactly one pinned-cache consumer step")
        if len(cache_steps) == len(fetch_steps) == len(consumer_steps) == 1:
            if not cache_steps[0] < fetch_steps[0] < consumer_steps[0]:
                issues.append(
                    f"{rel} must order pinned cache restore -> --fetch-pinned -> consumer")
        if any("--refresh" in line for lines in steps for line in lines):
            issues.append(f"{rel} must never run --refresh in CI")
    return issues


def feedback_relay_deploy_issues(root: Path) -> list[str]:
    """Pin the relay's validate -> staging -> production deployment contract."""
    path = root / FEEDBACK_RELAY_DEPLOY_WORKFLOW
    if not path.exists():
        return [f"Missing feedback relay deployment workflow: {FEEDBACK_RELAY_DEPLOY_WORKFLOW}"]
    text = _active_yaml_text(path.read_text(encoding="utf-8"))
    issues: list[str] = []
    required = (
        "branches:\n      - main",
        '      - "services/feedback-relay/**"',
        "permissions:\n  contents: read",
        (
            "group: feedback-relay-${{ github.event_name == 'pull_request' && "
            "format('pr-{0}', github.event.pull_request.number) || github.ref }}"
        ),
        "cancel-in-progress: false",
        "run: npm ci",
        "run: npm run check",
        "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
        "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020",
        "npx wrangler deploy --dry-run --strict --keep-vars --env staging",
        'npx wrangler deploy --dry-run --strict --keep-vars --env=""',
        "environment: feedback-staging",
        "environment: feedback-production",
        "CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}",
        "CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}",
        "npx wrangler d1 migrations apply DB --remote --env staging",
        'npx wrangler d1 migrations apply DB --remote --env=""',
        "https://poke-wilds-feedback-relay-staging.drake-t.workers.dev/healthz",
        "https://poke-wilds-feedback-relay.drake-t.workers.dev/healthz",
    )
    for fragment in required:
        if fragment not in text:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} is missing deployment contract: {fragment}"
            )
    for action_ref in (
        "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
        "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020",
    ):
        if text.count(action_ref) != 3:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must pin {action_ref} in all three jobs"
            )

    if text.count('      - "services/feedback-relay/**"') != 2:
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must path-filter relay changes on push and pull_request"
        )
    deploy_if = (
        "if: github.event_name == 'push' || (github.event_name == 'workflow_dispatch' "
        "&& github.ref == 'refs/heads/main')"
    )
    if text.count(deploy_if) != 2:
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must deploy only a push or manual dispatch of main"
        )
    job_step_contracts = {
        "validate": {
            "Install from the lockfile": ("run: npm ci",),
            "Type-check and test the Worker": ("run: npm run check",),
            "Validate the staging deployment bundle": (
                "run: npx wrangler deploy --dry-run --strict --keep-vars --env staging",
            ),
            "Validate the production deployment bundle": (
                'run: npx wrangler deploy --dry-run --strict --keep-vars --env=""',
            ),
        },
        "deploy-staging": {
            "Install from the lockfile": ("run: npm ci",),
            "Apply staging D1 migrations": (
                "run: npx wrangler d1 migrations apply DB --remote --env staging",
            ),
            "Deploy staging Worker": (
                'run: npx wrangler deploy --strict --keep-vars --env staging --message "GitHub Actions ${GITHUB_SHA}"',
            ),
            "Verify staging health": (
                "run: |",
                'response="$(curl --fail-with-body --silent --show-error --retry 5 --retry-all-errors --retry-delay 2 https://poke-wilds-feedback-relay-staging.drake-t.workers.dev/healthz)"',
                'RESPONSE="$response" node -e \'const h=JSON.parse(process.env.RESPONSE); if (h.ok !== true || h.environment !== "staging" || h.report_schema !== 1) process.exit(1)\'',
            ),
        },
        "deploy-production": {
            "Install from the lockfile": ("run: npm ci",),
            "Apply production D1 migrations": (
                'run: npx wrangler d1 migrations apply DB --remote --env=""',
            ),
            "Deploy production Worker": (
                'run: npx wrangler deploy --strict --keep-vars --env="" --message "GitHub Actions ${GITHUB_SHA}"',
            ),
            "Verify production health": (
                "run: |",
                'response="$(curl --fail-with-body --silent --show-error --retry 5 --retry-all-errors --retry-delay 2 https://poke-wilds-feedback-relay.drake-t.workers.dev/healthz)"',
                'RESPONSE="$response" node -e \'const h=JSON.parse(process.env.RESPONSE); if (h.ok !== true || h.environment !== "production" || h.report_schema !== 1) process.exit(1)\'',
            ),
        },
    }
    job_blocks = _workflow_job_blocks(text)
    if set(job_blocks) != set(job_step_contracts):
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must contain only validate, deploy-staging, and deploy-production jobs"
        )
    job_metadata = {
        "validate": (),
        "deploy-staging": (deploy_if, "needs: validate", "environment: feedback-staging"),
        "deploy-production": (
            deploy_if,
            "needs: deploy-staging",
            "environment: feedback-production",
        ),
    }
    for job_name, step_contracts in job_step_contracts.items():
        blocks = job_blocks.get(job_name, [])
        if len(blocks) != 1:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must contain exactly one {job_name!r} job"
            )
            continue
        job = blocks[0]
        job_lines = [line.strip() for line in job.splitlines() if line.strip()]
        for metadata_line in job_metadata[job_name]:
            if metadata_line not in job_lines:
                issues.append(
                    f"feedback relay job {job_name!r} is missing {metadata_line!r}"
                )
        for action_ref in (
            "uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            "uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020",
        ):
            if sum(action_ref in line for line in job_lines) != 1:
                issues.append(
                    f"feedback relay job {job_name!r} must use {action_ref} exactly once"
                )
        step_blocks = _workflow_step_blocks(job)
        named_steps: dict[str, list[list[str]]] = {}
        for lines in step_blocks:
            first_line = lines[0] if lines else ""
            if first_line.startswith("- name: "):
                named_steps.setdefault(first_line.removeprefix("- name: "), []).append(lines)
        if len(step_blocks) != len(step_contracts) + 2 or set(named_steps) != set(step_contracts):
            issues.append(
                f"feedback relay job {job_name!r} must contain only its contracted steps"
            )
        for step_name, required_lines in step_contracts.items():
            matches = named_steps.get(step_name, [])
            if len(matches) != 1:
                issues.append(
                    f"feedback relay job {job_name!r} must contain exactly one {step_name!r} step"
                )
                continue
            missing_lines = [line for line in required_lines if line not in matches[0]]
            if missing_lines:
                issues.append(
                    f"feedback relay step {step_name!r} is missing its contracted command"
                )
    if re.search(r"(?m)^    env:\n      CLOUDFLARE_", text):
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must scope Cloudflare credentials to individual steps"
        )
    credential_names = ("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID")
    secrets_context = re.compile(r"\bsecrets\b")
    credential_references = {}
    credential_assignments = {}
    for secret_name in credential_names:
        escaped_name = re.escape(secret_name)
        secret_access = (
            rf"secrets\s*(?:\.\s*{escaped_name}|"
            rf"\[\s*['\"]{escaped_name}['\"]\s*\])"
        )
        credential_references[secret_name] = re.compile(
            rf"\$\{{\{{\s*{secret_access}\s*\}}\}}"
        )
        credential_assignments[secret_name] = re.compile(
            rf"^{escaped_name}\s*:\s*['\"]?\$\{{\{{\s*{secret_access}\s*\}}\}}['\"]?$"
        )
    credential_step_names = {
        "Apply staging D1 migrations",
        "Deploy staging Worker",
        "Apply production D1 migrations",
        "Deploy production Worker",
    }
    credential_step_counts = {name: 0 for name in credential_step_names}
    for lines in _workflow_step_blocks(text):
        first_line = lines[0] if lines else ""
        step_name = (
            first_line.removeprefix("- name: ")
            if first_line.startswith("- name: ")
            else ""
        )
        present = {
            secret_name
            for secret_name, pattern in credential_references.items()
            if any(pattern.search(line) for line in lines)
        }
        uses_secrets_context = any(secrets_context.search(line) for line in lines)
        assigned = {
            secret_name
            for secret_name, pattern in credential_assignments.items()
            if any(pattern.fullmatch(line) for line in lines)
        }
        if step_name in credential_step_names:
            credential_step_counts[step_name] += 1
            missing = sorted(set(credential_names) - assigned)
            if missing:
                issues.append(
                    f"feedback relay step {step_name!r} must receive both Cloudflare credentials; "
                    f"missing {', '.join(missing)}"
                )
        elif uses_secrets_context:
            label = step_name or first_line or "unnamed step"
            details = f": {', '.join(sorted(present))}" if present else ""
            issues.append(
                f"feedback relay step {label!r} must not receive GitHub secrets{details}"
            )
    for step_name, count in sorted(credential_step_counts.items()):
        if count != 1:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must contain exactly one {step_name!r} step"
            )
    for secret_name, pattern in credential_references.items():
        if len(pattern.findall(text)) != 4:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must expose {secret_name} only to four migration/deploy steps"
            )
    active_text = text
    yaml_anchor_or_alias = re.compile(
        r"(?m)(?:^|[\s:\-\[\{,])[&*](?![&*])[^ \t\r\n\[\]\{\},]+"
    )
    if yaml_anchor_or_alias.search(active_text):
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must not use YAML anchors or aliases"
        )
    for pattern in credential_references.values():
        active_text = pattern.sub("", active_text)
    if secrets_context.search(active_text):
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must not expose any other GitHub secrets context"
        )

    staging_at = text.find("  deploy-staging:")
    production_at = text.find("  deploy-production:")
    if staging_at < 0 or production_at < 0 or staging_at >= production_at:
        issues.append(
            f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must declare staging before production"
        )
    else:
        staging = text[staging_at:production_at]
        production = text[production_at:]
        if "needs: validate" not in staging:
            issues.append("feedback relay staging deployment must need validate")
        if "needs: deploy-staging" not in production:
            issues.append("feedback relay production deployment must need deploy-staging")
        for label, block in (("staging", staging), ("production", production)):
            migrate_at = block.find("wrangler d1 migrations apply")
            deploy_at = block.find("wrangler deploy --strict")
            health_at = block.find("/healthz")
            if not (0 <= migrate_at < deploy_at < health_at):
                issues.append(
                    f"feedback relay {label} must order migration -> deploy -> health check"
                )

    forbidden = ("GITHUB_PRIVATE_KEY", "ADMIN_TOKEN", "invite_token")
    for secret_name in forbidden:
        if secret_name in text:
            issues.append(
                f"{FEEDBACK_RELAY_DEPLOY_WORKFLOW} must not receive Worker runtime secret {secret_name}"
            )
    return issues


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
            staged = BUILD_STAGED_SOURCE_MARKER.match(source)
            if staged:
                staged_path = staged.group(1).strip()
                if (root / staged_path).exists():
                    issues.append(f"Doc {rel} carries a stale build-phase marker for an existing source path: {staged_path}")
                continue
            # user:// (the runtime user dir) and .godot-smoke/ (gitignored run
            # output) are documented non-repo locations — the agent-surface
            # manifest check below skips them by the same rule; a fresh CI
            # checkout never has them.
            if source.startswith("user://") or source.startswith(".godot-smoke/"):
                continue
            if not (root / source).exists():
                issues.append(f"Doc {rel} references a missing source path: {source}")
        for target in internal_links(path):
            if not resolve_link(path, target, root).exists():
                issues.append(f"Broken internal link in {rel}: {target}")

    issues.extend(report_stamp_issues(root))
    issues.extend(region_coverage_issues(root))
    issues.extend(core_tools_stdlib_issues(root))
    issues.extend(pokeapi_ci_cache_issues(root))
    issues.extend(feedback_relay_deploy_issues(root))
    issues.extend(region_diff_backstop_sync_issues(root))
    issues.extend(art_anchor_issues(root))
    issues.extend(rubric_question_inventory_issues(root))
    issues.extend(miss_postmortem_issues(root))
    issues.extend(sim_rng_setup_issues(root))
    issues.extend(world_depth_rng_issues(root))
    issues.extend(shot_numbering_issues(root))
    issues.extend(agent_surface_issues(root))
    issues.extend(adapter_authority_gate_issues(root))
    issues.extend(command_code_reviewer_issues(root))
    issues.extend(reviewer_cmd_error_detail_issues(root))
    issues.extend(cloud_env_display_issues(root))
    issues.extend(install_cmd_path_issues(root))

    return issues


AGENT_SURFACE_REL = "docs/registry/agent-surface.toml"
# Key-name convention coupling the manifest to the gate: a string value under a
# key ending in _path/_dir/_doc (plus the DAP `scene`) is a repo reference that
# must exist — EXCEPT user:// (the runtime user dir) and .godot-smoke/
# (gitignored run output), which are documented non-repo locations. res:// maps
# to the repo root. Any key named `port` must be an integer in 1..65535.
AGENT_SURFACE_PATH_SUFFIXES = ("_path", "_dir", "_doc")
AGENT_SURFACE_REQUIRED_SECTIONS = (
    "protocols", "scenario_cli", "traces", "visual_baselines",
    "determinism", "golden_save", "preflight", "errors",
)


def _agent_surface_leaves(node: object, prefix: str = "") -> list[tuple[str, object]]:
    """Flatten a parsed TOML table into (dotted_key, leaf_value) pairs."""
    leaves: list[tuple[str, object]] = []
    if isinstance(node, dict):
        for key, value in node.items():
            leaves.extend(_agent_surface_leaves(value, f"{prefix}{key}."))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            leaves.extend(_agent_surface_leaves(value, f"{prefix}{index}."))
    else:
        leaves.append((prefix.rstrip("."), node))
    return leaves


def agent_surface_issues(root: Path) -> list[str]:
    """Validate the agent-surface manifest (docs/registry/agent-surface.toml):
    schema_version is an int, the required sections are present, every `port`
    is a valid integer port, and every repo reference resolves to an existing
    path. An ABSENT manifest returns [] (progressive arming, mirrors
    art_anchor_issues); a present-but-unparseable one is RED
    (refuse-on-unreadable, mirrors _load_miss_ledger)."""
    path = root / AGENT_SURFACE_REL
    if not path.exists():
        return []
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return [f"{AGENT_SURFACE_REL} is present but unreadable "
                f"(refuse-on-unreadable): {exc}"]
    if not isinstance(data, dict):
        return [f"{AGENT_SURFACE_REL} is not a TOML table"]
    issues: list[str] = []
    if not isinstance(data.get("schema_version"), int) or isinstance(data.get("schema_version"), bool):
        issues.append(f"{AGENT_SURFACE_REL}: schema_version must be an integer")
    for section in AGENT_SURFACE_REQUIRED_SECTIONS:
        if section not in data:
            issues.append(f"{AGENT_SURFACE_REL}: missing required section [{section}]")
    for key, value in _agent_surface_leaves(data):
        leaf = key.rsplit(".", 1)[-1]
        if leaf == "port":
            if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 65535:
                issues.append(f"{AGENT_SURFACE_REL}: `{key}` must be an integer port "
                              f"in 1..65535 (got {value!r})")
            continue
        if not isinstance(value, str):
            continue
        if leaf != "scene" and not leaf.endswith(AGENT_SURFACE_PATH_SUFFIXES):
            continue
        if value.startswith("user://") or value.startswith(".godot-smoke/"):
            continue  # runtime user dir / gitignored run output: never repo-local
        rel = value.removeprefix("res://")
        if not (root / rel).exists():
            issues.append(f"{AGENT_SURFACE_REL}: `{key}` references a missing repo "
                          f"path: {value}")
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
    vendored source ART bytes (policed by the art_sha256 pin), not repo artifacts."""
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


# House seeding convention (miss-postmortem miss-002): the determinism half is
# ADOPTED per scenario (seed_for_smoke pins the runtime RNG streams and resets
# Pokemon creation order), so a loud advisory holds the convention.
SEED_DRIVE_MARKERS = ("generate_wild_encounter(", "start_wild_battle(")
SEED_PIN_MARKERS = ("seed_for_smoke(", "_rng.seed")
_PASSED_EMIT_RE = re.compile(r'emit_trace\(\s*"([A-Za-z0-9_]+)_passed"')


def seed_convention_advisories(root: Path | None = None) -> list[str]:
    """Advisory scenario-authoring checklist (stderr, NEVER red — the house
    progressive-arming style): any scenario file that drives wild/battle inputs
    (generate_wild_encounter / start_wild_battle) and emits a <scenario>_passed
    trace must pin deterministic inputs first (seed_for_smoke, or direct _rng.seed
    assignment as visual_sweep.gd's BATTLE_RNG_SEED). A file that skips the pin
    gates its pass event on the per-process wall-clock randomize() — the exact
    nav_audit false-red class (miss-002). A violation can still flake, but never
    silently (the honest-reporting half makes every red reason-carrying); the
    advisory names the remaining seeding debt on every gate run until it is
    closed. Per-file granularity by design: the pin must sit in the file that
    drives the inputs (nav_audit.gd passes its check by delegation to the seeded
    nav_audit_battle.gd, which carries the pin itself)."""
    root = root or Path(__file__).resolve().parents[1]
    scripts_dir = root / "scripts"
    if not scripts_dir.is_dir():
        return []
    advisories: list[str] = []
    for path in sorted(scripts_dir.rglob("*.gd")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        passed = sorted({match.group(1) + "_passed" for match in _PASSED_EMIT_RE.finditer(text)})
        if not passed:
            continue  # not a pass-gating scenario file
        driven = sorted({marker.rstrip("(") for marker in SEED_DRIVE_MARKERS if marker in text})
        if not driven:
            continue  # draws no wild/battle inputs into this file
        if any(marker in text for marker in SEED_PIN_MARKERS):
            continue  # rng pinned (the seam or a direct assignment)
        advisories.append(
            f"{path.relative_to(root)} drives {', '.join(driven)} and emits "
            f"{', '.join(passed)} without pinning the runtime rng (seed_for_smoke "
            "or _rng.seed) before the pass-gating work — the nav_audit false-red "
            "class (miss-002): the pass event rides the per-process wall-clock "
            "seed (advisory, never red)")
    return advisories


def _sim_gd_files(root: Path) -> list[Path]:
    return sorted(root.glob("scripts/**/*_sim.gd"))


def sim_rng_setup_issues(root: Path) -> list[str]:
    """Static determinism rule codifying overworld_mons_sim.gd's NO-rng contract
    (overworld-pokemon.md § Determinism): a *_sim.gd step engine is a pure function
    of derived SplitMix hashes of (world_seed, cell, slot, step), so its setup
    signature must never receive a RandomNumberGenerator and the file must never
    construct one. A sim that takes/owns an rng can silently consume the shared
    wild-encounter stream and break the pinned scenarios + canary."""
    issues: list[str] = []
    for path in _sim_gd_files(root):
        rel = relative_path(path, root)
        text = path.read_text(encoding="utf-8")
        # (1) the setup signature must not take a RandomNumberGenerator parameter
        # ([^)]* spans multi-line signatures; a character class, not '.', so it
        # crosses newlines without DOTALL).
        for match in re.finditer(r"(?:static\s+)?func\s+setup\s*\(([^)]*)\)", text):
            params = match.group(1)
            if "RandomNumberGenerator" in params:
                issues.append(
                    f"{rel}: setup() takes a RandomNumberGenerator ({params.strip()}); "
                    "*_sim.gd step engines must be rng-free (derived hashes only)")
        # (2) the file must never construct its own rng.
        if re.search(r"RandomNumberGenerator\s*\.\s*new\s*\(", text):
            issues.append(
                f"{rel}: constructs RandomNumberGenerator.new(); *_sim.gd step "
                "engines must be rng-free (derived SplitMix hashes only)")
    return issues


def _world_depth_determinism_files(root: Path) -> list[Path]:
    """world-depth.md § Determinism scope: every domain module plus the
    world-depth runtime (landmark_runtime). The *_sim.gd glob above does not reach
    these files, so this list is the extension's coverage. (Infinite-world slice 1
    RETIRED world chaining — the former second runtime world_chain_runtime.gd is
    deleted with the chain predicates; the seamless plane derives everything from
    the ONE world seed.)"""
    files = list(root.glob("scripts/domain/**/*.gd"))
    # dungeon_runtime.gd joins the scope with the legendary-dungeon slice (the world-depth
    # runtime core: warps/resolver/seal/chamber — rng-free, the draws ride the shared _rng).
    for rel in ("scripts/runtime/landmark_runtime.gd", "scripts/runtime/dungeon_runtime.gd"):
        path = root / rel
        if path.exists():
            files.append(path)
    return sorted(set(files))


def world_depth_rng_issues(root: Path) -> list[str]:
    """Static determinism rule codifying world-depth.md § Determinism's NO-new-rng
    contract: the world seed + landmark/legendary anchors + chunk-hash scattering
    are PURE SplitMix hashes of (world_seed, coords), so scripts/domain/** + the
    world-depth runtime must never CONSTRUCT a RandomNumberGenerator (a
    construction — not a threaded parameter: pick_species_for/level_for_scope
    legitimately receive the shared _rng to consume it in the pinned order). The
    three legitimate owners (game_runtime, battle_runtime, player_avatar) live
    outside this scope, so the ban needs no allowlist. Extends
    sim_rng_setup_issues."""
    issues: list[str] = []
    for path in _world_depth_determinism_files(root):
        text = path.read_text(encoding="utf-8")
        if re.search(r"RandomNumberGenerator\s*\.\s*new\s*\(", text):
            issues.append(
                f"{relative_path(path, root)}: constructs RandomNumberGenerator.new(); "
                "world-depth domain + runtime are rng-free (pure SplitMix hashes of "
                "(world_seed, coords) — world-depth.md § Determinism)")
    return issues


# Single-sourced shot-range registry parsed by shot_numbering_issues. The visuals
# builder owns the const (scripts/app/visual_sweep_baselines.gd); its value is a
# GDScript dict literal that is ALSO valid Python, so ast.literal_eval parses it
# directly. Format contract (see SHOT_REGISTRY):
#   {"<sweep>": {"range": [lo, hi], "extra": [..], "seed": <int>}, ..., "retired": [..]}
SHOT_REGISTRY_REL = Path("scripts") / "app" / "visual_sweep_baselines.gd"
RETIRED_WHITELIST = {17, 33, 35, 36, 43}  # 17 (original gap) + 33/35/36 retired with world chaining (infinite-world slice) + 43 (the farfield lair shot) retired with the legendary-dungeon slice
BIOME_SHOT_FLOOR = 3      # committed 03_biome_* shots; loud-fail below this


def _parse_shot_registry(root: Path) -> tuple[dict | None, str | None]:
    """(registry, error). (None, None) = file/const absent (progressive arming,
    mirrors art_anchor_issues); (None, msg) = present but unparseable (LOUD)."""
    path = root / SHOT_REGISTRY_REL
    if not path.exists():
        return None, None
    text = path.read_text(encoding="utf-8")
    marker = text.find("const SHOT_REGISTRY")
    if marker < 0:
        return None, None  # not defined yet -- arms once the visuals builder lands it
    open_brace = text.find("{", marker)
    if open_brace < 0:
        return None, "SHOT_REGISTRY has no opening brace"
    depth = 0
    literal = None
    for i in range(open_brace, len(text)):
        char = text[i]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                literal = text[open_brace:i + 1]
                break
    if literal is None:
        return None, "SHOT_REGISTRY braces are unbalanced"
    try:
        registry = ast.literal_eval(literal)
    except (ValueError, SyntaxError) as exc:
        return None, f"SHOT_REGISTRY is not a parseable dict literal: {exc}"
    if not isinstance(registry, dict):
        return None, "SHOT_REGISTRY is not a dictionary"
    return registry, None


def shot_numbering_issues(root: Path) -> list[str]:
    """Shot-numbering completeness against the single-sourced SHOT_REGISTRY.

    Every registered shot number (a sweep's range + extra) must be a committed
    baseline (NN_*.png) or formally retired; the ONLY retired numbers allowed are the
    RETIRED_WHITELIST (17 + 33/35/36 retired with world chaining + 43 retired with the
    lairs); committed shots must
    themselves be registered; and the biome group (03_biome_*) must hold >= BIOME_SHOT_FLOOR
    shots (loud-fail). Arms progressively until SHOT_REGISTRY exists (cross-builder
    dependency on the visuals builder)."""
    registry, error = _parse_shot_registry(root)
    if error:
        return [f"SHOT_REGISTRY parse failure in {SHOT_REGISTRY_REL}: {error}"]
    if registry is None:
        return []  # progressive arming

    issues: list[str] = []
    registered: dict[int, str] = {}
    retired: set[int] = set()
    for sweep, entry in registry.items():
        if sweep == "retired":
            if isinstance(entry, list):
                retired = {int(n) for n in entry}
            continue
        if not isinstance(entry, dict):
            continue
        span = entry.get("range")
        if isinstance(span, (list, tuple)) and len(span) == 2:
            for number in range(int(span[0]), int(span[1]) + 1):
                registered.setdefault(number, sweep)
        for number in entry.get("extra") or []:
            registered.setdefault(int(number), sweep)

    # (1) retired whitelist: only the RETIRED_WHITELIST numbers may be retired.
    for number in sorted(retired):
        if number not in RETIRED_WHITELIST:
            issues.append(f"SHOT_REGISTRY retires shot {number}, but only "
                          f"{sorted(RETIRED_WHITELIST)} are the whitelisted numbering gaps")

    # Committed baseline shot numbers + biome count.
    baseline_dir = root / "docs" / "generated" / "visual-baselines"
    committed: set[int] = set()
    biome_count = 0
    if baseline_dir.is_dir():
        for png in baseline_dir.glob("*.png"):
            match = re.match(r"^(\d+)_(.*)$", png.stem)
            if not match:
                continue
            committed.add(int(match.group(1)))
            if match.group(2).startswith("biome"):
                biome_count += 1

    # (2) completeness: every registered number is committed or retired.
    for number in sorted(registered):
        if number in committed or number in retired:
            continue
        issues.append(f"SHOT_REGISTRY registers shot {number} ({registered[number]}) "
                      f"but no committed baseline {number:02d}_*.png exists and it is not retired")

    # (3) no orphan committed shots (every committed number is registered or retired).
    for number in sorted(committed):
        if number not in registered and number not in retired:
            issues.append(f"committed baseline shot {number:02d} is not in SHOT_REGISTRY "
                          "(register its sweep range/extra or retire it)")

    # (4) biome floor (loud-fail).
    if biome_count < BIOME_SHOT_FLOOR:
        issues.append(f"biome shot floor violated: {biome_count} committed 03_biome_* "
                      f"shot(s) < required {BIOME_SHOT_FLOOR}")

    return issues


def install_cmd_path_issues(root: Path) -> list[str]:
    """Warm install.sh must see ~/.local/bin/cmd without a login PATH."""
    path = root / ".cursor" / "install.sh"
    if not path.is_file():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f".cursor/install.sh is unreadable: {exc}"]
    if 'export PATH="${HOME}/.local/bin:${PATH}"' not in text:
        return [
            ".cursor/install.sh must prepend $HOME/.local/bin to PATH before "
            "the Command Code presence check"
        ]
    cmd_check = text.find("command -v cmd")
    prepend = text.find('export PATH="${HOME}/.local/bin:${PATH}"')
    if cmd_check == -1 or prepend == -1 or prepend > cmd_check:
        return [
            ".cursor/install.sh must export PATH=$HOME/.local/bin:$PATH before "
            "command -v cmd so a warm non-login re-run does not npm-install again"
        ]
    return []


def cloud_env_display_issues(root: Path) -> list[str]:
    """Lock DISPLAY replace-if-dead so a stale Cloud desktop cannot block Xvfb."""
    del root
    tool_path = Path(__file__).resolve().with_name("cloud_env.py")
    if not tool_path.exists():
        return []
    try:
        cloud = _load_tool("cloud_env", tool_path)
    except (OSError, RuntimeError) as exc:
        return [f"cloud env display: cannot load cloud_env.py: {exc}"]

    issues: list[str] = []
    if cloud._display_num(":99") != "99" or cloud._display_num(":1.0") != "1":
        issues.append("cloud_env._display_num must parse :99 and :1.0")

    with tempfile.TemporaryDirectory() as tmp:
        x11 = Path(tmp) / "X11-unix"
        x11.mkdir()
        sock = x11 / "X99"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        which = cloud.shutil.which
        cloud.shutil.which = lambda _name: None
        try:
            listener.bind(str(sock))
            if not cloud.display_alive(":99", x11_dir=x11):
                issues.append("display_alive socket fallback missed a live X99 socket")
            if cloud.display_alive(":1", x11_dir=x11):
                issues.append("display_alive socket fallback must not treat a missing X1 as live")
            (x11 / "X1").write_text("", encoding="utf-8")
            if cloud.display_alive(":1", x11_dir=x11):
                issues.append("display_alive must require an X11 unix socket, not a regular file")
        finally:
            cloud.shutil.which = which
            listener.close()

        env_file = Path(tmp) / "cloud.env"
        env_file.write_text(
            "export DISPLAY=:99\nexport GODOT_BIN=/persisted/godot\n",
            encoding="utf-8",
        )
        dead = {"DISPLAY": ":1", "GODOT_BIN": "/inherited/godot"}
        applied = cloud.load_cloud_env(
            dead, path=env_file, display_probe=lambda _d: False)
        if dead.get("DISPLAY") != ":99" or "DISPLAY" not in applied:
            issues.append(
                "load_cloud_env must replace a dead inherited DISPLAY with the persisted value"
            )
        if dead.get("GODOT_BIN") != "/inherited/godot":
            issues.append("load_cloud_env must not overwrite a set non-DISPLAY key")
        live = {"DISPLAY": ":1"}
        applied_live = cloud.load_cloud_env(
            live, path=env_file, display_probe=lambda d: d == ":1")
        if live.get("DISPLAY") != ":1" or "DISPLAY" in applied_live:
            issues.append("load_cloud_env must keep a live inherited DISPLAY")
        unset: dict[str, str] = {}
        applied_unset = cloud.load_cloud_env(
            unset, path=env_file, display_probe=lambda _d: False)
        if unset.get("DISPLAY") != ":99" or "DISPLAY" not in applied_unset:
            issues.append("load_cloud_env must still fill an unset DISPLAY")
    return issues


def command_code_reviewer_issues(root: Path) -> list[str]:
    """Lock Command Code reviewer to plan-only argv and ordered SoM+crop paths."""
    del root
    tool_path = Path(__file__).resolve().with_name("vlm_reviewer.py")
    if not tool_path.exists():
        return []
    try:
        reviewer = _load_tool("vlm_reviewer", tool_path)
    except (OSError, RuntimeError) as exc:
        return [f"command code reviewer: cannot load vlm_reviewer.py: {exc}"]

    issues: list[str] = []
    cfg = reviewer.Config(reviewer._parse_args([]))
    argv = reviewer.command_code_argv("/bin/cmd", "prompt", cfg)
    if "--auto-accept" in argv:
        issues.append("vlm_reviewer Command Code argv must not use --auto-accept")
    try:
        mode_at = argv.index("--permission-mode")
    except ValueError:
        issues.append("vlm_reviewer Command Code argv must use --permission-mode plan")
        mode_at = -1
    if mode_at >= 0 and (mode_at + 1 >= len(argv) or argv[mode_at + 1] != "plan"):
        issues.append("vlm_reviewer Command Code argv must set --permission-mode plan")

    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        for name in ("som_before.png", "som_after.png", "before.png", "after.png",
                     "crop_a.png", "crop_b.png"):
            (base / name).write_bytes(b"png")
        cfg.base_dir = base
        ctx = {"paths": {
            "som_before": "som_before.png",
            "som_after": "som_after.png",
            "before": "before.png",
            "after": "after.png",
            "crops": ["crop_a.png", "crop_b.png"],
        }}
        rels = [rel for rel, _kind in reviewer.ordered_review_entries(
            cfg, ctx, ["after", "before"])]
        if rels != ["som_after.png", "som_before.png", "crop_a.png", "crop_b.png"]:
            issues.append(
                "ordered_review_entries must follow the shuffled SoM order and "
                f"include crops; got {rels}"
            )
        prompt = reviewer._command_code_prompt(
            cfg, ctx, "SYS", "USER", ["after", "before"])
        after_at = prompt.find("som_after.png")
        before_at = prompt.find("som_before.png")
        crop_a_at = prompt.find("crop_a.png")
        crop_b_at = prompt.find("crop_b.png")
        if min(after_at, before_at, crop_a_at, crop_b_at) < 0:
            issues.append("_command_code_prompt omitted shuffled SoM or crop paths")
        elif not (after_at < before_at < crop_a_at < crop_b_at):
            issues.append(
                "_command_code_prompt path order must match shuffled SoM then crops"
            )

    have = [{"question_id": "q1-aaa"}, {"question_id": "q1-ccc"}]
    omitted = reviewer.omitted_question_ids(have, {"q1-aaa", "q1-bbb", "q1-ccc"})
    if omitted != ["q1-bbb"]:
        issues.append(
            f"omitted_question_ids must report the unanswered rubric id; got {omitted}"
        )
    repair = reviewer.incomplete_answers_repair_system("SYS", ["q1-bbb"])
    if "q1-bbb" not in repair or "EVERY rubric question" not in repair:
        issues.append(
            "incomplete_answers_repair_system must name omitted ids and demand a "
            "complete answers[]"
        )
    src = tool_path.read_text(encoding="utf-8")
    if "incomplete_answers_repair_system(system, missing)" not in src:
        issues.append(
            "run_model must call incomplete_answers_repair_system on a short pass"
        )
    merged, added, remaining = reviewer.merge_incomplete_repair_answers(
        [{"question_id": "q1-aaa", "verdict": "yes"}],
        [
            {"question_id": "q1-aaa", "verdict": "no"},
            {"question_id": "q1-bbb", "verdict": "yes"},
        ],
        {"q1-aaa", "q1-bbb"},
    )
    identities = [(answer.get("question_id"), answer.get("verdict")) for answer in merged]
    if identities != [("q1-aaa", "yes"), ("q1-bbb", "yes")]:
        issues.append(
            "incomplete repair must add omitted answers without overwriting original verdicts; "
            f"got {identities}"
        )
    if added != ["q1-bbb"] or remaining:
        issues.append(
            "incomplete repair must report newly added and still-missing ids; "
            f"added={added}, remaining={remaining}"
        )
    return issues


def reviewer_cmd_error_detail_issues(root: Path) -> list[str]:
    """Lock reviewer-cmd failures to the last internal-error line.

    Art-anchor live-unverified notes print first and used to occupy stderr[:400],
    hiding ``required vision review incomplete: answers 6/7`` on Cloud.
    """
    del root
    tool_path = Path(__file__).resolve().with_name("vision_review.py")
    if not tool_path.exists():
        return []
    try:
        vision_review = _load_tool("vision_review", tool_path)
    except (OSError, RuntimeError) as exc:
        return [f"reviewer-cmd error detail: cannot load vision_review.py: {exc}"]

    issues: list[str] = []
    noise = (
        "vlm_reviewer: art-anchor live-unverified (counted, never a finding): "
        + "; ".join(
            f"menu/{name} (node absent from draw_order: {node})"
            for name, node in (
                ("party_list", "ListPlate"),
                ("party_summary_plate", "SummaryPlate"),
                ("bag_list_plate", "BackgroundList"),
                ("bag_item_row", "PickerPlate"),
                ("storage_box_plate", "BoxPlate"),
                ("storage_party_plate", "PartyPlate"),
            )
        )
    )
    real = ("vlm_reviewer: internal error: RuntimeError: required vision model "
            "failed: RuntimeError: required vision review incomplete: "
            "passes 1/1, answers 6/7")
    detail = vision_review.reviewer_cmd_error_detail(noise + "\n" + real)
    if "answers 6/7" not in detail:
        issues.append(
            "reviewer_cmd_error_detail must surface the incomplete-answers line, "
            f"not the leading art-anchor note; got {detail!r}"
        )
    if "art-anchor live-unverified" in detail:
        issues.append(
            "reviewer_cmd_error_detail must not prefer the art-anchor note when "
            "an internal error line is present"
        )
    if vision_review.reviewer_cmd_error_detail("") != "no stderr":
        issues.append("reviewer_cmd_error_detail must say 'no stderr' when empty")
    return issues


def adapter_authority_gate_issues(root: Path) -> list[str]:
    """Lock Cloud adapter authority: satellite ``*_update`` names are snapshotted,
    and a farfield-style silent copy (no ``auto_update``) still refuses/restores.
    """
    del root  # runner path is sibling-absolute; root is unused
    tool_path = Path(__file__).resolve().with_name("run_playtests.py")
    if not tool_path.exists():
        return []
    try:
        runner = _load_tool("run_playtests", tool_path)
    except (OSError, RuntimeError) as exc:
        return [f"adapter authority gate: cannot load run_playtests.py: {exc}"]

    issues: list[str] = []
    gate = tuple(runner.SWEEP_GATE_SCENARIOS)
    vision = tuple(runner.VISION_REVIEW_SCENARIOS)
    if gate != vision:
        issues.append(
            "SWEEP_GATE_SCENARIOS must equal VISION_REVIEW_SCENARIOS so every "
            f"satellite *_update name is snapshotted; gate={gate} vision={vision}"
        )
    satellite_updates = [
        name for name in runner.SATELLITE_SWEEP_SCENARIOS
        if str(name).endswith("_update")
    ]
    if satellite_updates:
        issues.append(
            "SATELLITE_SWEEP_SCENARIOS must stay compare-only (verify_all S9); "
            f"found update names {satellite_updates}"
        )

    apple = b'{"capture_env":{"adapter_name":"Apple M4"}}'
    lava = b'{"capture_env":{"adapter_name":"llvmpipe"}}'
    shot = "42_far_landmark.png"

    def write_pair(directory: Path, adapter: bytes) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / shot).write_bytes(b"png")
        (directory / f"{shot}.sidecar.json").write_bytes(adapter)

    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp)
        baseline_dir = project / "docs" / "generated" / "visual-baselines"
        shots_dir = project / ".godot-smoke" / "shots"
        write_pair(baseline_dir, apple)
        snapshot = {
            path.name: path.read_bytes()
            for path in baseline_dir.iterdir() if path.is_file()
        }
        write_pair(shots_dir, lava)
        write_pair(baseline_dir, lava)
        sink = io.StringIO()
        farfield = {
            "scenario": "visual_sweep_farfield",
            "ok": True,
            "error": None,
            "transport": "windowed-subprocess",
            "passed_payload": {"mode": "compare", "shots": [shot]},
        }
        with contextlib.redirect_stdout(sink):
            runner.apply_adapter_authority_gate(project, farfield, snapshot)
        if farfield.get("ok") is not False:
            issues.append(
                "adapter authority gate did not refuse a silent farfield baseline copy"
            )
        err = farfield.get("error") or {}
        if not isinstance(err, dict) or err.get("code") != "adapter_baseline_refused":
            issues.append(
                f"silent farfield copy must set adapter_baseline_refused, got {err!r}"
            )
        if (baseline_dir / f"{shot}.sidecar.json").read_bytes() != apple:
            issues.append("silent farfield copy did not restore the Apple M4 sidecar")

        write_pair(baseline_dir, lava)
        fishing = {
            "scenario": "visual_sweep_fishing_update",
            "ok": True,
            "error": None,
            "transport": "windowed-subprocess",
            "passed_payload": {"mode": "update"},
        }
        with contextlib.redirect_stdout(sink):
            runner.apply_adapter_authority_gate(project, fishing, snapshot)
        if fishing.get("ok") is not False:
            issues.append(
                "adapter authority gate did not refuse visual_sweep_fishing_update"
            )
        ferr = fishing.get("error") or {}
        if not isinstance(ferr, dict) or ferr.get("code") != "adapter_baseline_refused":
            issues.append(
                f"fishing_update must set adapter_baseline_refused, got {ferr!r}"
            )
        if (baseline_dir / f"{shot}.sidecar.json").read_bytes() != apple:
            issues.append("fishing_update did not restore the Apple M4 sidecar")

        write_pair(baseline_dir, apple)
        compare = {
            "scenario": "visual_sweep_farfield",
            "ok": True,
            "error": None,
            "transport": "windowed-subprocess",
            "passed_payload": {"mode": "compare"},
        }
        with contextlib.redirect_stdout(sink):
            runner.apply_adapter_authority_gate(project, compare, snapshot)
        if compare.get("ok") is not True or compare.get("error") is not None:
            issues.append("unmutated farfield compare must remain a no-op")

    return issues


def main() -> int:
    issues = run()
    for advisory in miss_postmortem_advisories():
        print(f"advisory: {advisory}", file=sys.stderr)
    for advisory in seed_convention_advisories():
        print(f"advisory: {advisory}", file=sys.stderr)
    if issues:
        print("Repo contract check failed:")
        print(format_issues(issues))
        return 1
    print("Repo contract check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
