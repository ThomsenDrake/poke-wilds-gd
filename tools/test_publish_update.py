#!/usr/bin/env python3
"""Pure tests for shared update manifests, apply swaps, and publish refusals."""

from __future__ import annotations

import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
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
        self.assertTrue(update_manifest.is_offerable(latest, older, {}, "Linux", 6))
        self.assertFalse(update_manifest.is_offerable(latest, older, {}, "Linux", 5))
        self.assertEqual(update_manifest.build_for_os(latest, "Android"), {})
        self.assertEqual(update_manifest.os_key("Android"), "")


class UpdateApplyTests(unittest.TestCase):
    def test_linux_stages_then_promotes(self) -> None:
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
            self.assertFalse(Path(str(current) + ".new").exists())
            self.assertEqual(current.stat().st_mode & 0o111, 0o111)

    def test_linux_restores_old_when_promote_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            current = root / "PokeWilds.x86_64"
            artifact = root / "new.bin"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            real_replace = Path.replace

            def flaky(self: Path, target: Path) -> Path:
                if self.name.endswith(".new"):
                    raise OSError("promote failed")
                return real_replace(self, target)

            with mock.patch.object(Path, "replace", flaky):
                result = update_apply.apply("Linux", artifact, current)
            self.assertFalse(result["ok"])
            self.assertEqual(current.read_bytes(), b"old")
            self.assertFalse(Path(str(current) + ".new").exists())

    def test_linux_refuses_when_chmod_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            current = root / "PokeWilds.x86_64"
            artifact = root / "new.bin"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            with mock.patch.object(Path, "chmod", side_effect=OSError("chmod failed")):
                result = update_apply.apply("Linux", artifact, current)
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"], "chmod_failed")
            self.assertEqual(current.read_bytes(), b"old")
            self.assertFalse(Path(str(current) + ".new").exists())
            self.assertFalse(Path(str(current) + ".old").exists())

    def test_windows_stages_helper_and_swaps_after_exit(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            current = root / "PokeWilds.exe"
            artifact = root / "new.exe"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            result = update_apply.apply("Windows", artifact, current)
            self.assertTrue(result["ok"])
            self.assertTrue(result["deferred"])
            self.assertEqual(current.read_bytes(), b"old")
            self.assertEqual(Path(str(current) + ".new").read_bytes(), b"new")
            self.assertTrue(Path(result["helper"]).is_file())
            self.assertIn("PokeWilds-update.cmd", result["helper"])
            finished = update_apply.complete_windows_swap(current)
            self.assertEqual(current.read_bytes(), b"new")
            self.assertEqual(Path(finished["old_path"]).read_bytes(), b"old")
            update_apply.cleanup_old(current)
            self.assertFalse(Path(finished["old_path"]).exists())

    def test_windows_helper_launch_refuses_negative_pid(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            helper = Path(raw) / "PokeWilds-update.cmd"
            helper.write_text("@echo off\r\n", encoding="ascii")
            applied = {"helper": str(helper)}
            self.assertFalse(update_apply.launch_deferred(applied, create_process=lambda _path: -1))
            self.assertTrue(update_apply.launch_deferred(applied, create_process=lambda _path: 42))
            self.assertFalse(update_apply.launch_deferred({"helper": ""}, create_process=lambda _path: 42))
            self.assertFalse(update_apply.launch_deferred(
                {"helper": str(Path(raw) / "missing.cmd")}, create_process=lambda _path: 42))

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
    def _assert_remote_put(self, cmd: list[str], object_path: str) -> None:
        self.assertEqual(cmd[:5], ["wrangler", "r2", "object", "put", object_path])
        self.assertIn("--file", cmd)
        self.assertIn("--remote", cmd)
        self.assertNotIn("--cache-control", cmd)
        self.assertNotIn("--custom-metadata", cmd)
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

    def test_export_embeds_a_cohort_invite_not_a_friend_name(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)

            def fake_run(cmd, check, cwd):  # noqa: ANN001
                Path(cmd[-1]).write_bytes(b"bin")
                return mock.Mock()

            cohort = {
                "tester_id": "PKMN-EEVEE-ABCDEF",
                "token": "secret-cohort-token",
                "nickname": "shared-playtest",
                "cohort_id": "playtest",
            }
            with mock.patch.object(publish_update, "run", side_effect=["a" * 40, "v1"]), \
                    mock.patch.object(publish_update, "ROOT", root), \
                    mock.patch.object(publish_update, "BUILD_INFO",
                                      root / "generated" / "playtest_build.json"):
                publish_update.export_shared(
                    "playtest", "https://relay.test", godot="godot",
                    runner=fake_run, cohort=cohort)
            metadata = json.loads((root / "generated" / "playtest_build.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["invite_token"], "secret-cohort-token")
            self.assertEqual(metadata["tester_id"], "PKMN-EEVEE-ABCDEF")
            self.assertEqual(metadata["channel"], "playtest")
            self.assertEqual(metadata["identity_kind"], "cohort")
            self.assertNotIn("nickname", metadata)

    def test_cohort_from_env_derives_the_public_handle(self) -> None:
        token = "stable-shared-token"
        with mock.patch.dict("os.environ", {
            "PLAYTEST_COHORT_INVITE_TOKEN": token,
            "PLAYTEST_COHORT_NICKNAME": "shared-playtest",
        }, clear=False):
            cohort = publish_update.cohort_from_env("playtest")
        self.assertIsNotNone(cohort)
        assert cohort is not None
        self.assertEqual(cohort["token"], token)
        self.assertEqual(cohort["cohort_id"], "playtest")
        self.assertEqual(cohort["nickname"], "shared-playtest")
        self.assertTrue(cohort["tester_id"].startswith("PKMN-"))
        with mock.patch.dict("os.environ", {"PLAYTEST_COHORT_INVITE_TOKEN": ""}, clear=False):
            self.assertIsNone(publish_update.cohort_from_env("playtest"))

    def test_require_cohort_refuses_a_tokenless_distributed_build(self) -> None:
        with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                mock.patch.dict("os.environ", {
                    "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                    "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                    "PLAYTEST_COHORT_INVITE_TOKEN": "",
                }, clear=False):
            with self.assertRaises(SystemExit):
                with mock.patch("sys.argv", ["publish_update.py", "--require-cohort"]):
                    publish_update.main()

    def test_export_writes_empty_endpoint_for_a_public_embed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)

            def fake_run(cmd, check, cwd):  # noqa: ANN001
                Path(cmd[-1]).write_bytes(b"bin")
                return mock.Mock()

            with mock.patch.object(publish_update, "run", side_effect=["a" * 40, "v1"]), \
                    mock.patch.object(publish_update, "ROOT", root), \
                    mock.patch.object(publish_update, "BUILD_INFO",
                                      root / "generated" / "playtest_build.json"):
                publish_update.export_shared(
                    "public", "", godot="godot", runner=fake_run)
            metadata = json.loads((root / "generated" / "playtest_build.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["endpoint"], "")
            self.assertEqual(metadata["invite_token"], "")
            self.assertEqual(metadata["channel"], "public")

    def _embed_public_export(self, channel: str = "public") -> dict:
        return {
            "channel": channel, "build_id": "public-b1", "commit_sha": "c" * 40,
            "version": "v1", "published_at": "2026-08-21T00:00:00Z",
            "artifacts": {
                "linux": {"filename": "PokeWilds-linux.x86_64", "sha256": "c" * 64, "bytes": 1},
                "windows": {"filename": "PokeWilds-windows.exe", "sha256": "d" * 64, "bytes": 1},
                "macos": {"filename": "PokeWilds-macos.zip", "sha256": "e" * 64, "bytes": 1},
            },
        }

    def test_embed_public_writes_empty_stamp_and_skips_relay(self) -> None:
        captured: dict[str, object] = {}

        def fake_export(channel, endpoint, **kwargs):  # noqa: ANN001
            captured["channel"] = channel
            captured["endpoint"] = endpoint
            captured["cohort"] = kwargs.get("cohort")
            return self._embed_public_export(channel)

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                    mock.patch.object(publish_update, "export_shared", side_effect=fake_export), \
                    mock.patch.object(publish_update, "ROOT", root), \
                    mock.patch.object(publish_update, "register_invite") as register, \
                    mock.patch.object(publish_update, "upload_artifacts") as upload, \
                    mock.patch.object(publish_update, "publish_manifest") as publish, \
                    mock.patch.object(publish_update, "godot_binary", return_value="godot"), \
                    mock.patch.object(publish_update, "build_metadata_lock"), \
                    mock.patch.object(publish_update, "BUILD_INFO", root / "playtest_build.json"), \
                    mock.patch.dict("os.environ", {
                        "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                        "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                        "PLAYTEST_COHORT_INVITE_TOKEN": "stable-shared-token",
                    }, clear=False), \
                    mock.patch("sys.argv", ["publish_update.py", "--embed-public", "--channel", "public"]):
                self.assertEqual(publish_update.main(), 0)
            receipt = root / "dist" / "updates" / "public-b1" / "receipt.json"
            dumped = receipt.read_text(encoding="utf-8")
        self.assertEqual(captured["channel"], "public")
        self.assertEqual(captured["endpoint"], "")
        self.assertIsNone(captured["cohort"])
        register.assert_not_called()
        upload.assert_not_called()
        publish.assert_not_called()
        self.assertEqual(set(json.loads(dumped)["artifacts"]), {"linux", "windows", "macos"})
        self.assertNotIn("invite", dumped)
        self.assertNotIn("token", dumped)

    def test_embed_public_succeeds_when_relay_env_is_unset(self) -> None:
        env = {
            key: value for key, value in os.environ.items()
            if key not in {
                "PLAYTEST_FEEDBACK_ENDPOINT",
                "PLAYTEST_FEEDBACK_ADMIN_TOKEN",
                "PLAYTEST_COHORT_INVITE_TOKEN",
            }
        }

        def fake_export(channel, endpoint, **kwargs):  # noqa: ANN001
            self.assertEqual(endpoint, "")
            self.assertIsNone(kwargs.get("cohort"))
            return self._embed_public_export(channel)

        with tempfile.TemporaryDirectory() as raw:
            with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                    mock.patch.object(publish_update, "export_shared", side_effect=fake_export), \
                    mock.patch.object(publish_update, "write_publish_receipt"), \
                    mock.patch.object(publish_update, "register_invite") as register, \
                    mock.patch.object(publish_update, "upload_artifacts") as upload, \
                    mock.patch.object(publish_update, "publish_manifest") as publish, \
                    mock.patch.object(publish_update, "godot_binary", return_value="godot"), \
                    mock.patch.object(publish_update, "build_metadata_lock"), \
                    mock.patch.object(publish_update, "BUILD_INFO", Path(raw) / "playtest_build.json"), \
                    mock.patch.dict("os.environ", env, clear=True), \
                    mock.patch("sys.argv", ["publish_update.py", "--embed-public"]):
                self.assertEqual(publish_update.main(), 0)
        register.assert_not_called()
        upload.assert_not_called()
        publish.assert_not_called()

    def test_receipt_lists_all_three_os_without_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw) / "receipt.json"
            exported = {
                "channel": "playtest",
                "build_id": "playtest-abc1234567-20260821T000000Z",
                "commit_sha": "b" * 40,
                "version": "v1",
                "published_at": "2026-08-21T00:00:00Z",
                "artifacts": {
                    "linux": {"filename": "PokeWilds-linux.x86_64", "sha256": "c" * 64,
                              "bytes": 8, "path": Path("/secret/linux")},
                    "windows": {"filename": "PokeWilds-windows.exe", "sha256": "d" * 64,
                                "bytes": 9, "path": Path("/secret/windows")},
                    "macos": {"filename": "PokeWilds-macos.zip", "sha256": "e" * 64,
                              "bytes": 10, "path": Path("/secret/macos")},
                },
            }
            path = publish_update.write_publish_receipt(exported, dest)
            receipt = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(set(receipt["artifacts"]), {"linux", "windows", "macos"})
            dumped = path.read_text(encoding="utf-8")
            self.assertNotIn("invite", dumped)
            self.assertNotIn("token", dumped)
            self.assertNotIn("/secret/", dumped)

    def test_stage_github_release_assets_uses_stable_names(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            src = Path(raw) / "build"
            dest = Path(raw) / "stage"
            src.mkdir()
            receipt = src / "receipt.json"
            names = {
                "linux": "PokeWilds-playtest-abc-20260821T000000Z-linux.x86_64",
                "windows": "PokeWilds-playtest-abc-20260821T000000Z-windows.exe",
                "macos": "PokeWilds-playtest-abc-20260821T000000Z-macos.zip",
            }
            payloads = {os_name: os_name.encode() for os_name in names}
            for os_name, filename in names.items():
                (src / filename).write_bytes(payloads[os_name])
            receipt.write_text(json.dumps({
                "channel": "playtest",
                "build_id": "playtest-abc-20260821T000000Z",
                "artifacts": {
                    os_name: {"filename": filename, "sha256": "a" * 64, "bytes": 1}
                    for os_name, filename in names.items()
                },
            }), encoding="utf-8")
            staged = publish_update.stage_github_release_assets(receipt, dest)
            self.assertEqual(
                [path.name for path in staged],
                list(publish_update.STABLE_RELEASE_ASSETS.values()),
            )
            for os_name, stable_name in publish_update.STABLE_RELEASE_ASSETS.items():
                self.assertEqual((dest / stable_name).read_bytes(), payloads[os_name])

    def test_publish_registers_the_cohort_invite_before_export(self) -> None:
        order: list[str] = []

        def fake_register(*_args, **_kwargs):  # noqa: ANN001
            order.append("register")

        def fake_export(*_args, **_kwargs):  # noqa: ANN001
            order.append("export")
            return {
                "channel": "playtest", "build_id": "b1", "commit_sha": "c" * 40,
                "version": "v1", "published_at": "2026-08-21T00:00:00Z",
                "artifacts": {},
            }

        with tempfile.TemporaryDirectory() as raw:
            receipt = Path(raw) / "receipt.json"
            with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                    mock.patch.object(publish_update, "validated_endpoint", return_value="https://relay.test"), \
                    mock.patch.object(publish_update, "assert_current_main"), \
                    mock.patch.object(publish_update, "assert_production_relay",
                                      side_effect=lambda *_args, **_kwargs: order.append("relay")), \
                    mock.patch.object(publish_update, "register_invite", side_effect=fake_register), \
                    mock.patch.object(publish_update, "export_shared", side_effect=fake_export), \
                    mock.patch.object(publish_update, "write_publish_receipt",
                                      return_value=receipt) as write_receipt, \
                    mock.patch.object(publish_update, "upload_artifacts",
                                      return_value={}) as upload, \
                    mock.patch.object(publish_update, "publish_manifest") as publish, \
                    mock.patch.object(publish_update, "godot_binary", return_value="godot"), \
                    mock.patch.object(publish_update, "build_metadata_lock"), \
                    mock.patch.object(publish_update, "BUILD_INFO", Path(raw) / "playtest_build.json"), \
                    mock.patch.dict("os.environ", {
                        "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                        "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                        "PLAYTEST_COHORT_INVITE_TOKEN": "stable-shared-token",
                    }, clear=False), \
                    mock.patch("sys.argv", ["publish_update.py", "--require-cohort"]):
                self.assertEqual(publish_update.main(), 0)
        self.assertEqual(order, ["relay", "register", "export"])
        write_receipt.assert_called_once()
        upload.assert_called_once()
        publish.assert_called_once()

    def test_assert_current_main_refuses_when_origin_main_moved(self) -> None:
        def fake_run(*args: str) -> str:
            if args[:3] == ("git", "rev-parse", "origin/main"):
                return "b" * 40
            if args[:3] == ("git", "rev-parse", "HEAD"):
                return "a" * 40
            return ""

        with self.assertRaises(RuntimeError) as ctx:
            publish_update.assert_current_main(git_run=fake_run)
        self.assertIn("stale playtest publish", str(ctx.exception))
        self.assertEqual(
            publish_update.assert_current_main(
                git_run=lambda *args: "a" * 40 if "rev-parse" in args else ""),
            "a" * 40,
        )

    def test_publish_refuses_manifest_when_main_moves(self) -> None:
        checks = {"n": 0}

        def fake_main(*_args, **_kwargs):  # noqa: ANN001
            checks["n"] += 1
            if checks["n"] > 1:
                raise RuntimeError("refusing stale playtest publish a; origin/main is b")
            return "a" * 40

        with tempfile.TemporaryDirectory() as raw:
            receipt = Path(raw) / "receipt.json"
            with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                    mock.patch.object(publish_update, "validated_endpoint", return_value="https://relay.test"), \
                    mock.patch.object(publish_update, "assert_current_main", side_effect=fake_main), \
                    mock.patch.object(publish_update, "assert_production_relay"), \
                    mock.patch.object(publish_update, "register_invite"), \
                    mock.patch.object(publish_update, "export_shared", return_value={
                        "channel": "playtest", "build_id": "b1", "commit_sha": "c" * 40,
                        "version": "v1", "published_at": "2026-08-21T00:00:00Z",
                        "artifacts": {},
                    }), \
                    mock.patch.object(publish_update, "write_publish_receipt", return_value=receipt), \
                    mock.patch.object(publish_update, "upload_artifacts", return_value={}) as upload, \
                    mock.patch.object(publish_update, "publish_manifest") as publish, \
                    mock.patch.object(publish_update, "godot_binary", return_value="godot"), \
                    mock.patch.object(publish_update, "build_metadata_lock"), \
                    mock.patch.object(publish_update, "BUILD_INFO", Path(raw) / "playtest_build.json"), \
                    mock.patch.dict("os.environ", {
                        "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                        "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                        "PLAYTEST_COHORT_INVITE_TOKEN": "stable-shared-token",
                    }, clear=False), \
                    mock.patch("sys.argv", ["publish_update.py", "--require-cohort"]):
                with self.assertRaises(RuntimeError):
                    publish_update.main()
        upload.assert_called_once()
        publish.assert_not_called()

    def test_required_relay_commit_uses_the_latest_relay_touching_sha(self) -> None:
        captured: list[tuple[str, ...]] = []

        def fake_run(*args: str) -> str:
            captured.append(args)
            return "r" * 40

        self.assertEqual(publish_update.required_relay_commit(git_run=fake_run), "r" * 40)
        self.assertEqual(captured[0][:4], ("git", "log", "-1", "--format=%H"))
        self.assertIn("services/feedback-relay", captured[0])
        self.assertIn(".github/workflows/feedback-relay-deploy.yml", captured[0])
        with self.assertRaises(RuntimeError):
            publish_update.required_relay_commit(git_run=lambda *_args: "")

    def test_assert_production_relay_refuses_a_stale_worker(self) -> None:
        captured: list[str] = []

        class FakeResponse:
            status = 200

            def read(self) -> bytes:
                return b'{"ok":true,"environment":"production","report_schema":1,"version_tag":"old"}'

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        def fake_open(request, timeout):  # noqa: ANN001
            captured.append(request.full_url)
            return FakeResponse()

        with self.assertRaises(RuntimeError) as ctx:
            publish_update.assert_production_relay(
                "https://relay.test", "new" * 10, urlopen=fake_open)
        self.assertIn("stale production relay", str(ctx.exception))
        self.assertEqual(captured, ["https://relay.test/healthz"])
        health = publish_update.assert_production_relay(
            "https://relay.test", "old", urlopen=fake_open)
        self.assertEqual(health["version_tag"], "old")
        self.assertFalse(publish_update.production_relay_covers(
            {"ok": True, "environment": "staging", "report_schema": 1, "version_tag": "old"},
            "old",
        ))

    def test_commit_contains_accepts_a_descendant_sha(self) -> None:
        head = publish_update.run("git", "rev-parse", "HEAD")
        parent = publish_update.run("git", "rev-parse", "HEAD^")
        self.assertTrue(publish_update.commit_contains(parent, head))
        self.assertTrue(publish_update.commit_contains(head, head))
        self.assertFalse(publish_update.commit_contains(head, parent))
        self.assertFalse(publish_update.commit_contains("", head))

    def test_assert_production_relay_accepts_a_newer_descendant_worker(self) -> None:
        head = publish_update.run("git", "rev-parse", "HEAD")
        parent = publish_update.run("git", "rev-parse", "HEAD^")
        payload = (
            b'{"ok":true,"environment":"production","report_schema":1,"version_tag":"%s"}'
            % head.encode()
        )

        class FakeResponse:
            status = 200

            def read(self) -> bytes:
                return payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        health = publish_update.assert_production_relay(
            "https://relay.test", parent, urlopen=lambda request, timeout: FakeResponse())
        self.assertEqual(health["version_tag"], head)

    def test_publish_refuses_register_when_production_relay_is_stale(self) -> None:
        def boom(*_args, **_kwargs):  # noqa: ANN001
            raise RuntimeError("refusing stale production relay; wanted version_tag x")

        with mock.patch.object(publish_update, "worktree_is_dirty", return_value=False), \
                mock.patch.object(publish_update, "validated_endpoint", return_value="https://relay.test"), \
                mock.patch.object(publish_update, "assert_current_main"), \
                mock.patch.object(publish_update, "assert_production_relay", side_effect=boom), \
                mock.patch.object(publish_update, "register_invite") as register_invite, \
                mock.patch.object(publish_update, "export_shared") as export_shared, \
                mock.patch.object(publish_update, "build_metadata_lock"), \
                mock.patch.dict("os.environ", {
                    "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                    "PLAYTEST_FEEDBACK_ADMIN_TOKEN": "a" * 32,
                    "PLAYTEST_COHORT_INVITE_TOKEN": "stable-shared-token",
                }, clear=False), \
                mock.patch("sys.argv", ["publish_update.py", "--require-cohort"]):
            with self.assertRaises(RuntimeError):
                publish_update.main()
        register_invite.assert_not_called()
        export_shared.assert_not_called()

    def test_require_production_relay_cli_prints_the_matched_sha(self) -> None:
        required = "d" * 40
        live = "e" * 40
        with mock.patch.object(publish_update, "required_relay_commit", return_value=required), \
                mock.patch.object(publish_update, "assert_production_relay",
                                  return_value={"version_tag": live}) as assert_relay, \
                mock.patch.dict("os.environ", {
                    "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                }, clear=False), \
                mock.patch("sys.argv", ["publish_update.py", "--require-production-relay"]), \
                mock.patch("sys.stdout", new_callable=StringIO) as stdout:
            self.assertEqual(publish_update.main(), 0)
        assert_relay.assert_called_once_with("https://relay.test", required)
        self.assertIn(f"production_relay={live}", stdout.getvalue())

    def test_already_published_commit_matches_latest_sha(self) -> None:
        sha = "a" * 40
        self.assertTrue(publish_update.already_published_commit({"commit_sha": sha}, sha))
        self.assertTrue(publish_update.already_published_commit({"commit_sha": sha.upper()}, sha))
        self.assertFalse(publish_update.already_published_commit({"commit_sha": "b" * 40}, sha))
        self.assertFalse(publish_update.already_published_commit({}, sha))
        self.assertFalse(publish_update.already_published_commit({"commit_sha": sha}, ""))
        publish_update.assert_latest_matches_commit({"commit_sha": sha}, sha)
        with self.assertRaises(RuntimeError) as ctx:
            publish_update.assert_latest_matches_commit({"commit_sha": "b" * 40}, sha)
        self.assertIn("latest commit", str(ctx.exception))

    def test_fetch_latest_reads_the_public_channel_pointer(self) -> None:
        captured: list[str] = []

        class FakeResponse:
            status = 200

            def read(self) -> bytes:
                return b'{"commit_sha":"%s","channel":"playtest"}' % (b"c" * 40)

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        def fake_open(request, timeout):  # noqa: ANN001
            captured.append(request.full_url)
            return FakeResponse()

        latest = publish_update.fetch_latest("https://relay.test", "playtest", urlopen=fake_open)
        self.assertEqual(latest["commit_sha"], "c" * 40)
        self.assertEqual(captured, ["https://relay.test/v1/updates/latest?channel=playtest"])

    def test_fetch_latest_treats_404_as_not_found(self) -> None:
        def fake_open(request, timeout):  # noqa: ANN001
            raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

        with self.assertRaises(publish_update.LatestNotFound):
            publish_update.fetch_latest("https://relay.test", "playtest", urlopen=fake_open)

        def fake_down(request, timeout):  # noqa: ANN001
            raise urllib.error.HTTPError(request.full_url, 503, "down", {}, None)

        with self.assertRaises(RuntimeError) as ctx:
            publish_update.fetch_latest("https://relay.test", "playtest", urlopen=fake_down)
        self.assertIn("HTTP 503", str(ctx.exception))

    def test_already_published_cli_treats_not_found_as_unpublished(self) -> None:
        with mock.patch.object(publish_update, "run", return_value="a" * 40), \
                mock.patch.object(publish_update, "fetch_latest",
                                  side_effect=publish_update.LatestNotFound("latest is not published")), \
                mock.patch.dict("os.environ", {
                    "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                }, clear=False), \
                mock.patch("sys.argv", ["publish_update.py", "--already-published"]), \
                mock.patch("sys.stdout", new_callable=StringIO) as stdout:
            self.assertEqual(publish_update.main(), 0)
        self.assertIn("already_published=false", stdout.getvalue())

    def test_already_published_cli_fails_closed_on_lookup_errors(self) -> None:
        errors = (
            TimeoutError("timed out"),
            RuntimeError("latest returned HTTP 503"),
            json.JSONDecodeError("bad", "x", 0),
        )
        for exc in errors:
            with self.subTest(error=type(exc).__name__):
                with mock.patch.object(publish_update, "run", return_value="a" * 40), \
                        mock.patch.object(publish_update, "fetch_latest", side_effect=exc), \
                        mock.patch.dict("os.environ", {
                            "PLAYTEST_FEEDBACK_ENDPOINT": "https://relay.test",
                        }, clear=False), \
                        mock.patch("sys.argv", ["publish_update.py", "--already-published"]), \
                        mock.patch("sys.stdout", new_callable=StringIO) as stdout, \
                        mock.patch("sys.stderr", new_callable=StringIO) as stderr:
                    self.assertEqual(publish_update.main(), 1)
                self.assertNotIn("already_published=false", stdout.getvalue())
                self.assertIn("latest lookup failed", stderr.getvalue())

    def test_stage_github_release_from_latest_uses_stable_names(self) -> None:
        payloads = {
            "linux": b"L",
            "windows": b"W",
            "macos": b"M",
        }

        class FakeResponse:
            def __init__(self, body: bytes) -> None:
                self._body = body

            def read(self) -> bytes:
                return self._body

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        def fake_open(request, timeout):  # noqa: ANN001
            os_name = request.full_url.rsplit("/", 1)[-1]
            return FakeResponse(payloads[os_name])

        latest = {
            "builds": {
                os_name: {
                    "url": f"https://relay.test/v1/updates/artifacts/playtest/b1/{os_name}",
                    "sha256": hashlib.sha256(body).hexdigest(),
                    "bytes": len(body),
                }
                for os_name, body in payloads.items()
            }
        }
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            staged = publish_update.stage_github_release_from_latest(
                latest, dest, urlopen=fake_open)
            self.assertEqual(
                [path.name for path in staged],
                list(publish_update.STABLE_RELEASE_ASSETS.values()),
            )
            for os_name, stable_name in publish_update.STABLE_RELEASE_ASSETS.items():
                self.assertEqual((dest / stable_name).read_bytes(), payloads[os_name])
            latest["builds"]["linux"]["sha256"] = "0" * 64
            with self.assertRaises(RuntimeError):
                publish_update.stage_github_release_from_latest(
                    latest, dest, urlopen=fake_open)

    def test_release_workflow_contract_accepts_the_committed_file(self) -> None:
        import check_repo_contracts
        root = Path(__file__).resolve().parents[1]
        self.assertEqual(check_repo_contracts.playtest_release_workflow_issues(root), [])
        self.assertEqual(check_repo_contracts.public_release_workflow_issues(root), [])

    def test_playtest_workflow_contract_refuses_v_star_and_missing_prerelease(self) -> None:
        import check_repo_contracts
        root = Path(__file__).resolve().parents[1]
        text = (root / ".github/workflows/playtest-release.yml").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as raw:
            dest_root = Path(raw)
            dest = dest_root / ".github/workflows/playtest-release.yml"
            dest.parent.mkdir(parents=True)
            dest.write_text(
                text.replace('      - "playtest-*"', '      - "v*"').replace(
                    "              --prerelease \\\n", ""),
                encoding="utf-8",
            )
            issues = check_repo_contracts.playtest_release_workflow_issues(dest_root)
        joined = "\n".join(issues)
        self.assertIn("must not trigger on v*", joined)
        self.assertIn("--prerelease", joined)

    def test_wrangler_put_prefixes_configured_bucket(self) -> None:
        captured: list[list[str]] = []

        def fake_run(cmd, check, cwd):  # noqa: ANN001
            captured.append(cmd)
            return mock.Mock()

        with mock.patch.dict("os.environ", {
            "PLAYTEST_UPDATE_R2_BUCKET": "poke-wilds-feedback-private",
        }, clear=False), mock.patch.object(publish_update.subprocess, "run", side_effect=fake_run):
            url = publish_update.wrangler_put(
                "updates/playtest/b1/linux", Path("/tmp/artifact.bin"),
                endpoint="https://relay.test")
        self.assertEqual(url, "https://relay.test/v1/updates/artifacts/playtest/b1/linux")
        self._assert_remote_put(captured[0], "poke-wilds-feedback-private/updates/playtest/b1/linux")
        with self.assertRaises(RuntimeError):
            publish_update.wrangler_put(
                "reports/friends-1/r1/bundle.zip", Path("/tmp/artifact.bin"),
                endpoint="https://relay.test")

    def test_wrangler_put_uses_staging_bucket_for_staging_endpoint(self) -> None:
        captured: list[list[str]] = []

        def fake_run(cmd, check, cwd):  # noqa: ANN001
            captured.append(cmd)
            return mock.Mock()

        staging = "https://poke-wilds-feedback-relay-staging.drake-t.workers.dev"
        with mock.patch.dict("os.environ", {"PLAYTEST_UPDATE_R2_BUCKET": ""}, clear=False), \
                mock.patch.object(publish_update.subprocess, "run", side_effect=fake_run):
            url = publish_update.wrangler_put(
                "updates/playtest/b1/linux", Path("/tmp/artifact.bin"),
                endpoint=staging)
        self.assertEqual(url, f"{staging}/v1/updates/artifacts/playtest/b1/linux")
        self._assert_remote_put(
            captured[0], "poke-wilds-feedback-private-staging/updates/playtest/b1/linux")
        with self.assertRaises(RuntimeError):
            publish_update.resolved_wrangler_env(staging, "production")
        production = "https://poke-wilds-feedback-relay.drake-t.workers.dev"
        with self.assertRaises(RuntimeError):
            publish_update.resolved_wrangler_env(production, "staging")
        self.assertEqual(publish_update.resolved_wrangler_env(staging, "staging"), "staging")
        self.assertEqual(publish_update.resolved_wrangler_env(production, "production"), "")

    def test_windows_helper_restores_old_when_promote_fails(self) -> None:
        body = update_apply._windows_helper_body(
            Path("C:/Users/\u00c9mile/game/PokeWilds.exe"),
            Path("C:/Users/\u00c9mile/game/PokeWilds.exe.new"), 42)
        self.assertIn("if errorlevel 1 goto launch", body)
        self.assertIn('move /y "%~dp0PokeWilds.exe.old" "%~dp0PokeWilds.exe"', body)
        self.assertNotIn("\u00c9mile", body)
        self.assertNotIn("C:/Users", body)
        self.assertIn(":launch", body)
        body.encode("ascii")

    def test_windows_helper_refuses_non_ascii_file_name(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "Jos\u00e9"
            root.mkdir()
            current = root / "Pok\u00e9.exe"
            artifact = root / "new.exe"
            current.write_bytes(b"old")
            artifact.write_bytes(b"new")
            result = update_apply.apply("Windows", artifact, current)
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"], "helper_failed")
            self.assertEqual(current.read_bytes(), b"old")
            self.assertFalse(Path(str(current) + ".new").exists())
            current = root / "PokeWilds.exe"
            current.write_bytes(b"old")
            result = update_apply.apply("Windows", artifact, current)
            self.assertTrue(result["ok"], result)
            body = Path(result["helper"]).read_text(encoding="ascii")
            self.assertIn("%~dp0PokeWilds.exe", body)
            self.assertNotIn("Jos\u00e9", body)
            self.assertTrue(body.isascii())

    def test_configured_r2_bucket_reads_reports_binding(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(publish_update.configured_r2_bucket(), "poke-wilds-feedback-private")
            self.assertEqual(
                publish_update.configured_r2_bucket(environment="staging"),
                "poke-wilds-feedback-private-staging",
            )
            self.assertEqual(
                publish_update.resolved_wrangler_env(
                    "https://poke-wilds-feedback-relay-staging.drake-t.workers.dev"),
                "staging",
            )
            self.assertEqual(
                publish_update.resolved_wrangler_env(
                    "https://poke-wilds-feedback-relay.drake-t.workers.dev"),
                "",
            )


if __name__ == "__main__":
    unittest.main()
