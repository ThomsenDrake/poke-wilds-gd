#!/usr/bin/env python3
"""Pure tests for shared update manifests, apply swaps, and publish refusals."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

import publish_update
import update_apply
import update_manifest
from update_manifest import parse


class UpdateManifestTests(unittest.TestCase):
    def _valid(self) -> dict:
        digest = "c" * 64
        return {
            "schema_version": 1,
            "channel": "playtest",
            "published_at": "2026-08-19T18:00:00Z",
            "build_id": "playtest-abc1234567-20260819T180000Z",
            "commit_sha": "b" * 40,
            "min_save_version": 6,
            "builds": {
                "linux": {"url": "https://cdn.test/linux", "sha256": digest, "bytes": 8,
                          "filename": "PokeWilds-linux.x86_64"},
                "windows": {"url": "https://cdn.test/windows", "sha256": digest, "bytes": 8,
                            "filename": "PokeWilds-windows.exe"},
                "macos": {"url": "https://cdn.test/macos", "sha256": digest, "bytes": 8,
                          "filename": "PokeWilds-macos.zip"},
            },
        }

    def test_parse_accepts_the_frozen_shape(self) -> None:
        parsed = parse(self._valid())
        self.assertEqual(parsed["channel"], "playtest")
        self.assertEqual(update_manifest.os_key("Linux"), "linux")

    def test_parse_rejects_missing_checksum(self) -> None:
        payload = self._valid()
        payload["builds"]["linux"]["sha256"] = ""
        self.assertEqual(parse(payload), {})

    def test_is_newer_never_downgrades(self) -> None:
        latest = parse(self._valid())
        older = {"build_id": "friends-old", "published_at": "2026-08-01T00:00:00Z"}
        newer = {"build_id": latest["build_id"], "published_at": latest["published_at"]}
        self.assertTrue(update_manifest.is_newer(latest, older))
        self.assertFalse(update_manifest.is_newer(latest, newer))
        self.assertFalse(update_manifest.is_newer(latest, older, newer))
        same_time = {"build_id": "aaa-older", "published_at": latest["published_at"]}
        self.assertTrue(update_manifest.is_newer(latest, same_time))
        unstamped = {"build_id": "friends-old"}
        self.assertFalse(update_manifest.is_newer(latest, unstamped))
        stamped_friend = {"build_id": "friends-1-aaaaaaaaaa-20260801T000000Z"}
        newer_friend = {"build_id": "friends-1-aaaaaaaaaa-20260820T000000Z"}
        self.assertTrue(update_manifest.is_newer(latest, stamped_friend))
        self.assertFalse(update_manifest.is_newer(latest, newer_friend))

    def test_is_offerable_requires_a_supported_os_build(self) -> None:
        latest = parse(self._valid())
        older = {"build_id": "friends-old", "published_at": "2026-08-01T00:00:00Z"}
        self.assertTrue(update_manifest.is_offerable(latest, older, {}, "Linux"))
        self.assertTrue(update_manifest.is_offerable(latest, older, {}, "Windows"))
        self.assertTrue(update_manifest.is_offerable(latest, older, {}, "macOS"))
        self.assertFalse(update_manifest.is_offerable(latest, older, {}, "Android"))
        self.assertFalse(update_manifest.is_offerable(latest, older, {}, "Web"))
        self.assertFalse(update_manifest.is_offerable(latest, older, {}, ""))
        self.assertEqual(update_manifest.build_for_os(latest, "Android"), {})
        self.assertEqual(update_manifest.os_key("Android"), "")


class UpdateApplyTests(unittest.TestCase):
    def test_linux_unlinks_and_replaces(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            current = root / "PokeWilds.x86_64"
            artifact = root / "new.bin"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            result = update_apply.apply("Linux", artifact, current)
            self.assertTrue(result["ok"])
            self.assertEqual(current.read_bytes(), b"new")
            self.assertFalse(Path(str(current) + ".old").exists())

    def test_windows_keeps_old_until_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            current = root / "PokeWilds.exe"
            artifact = root / "new.exe"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            result = update_apply.apply("Windows", artifact, current)
            self.assertTrue(result["ok"])
            self.assertEqual(current.read_bytes(), b"new")
            self.assertEqual(Path(result["old_path"]).read_bytes(), b"old")
            update_apply.cleanup_old(current)
            self.assertFalse(Path(result["old_path"]).exists())

    def test_macos_swaps_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            app = root / "PokeWilds-Godot.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents" / "MacOS").mkdir()
            (app / "Contents" / "MacOS" / "PokeWilds").write_bytes(b"old")
            artifact = root / "PokeWilds.zip"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("PokeWilds-Godot.app/Contents/MacOS/PokeWilds", b"new")
            result = update_apply.apply("macOS", artifact, app)
            self.assertTrue(result["ok"], result)
            self.assertEqual((app / "Contents" / "MacOS" / "PokeWilds").read_bytes(), b"new")

    def test_refuses_save_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            save = root / "godot_port_save.json"
            artifact = root / "new.bin"
            save.write_bytes(b"save")
            artifact.write_bytes(b"new")
            self.assertEqual(update_apply.apply("Linux", artifact, save)["error"], "save_path_refused")


class PublishUpdateTests(unittest.TestCase):
    def test_dirty_tree_refuses_publish(self) -> None:
        parser = publish_update.argparse.ArgumentParser()
        parser.add_argument("--channel", default="playtest")
        parser.add_argument("--endpoint", default="https://relay.test")
        parser.add_argument("--allow-dirty", action="store_true")
        with mock.patch.object(publish_update, "worktree_is_dirty", return_value=True), \
                mock.patch.dict("os.environ", {
                    "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                    "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                }):
            with self.assertRaises(SystemExit):
                with mock.patch("sys.argv", ["publish_update.py"]):
                    publish_update.main()

    def test_export_writes_shared_metadata_without_a_friend_token(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            outputs = []

            def fake_run(cmd, check, cwd):  # noqa: ANN001
                path = Path(cmd[-1])
                path.write_bytes(b"bin")
                outputs.append(path)
                return mock.Mock()

            with mock.patch.object(publish_update, "run", side_effect=["a" * 40, "v1"]), \
                    mock.patch.object(publish_update, "ROOT", root), \
                    mock.patch.object(publish_update, "BUILD_INFO",
                                      root / "generated" / "playtest_build.json"):
                exported = publish_update.export_shared(
                    "playtest", "https://relay.test", godot="godot", runner=fake_run)
            self.assertEqual(set(exported["artifacts"]), {"linux", "windows", "macos"})
            metadata = json.loads((root / "generated" / "playtest_build.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["invite_token"], "")
            self.assertEqual(metadata["tester_id"], "UNASSIGNED")
            self.assertEqual(metadata["channel"], "playtest")

    def test_wrangler_put_prefixes_configured_bucket(self) -> None:
        captured: list[list[str]] = []

        def fake_run(cmd, check, cwd):  # noqa: ANN001
            captured.append(cmd)
            return mock.Mock()

        with mock.patch.dict("os.environ", {
            "PLAYTEST_UPDATE_PUBLIC_BASE": "https://cdn.test",
            "PLAYTEST_UPDATE_R2_BUCKET": "poke-wilds-feedback-private",
        }, clear=False), mock.patch.object(publish_update.subprocess, "run", side_effect=fake_run):
            url = publish_update.wrangler_put(
                "updates/playtest/b1/linux", Path("/tmp/artifact.bin"), "c" * 64)
        self.assertEqual(url, "https://cdn.test/updates/playtest/b1/linux")
        self.assertEqual(captured[0][4], "poke-wilds-feedback-private/updates/playtest/b1/linux")

    def test_configured_r2_bucket_reads_reports_binding(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(publish_update.configured_r2_bucket(), "poke-wilds-feedback-private")
            self.assertEqual(
                publish_update.configured_r2_bucket(environment="staging"),
                "poke-wilds-feedback-private-staging",
            )


if __name__ == "__main__":
    unittest.main()
