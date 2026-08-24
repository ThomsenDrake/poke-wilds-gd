#!/usr/bin/env python3
"""Export one shared latest build per OS and publish the update manifest."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from feedback_endpoint import open_no_redirect, validated_endpoint
from package_playtest import (
    BUILD_INFO,
    TARGETS,
    USER_AGENT,
    build_metadata_lock,
    godot_binary,
    public_tester_id,
    register_invite,
    run,
    dirty_worktree_error,
    worktree_is_dirty,
)
from update_manifest import artifact_key, artifact_public_url, parse

ROOT = Path(__file__).resolve().parents[1]
WRANGLER_CONFIG = ROOT / "services" / "feedback-relay" / "wrangler.jsonc"
RELAY_PATHS = (
    "services/feedback-relay",
    ".github/workflows/feedback-relay-deploy.yml",
)
STABLE_RELEASE_ASSETS = {
    "linux": "PokeWilds-linux.x86_64",
    "windows": "PokeWilds-windows.exe",
    "macos": "PokeWilds-macos.zip",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_shared_build_info(channel: str, endpoint: str, commit: str, version: str,
                            build_id: str, published_at: str, cohort: dict | None) -> None:
    payload = {
        "schema_version": 1,
        "version": version,
        "commit_sha": commit,
        "build_id": build_id,
        "channel": channel,
        "endpoint": endpoint,
        "published_at": published_at,
        "tester_id": (cohort or {}).get("tester_id", "UNASSIGNED"),
        "invite_token": (cohort or {}).get("token", ""),
        "identity_kind": "cohort" if cohort else "",
    }
    BUILD_INFO.parent.mkdir(parents=True, exist_ok=True)
    BUILD_INFO.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def cohort_from_env(channel: str) -> dict | None:
    """Return the shared accountless invite, or None when CI/local publish is tokenless."""
    token = os.environ.get("PLAYTEST_COHORT_INVITE_TOKEN", "").strip()
    if not token:
        return None
    nickname = os.environ.get("PLAYTEST_COHORT_NICKNAME", "shared-playtest").strip()
    return {
        "tester_id": public_tester_id(token),
        "token": token,
        "nickname": nickname or "shared-playtest",
        "cohort_id": channel,
    }


def write_publish_receipt(exported: dict, path: Path | None = None) -> Path:
    """Write public artifact metadata. Never include invite tokens or file paths."""
    dest = path or (
        ROOT / "dist" / "updates" / exported["build_id"] / "receipt.json"
    )
    dest.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "channel": exported["channel"],
        "build_id": exported["build_id"],
        "commit_sha": exported["commit_sha"],
        "version": exported["version"],
        "published_at": exported["published_at"],
        "artifacts": {
            os_name: {key: artifact[key] for key in ("filename", "sha256", "bytes")}
            for os_name, artifact in exported["artifacts"].items()
        },
    }
    dest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return dest


def stage_github_release_assets(receipt_path: Path, dest_dir: Path) -> list[Path]:
    """Copy timestamped artifacts to stable GitHub Release names so --clobber replaces."""
    doc = json.loads(receipt_path.read_text(encoding="utf-8"))
    artifacts = doc.get("artifacts") or {}
    missing = set(STABLE_RELEASE_ASSETS) - set(artifacts)
    if missing:
        raise RuntimeError(f"receipt is missing OS artifacts: {sorted(missing)}")
    dest_dir.mkdir(parents=True, exist_ok=True)
    staged: list[Path] = []
    src_dir = receipt_path.parent
    for os_name, stable_name in STABLE_RELEASE_ASSETS.items():
        source = src_dir / str(artifacts[os_name]["filename"])
        if not source.is_file():
            raise RuntimeError(f"missing release artifact {source.name}")
        dest = dest_dir / stable_name
        shutil.copy2(source, dest)
        staged.append(dest)
    return staged


def export_shared(channel: str, endpoint: str, *, godot: str, runner=subprocess.run,
                  cohort: dict | None = None) -> dict:
    commit = run("git", "rev-parse", "HEAD")
    version = run("git", "describe", "--tags", "--always")
    published_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build_id = f"{channel}-{commit[:10]}-{published_at.replace(':', '').replace('-', '')}"
    output_dir = ROOT / "dist" / "updates" / build_id
    output_dir.mkdir(parents=True, exist_ok=True)
    write_shared_build_info(channel, endpoint, commit, version, build_id, published_at, cohort)
    artifacts = {}
    for os_name, (preset, extension) in TARGETS.items():
        output = output_dir / f"PokeWilds-{build_id}-{os_name}{extension}"
        runner([godot, "--headless", "--path", str(ROOT), "--export-release", preset, str(output)],
               check=True, cwd=ROOT)
        artifacts[os_name] = {
            "path": output,
            "sha256": sha256_file(output),
            "bytes": output.stat().st_size,
            "filename": output.name,
        }
    return {
        "channel": channel, "build_id": build_id, "commit_sha": commit, "version": version,
        "published_at": published_at, "artifacts": artifacts,
    }


def upload_artifacts(exported: dict, *, put_object) -> dict:
    builds = {}
    for os_name, artifact in exported["artifacts"].items():
        key = artifact_key(exported["channel"], exported["build_id"], os_name)
        url = put_object(key, artifact["path"])
        builds[os_name] = {
            "url": url, "sha256": artifact["sha256"], "bytes": artifact["bytes"],
            "filename": artifact["filename"],
        }
    return builds


def publish_manifest(endpoint: str, admin_token: str, exported: dict, builds: dict, *,
                     urlopen=open_no_redirect) -> dict:
    manifest = parse({
        "schema_version": 1,
        "channel": exported["channel"],
        "published_at": exported["published_at"],
        "build_id": exported["build_id"],
        "commit_sha": exported["commit_sha"],
        "min_save_version": 6,
        "builds": builds,
    })
    if not manifest:
        raise RuntimeError("refusing to publish an invalid update manifest")
    payload = json.dumps(manifest).encode()
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v1/admin/updates", data=payload, method="PUT",
        headers={"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json",
                 "User-Agent": USER_AGENT},
    )
    with urlopen(request, timeout=20) as response:
        if response.status not in (200, 201):
            raise RuntimeError(f"manifest publish returned HTTP {response.status}")
        return json.loads(response.read().decode())


def wrangler_object_path(bucket: str, key: str) -> str:
    return f"{bucket.strip().strip('/')}/{key.lstrip('/')}"


def normalize_wrangler_env(name: str) -> str:
    text = name.strip()
    if text in ("", "production", "default"):
        return ""
    return text


def infer_wrangler_env(endpoint: str) -> str:
    host = (urllib.parse.urlparse(endpoint).hostname or "").lower()
    if "feedback-relay-staging" in host or "-staging." in host:
        return "staging"
    return ""


def resolved_wrangler_env(endpoint: str, explicit: str = "") -> str:
    raw = explicit.strip() or os.environ.get("PLAYTEST_UPDATE_WRANGLER_ENV", "").strip()
    specified = bool(raw)
    chosen = normalize_wrangler_env(raw)
    inferred = infer_wrangler_env(endpoint)
    if specified and chosen != inferred:
        raise RuntimeError("wrangler env does not match the selected update endpoint")
    return chosen if specified else inferred


def configured_r2_bucket(text: str | None = None, *, environment: str = "") -> str:
    override = os.environ.get("PLAYTEST_UPDATE_R2_BUCKET", "").strip()
    if override:
        return override
    env_name = normalize_wrangler_env(environment or os.environ.get("PLAYTEST_UPDATE_WRANGLER_ENV", ""))
    raw = text if text is not None else WRANGLER_CONFIG.read_text(encoding="utf-8")
    data = json.loads(raw)
    block = data.get("env", {}).get(env_name, data) if env_name else data
    for entry in block.get("r2_buckets", []):
        if entry.get("binding") == "REPORTS" and entry.get("bucket_name"):
            return str(entry["bucket_name"])
    raise RuntimeError("wrangler.jsonc has no REPORTS bucket_name")


class LatestNotFound(RuntimeError):
    """Authoritative empty GET /v1/updates/latest pointer."""


def fetch_latest(endpoint: str, channel: str, *, urlopen=open_no_redirect) -> dict:
    base = validated_endpoint(endpoint)
    request = urllib.request.Request(
        f"{base}/v1/updates/latest?channel={urllib.parse.quote(channel)}",
        method="GET",
        headers={"User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=20) as response:
            if response.status == 404:
                raise LatestNotFound("latest is not published")
            if response.status != 200:
                raise RuntimeError(f"latest returned HTTP {response.status}")
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise LatestNotFound("latest is not published") from exc
        raise RuntimeError(f"latest returned HTTP {exc.code}") from exc
    if not isinstance(data, dict):
        raise RuntimeError("latest is not a JSON object")
    return data


def already_published_commit(latest: dict, sha: str) -> bool:
    wanted = sha.strip().lower()
    return bool(wanted) and str(latest.get("commit_sha", "")).strip().lower() == wanted


def assert_latest_matches_commit(latest: dict, sha: str) -> None:
    """Refuse to attach a GitHub Release from a latest pointer that is not HEAD."""
    if not already_published_commit(latest, sha):
        got = str(latest.get("commit_sha", "")).strip() or "missing"
        raise RuntimeError(
            f"refusing to attach a GitHub Release; latest commit {got} is not {sha}"
        )


def assert_current_main(*, git_run=run) -> str:
    """Refuse to publish if origin/main moved past this SHA during the job."""
    git_run("git", "fetch", "--no-tags", "origin", "main")
    current = git_run("git", "rev-parse", "origin/main")
    wanted = git_run("git", "rev-parse", "HEAD")
    if current != wanted:
        raise RuntimeError(
            f"refusing stale playtest publish {wanted}; origin/main is {current}"
        )
    return wanted


def required_relay_commit(*, git_run=run) -> str:
    """Latest commit that deployed Worker code. Equals HEAD when this SHA changed it."""
    sha = git_run("git", "log", "-1", "--format=%H", "--", *RELAY_PATHS)
    if not sha:
        raise RuntimeError("refusing playtest publish; no relay commit on this branch")
    return sha


def fetch_healthz(endpoint: str, *, urlopen=open_no_redirect) -> dict:
    base = validated_endpoint(endpoint)
    request = urllib.request.Request(
        f"{base}/healthz",
        method="GET",
        headers={"User-Agent": USER_AGENT},
    )
    with urlopen(request, timeout=15) as response:
        if response.status != 200:
            raise RuntimeError(f"healthz returned HTTP {response.status}")
        data = json.loads(response.read().decode())
    if not isinstance(data, dict):
        raise RuntimeError("healthz is not a JSON object")
    return data


def commit_contains(ancestor: str, descendant: str, *, runner=subprocess.run) -> bool:
    """True when descendant is ancestor or a later commit that includes it."""
    wanted = ancestor.strip()
    tag = descendant.strip()
    if not wanted or not tag:
        return False
    if wanted == tag:
        return True
    result = runner(
        ["git", "merge-base", "--is-ancestor", wanted, tag],
        cwd=ROOT, capture_output=True, text=True,
    )
    return result.returncode == 0


def production_relay_covers(health: dict, sha: str, *, contains=commit_contains) -> bool:
    tag = str(health.get("version_tag") or "").strip()
    return bool(
        sha.strip()
        and health.get("ok") is True
        and health.get("environment") == "production"
        and health.get("report_schema") == 1
        and contains(sha, tag)
    )


def assert_production_relay(endpoint: str, sha: str, *, urlopen=open_no_redirect,
                            contains=commit_contains, attempts: int = 1,
                            delay: float = 0.0) -> dict:
    """Refuse register_invite until production /healthz includes this relay SHA."""
    last_error = "unreachable"
    for attempt in range(max(1, attempts)):
        try:
            health = fetch_healthz(endpoint, urlopen=urlopen)
        except (OSError, RuntimeError, json.JSONDecodeError, ValueError) as exc:
            last_error = str(exc)
        else:
            if production_relay_covers(health, sha, contains=contains):
                return health
            last_error = (
                f"version_tag={health.get('version_tag')!r} "
                f"environment={health.get('environment')!r}"
            )
        if attempt + 1 < attempts and delay > 0:
            time.sleep(delay)
    raise RuntimeError(
        f"refusing stale production relay; wanted version_tag containing {sha}, {last_error}"
    )


def stage_github_release_from_latest(latest: dict, dest_dir: Path, *,
                                     urlopen=open_no_redirect) -> list[Path]:
    """Copy already-published artifacts onto the stable GitHub Release names."""
    builds = latest.get("builds") or {}
    missing = set(STABLE_RELEASE_ASSETS) - set(builds)
    if missing:
        raise RuntimeError(f"latest is missing OS artifacts: {sorted(missing)}")
    dest_dir.mkdir(parents=True, exist_ok=True)
    staged: list[Path] = []
    for os_name, stable_name in STABLE_RELEASE_ASSETS.items():
        url = str(builds[os_name].get("url", "")).strip()
        if not url.startswith("https://"):
            raise RuntimeError(f"latest {os_name} artifact URL is not HTTPS")
        expected_digest = str(builds[os_name].get("sha256", "")).strip().lower()
        expected_bytes = int(builds[os_name].get("bytes", 0) or 0)
        dest = dest_dir / stable_name
        request = urllib.request.Request(url, method="GET", headers={"User-Agent": USER_AGENT})
        with urlopen(request, timeout=120) as response:
            body = response.read()
        if hashlib.sha256(body).hexdigest() != expected_digest or len(body) != expected_bytes:
            raise RuntimeError(f"latest {os_name} artifact does not match the manifest")
        dest.write_bytes(body)
        staged.append(dest)
    return staged


def wrangler_put(key: str, path: Path, endpoint: str = "",
                 environment: str = "") -> str:
    parts = key.split("/")
    if len(parts) != 4 or parts[0] != "updates":
        raise RuntimeError("refusing to publish a non-updates object key")
    env_name = resolved_wrangler_env(endpoint, environment)
    object_path = wrangler_object_path(configured_r2_bucket(environment=env_name), key)
    subprocess.run(["wrangler", "r2", "object", "put", object_path, "--file", str(path),
                    "--remote"], check=True, cwd=ROOT / "services" / "feedback-relay")
    return artifact_public_url(
        endpoint or os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""),
        parts[1], parts[2], parts[3],
        os.environ.get("PLAYTEST_UPDATE_PUBLIC_BASE", ""),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default="playtest")
    parser.add_argument("--endpoint", default=os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""))
    parser.add_argument("--wrangler-env", default=os.environ.get("PLAYTEST_UPDATE_WRANGLER_ENV", ""))
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument(
        "--require-cohort",
        action="store_true",
        help="Refuse tokenless shared builds so new testers can still F-report",
    )
    parser.add_argument(
        "--embed-public",
        action="store_true",
        help="Export three OS artifacts with empty endpoint and invite; skip relay publish",
    )
    parser.add_argument(
        "--already-published",
        action="store_true",
        help="Print already_published=true|false for HEAD vs the channel latest and exit",
    )
    parser.add_argument(
        "--require-production-relay",
        action="store_true",
        help="Refuse unless production /healthz version_tag contains the latest relay commit",
    )
    args = parser.parse_args()
    if args.embed_public and (
            args.require_cohort or args.already_published or args.require_production_relay):
        parser.error("--embed-public cannot be combined with playtest publish flags")
    if args.embed_public:
        if not args.allow_dirty and worktree_is_dirty():
            parser.error(dirty_worktree_error())
        with build_metadata_lock():
            try:
                exported = export_shared(
                    args.channel, "", godot=godot_binary(), cohort=None)
                write_publish_receipt(exported)
            finally:
                BUILD_INFO.unlink(missing_ok=True)
        print(f"exported public {args.channel} build {exported['build_id']}")
        return 0
    if args.already_published:
        if not args.endpoint:
            parser.error("set PLAYTEST_FEEDBACK_ENDPOINT")
        sha = run("git", "rev-parse", "HEAD")
        try:
            latest = fetch_latest(args.endpoint, args.channel)
        except LatestNotFound:
            print("already_published=false")
            return 0
        except (OSError, TimeoutError, RuntimeError, json.JSONDecodeError, ValueError) as exc:
            print(f"latest lookup failed: {exc}", file=sys.stderr)
            return 1
        print(f"already_published={'true' if already_published_commit(latest, sha) else 'false'}")
        return 0
    if args.require_production_relay:
        if not args.endpoint:
            parser.error("set PLAYTEST_FEEDBACK_ENDPOINT")
        sha = required_relay_commit()
        health = assert_production_relay(args.endpoint, sha)
        tag = str(health.get("version_tag") or sha).strip()
        print(f"production_relay={tag}")
        return 0
    admin_token = os.environ.get("PLAYTEST_FEEDBACK_ADMIN_TOKEN", "")
    if not args.endpoint or not admin_token:
        parser.error("set PLAYTEST_FEEDBACK_ENDPOINT and PLAYTEST_FEEDBACK_ADMIN_TOKEN")
    endpoint = validated_endpoint(args.endpoint)
    if not args.allow_dirty and worktree_is_dirty():
        parser.error(dirty_worktree_error())
    cohort = cohort_from_env(args.channel)
    if args.require_cohort and not cohort:
        parser.error("PLAYTEST_COHORT_INVITE_TOKEN is required for distributed shared builds")
    with build_metadata_lock():
        try:
            assert_current_main()
            if cohort:
                assert_production_relay(endpoint, required_relay_commit())
                register_invite(endpoint, admin_token, cohort)
            exported = export_shared(
                args.channel, endpoint, godot=godot_binary(), cohort=cohort)
            write_publish_receipt(exported)
            builds = upload_artifacts(
                exported, put_object=lambda key, dest: wrangler_put(
                    key, dest, endpoint=endpoint, environment=args.wrangler_env))
            assert_current_main()
            publish_manifest(endpoint, admin_token, exported, builds)
        finally:
            BUILD_INFO.unlink(missing_ok=True)
    suffix = f" cohort {cohort['tester_id']}" if cohort else ""
    print(f"published shared {args.channel} update {exported['build_id']}{suffix}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"update publish failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
