#!/usr/bin/env python3
"""Export one shared latest build per OS and publish the update manifest."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

from feedback_endpoint import open_no_redirect, validated_endpoint
from package_playtest import (
    BUILD_INFO,
    TARGETS,
    USER_AGENT,
    build_metadata_lock,
    godot_binary,
    run,
    worktree_is_dirty,
)
from update_manifest import artifact_key, artifact_public_url, parse

ROOT = Path(__file__).resolve().parents[1]
WRANGLER_CONFIG = ROOT / "services" / "feedback-relay" / "wrangler.jsonc"


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
    }
    BUILD_INFO.parent.mkdir(parents=True, exist_ok=True)
    BUILD_INFO.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def export_shared(channel: str, endpoint: str, *, godot: str, runner=subprocess.run) -> dict:
    commit = run("git", "rev-parse", "HEAD")
    version = run("git", "describe", "--tags", "--always")
    published_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build_id = f"{channel}-{commit[:10]}-{published_at.replace(':', '').replace('-', '')}"
    output_dir = ROOT / "dist" / "updates" / build_id
    output_dir.mkdir(parents=True, exist_ok=True)
    write_shared_build_info(channel, endpoint, commit, version, build_id, published_at, None)
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
        url = put_object(key, artifact["path"], artifact["sha256"])
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


def configured_r2_bucket(text: str | None = None, *, environment: str = "") -> str:
    override = os.environ.get("PLAYTEST_UPDATE_R2_BUCKET", "").strip()
    if override:
        return override
    env_name = environment or os.environ.get("PLAYTEST_UPDATE_WRANGLER_ENV", "").strip()
    raw = text if text is not None else WRANGLER_CONFIG.read_text(encoding="utf-8")
    data = json.loads(raw)
    block = data.get("env", {}).get(env_name, data) if env_name else data
    for entry in block.get("r2_buckets", []):
        if entry.get("binding") == "REPORTS" and entry.get("bucket_name"):
            return str(entry["bucket_name"])
    raise RuntimeError("wrangler.jsonc has no REPORTS bucket_name")


def wrangler_put(key: str, path: Path, digest: str, endpoint: str = "") -> str:
    parts = key.split("/")
    if len(parts) != 4 or parts[0] != "updates":
        raise RuntimeError("refusing to publish a non-updates object key")
    object_path = wrangler_object_path(configured_r2_bucket(), key)
    subprocess.run(["wrangler", "r2", "object", "put", object_path, "--file", str(path),
                    "--custom-metadata", f"sha256={digest}"], check=True, cwd=ROOT / "services" / "feedback-relay")
    return artifact_public_url(
        endpoint or os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""),
        parts[1], parts[2], parts[3],
        os.environ.get("PLAYTEST_UPDATE_PUBLIC_BASE", ""),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default="playtest")
    parser.add_argument("--endpoint", default=os.environ.get("PLAYTEST_FEEDBACK_ENDPOINT", ""))
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    admin_token = os.environ.get("PLAYTEST_FEEDBACK_ADMIN_TOKEN", "")
    if not args.endpoint or not admin_token:
        parser.error("set PLAYTEST_FEEDBACK_ENDPOINT and PLAYTEST_FEEDBACK_ADMIN_TOKEN")
    endpoint = validated_endpoint(args.endpoint)
    if not args.allow_dirty and worktree_is_dirty():
        parser.error("worktree is dirty; commit or ignore every release input first")
    with build_metadata_lock():
        try:
            exported = export_shared(args.channel, endpoint, godot=godot_binary())
            builds = upload_artifacts(
                exported, put_object=lambda key, dest, digest: wrangler_put(
                    key, dest, digest, endpoint=endpoint))
            publish_manifest(endpoint, admin_token, exported, builds)
        finally:
            BUILD_INFO.unlink(missing_ok=True)
    print(f"published shared {args.channel} update {exported['build_id']}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"update publish failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
