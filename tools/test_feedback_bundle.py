#!/usr/bin/env python3
"""Pure tests for the private feedback-bundle verifier."""

from __future__ import annotations

import configparser
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import warnings
import zipfile
import stat
import struct
from types import SimpleNamespace
from unittest import mock
import urllib.error
import urllib.request

from feedback_endpoint import _RejectRedirects, open_no_redirect
from fetch_feedback_report import bundle_request, download_bundle, resolve_report_id, transport_hash_matches
from inspect_feedback_bundle import extract_bundle, inspect_bundle
import package_playtest


class FeedbackBundleTests(unittest.TestCase):
    def _bundle(self, root: Path, *, corrupt: bool = False, omit: str = "", omit_report: str = "", report_patch: dict | None = None,
                screenshot: bool = False) -> Path:
        contents = {
            "README.txt": b"Start with report.json\n",
            "engine.log": b"safe log\n",
            "save.json": b"{}\n",
            "trace.jsonl": b'{"event":"boot"}\n',
            "ui-tree.json": b"{}\n",
        }
        if omit:
            contents.pop(omit)
        if screenshot:
            contents["screenshot.png"] = b"not-a-real-png"
        artifacts = [
            {"path": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest(), "truncated": False}
            for name, payload in contents.items()
        ]
        report = {
            "schema_version": 1,
            "report_id": "01234567-89ab-cdef-0123-456789abcdef",
            "created_at_utc": "2026-08-12T12:34:56Z",
            "message": "I got stuck.",
            "tester_id": "T-TEST",
            "install_id": "a" * 32,
            "build": {"version": "0.0.0", "commit_sha": "b" * 40, "build_id": "beta-1", "channel": "friends"},
            "runtime": {"godot_version": "4.6", "os_name": "macOS", "os_version": "15", "architecture": "arm64",
                        "locale": "en_US", "renderer": "gl_compatibility", "adapter": "Apple", "window_size": [1152, 648]},
            "game": {"current_screen": "overworld", "world_seed": 7, "player_tile": [17, 28], "active_area": "field",
                     "time_of_day_minutes": 480, "total_steps": 32, "party": [{"species_id": "geodude"}],
                     "bag": {"items": []}, "battle_active": False},
            "capture": {"screenshot_available": screenshot, "screen": "overworld"},
            "artifacts": artifacts,
        }
        if report_patch:
            report.update(report_patch)
        if omit_report:
            report.pop(omit_report)
        path = root / "report.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("report.json", json.dumps(report))
            for name, payload in contents.items():
                archive.writestr(name, b"tampered" if corrupt and name == "engine.log" else payload)
        return path

    def test_valid_bundle_verifies_and_extracts(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            self.assertEqual(inspect_bundle(bundle)["message"], "I got stuck.")
            output = root / "out"
            extract_bundle(bundle, output)
            self.assertEqual((output / "trace.jsonl").read_bytes(), b'{"event":"boot"}\n')

    def test_corrupt_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaisesRegex(ValueError, "mismatch"):
                inspect_bundle(self._bundle(Path(raw), corrupt=True))

    def test_missing_required_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaisesRegex(ValueError, "entry set"):
                inspect_bundle(self._bundle(Path(raw), omit="save.json"))

    def test_complete_v1_manifest_rejects_missing_fields_wrong_types_and_capture_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with self.assertRaisesRegex(ValueError, "created_at_utc"):
                inspect_bundle(self._bundle(root, omit_report="created_at_utc"))
            with self.assertRaisesRegex(ValueError, "runtime"):
                inspect_bundle(self._bundle(root, report_patch={"runtime": []}))
            with self.assertRaisesRegex(ValueError, "artifact"):
                inspect_bundle(self._bundle(root, report_patch={"artifacts": [{"path": "README.txt", "bytes": 1,
                                                                               "sha256": "0" * 64, "truncated": "false"}]}))
            with self.assertRaisesRegex(ValueError, "capture"):
                inspect_bundle(self._bundle(root, screenshot=True,
                                            report_patch={"capture": {"screenshot_available": False, "screen": "overworld"}}))

    def test_unmanifested_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            rewritten = root / "extra.zip"
            with zipfile.ZipFile(bundle) as source, zipfile.ZipFile(rewritten, "w") as target:
                for name in source.namelist():
                    target.writestr(name, source.read(name))
                target.writestr("screenshot.png", b"png")
            with self.assertRaisesRegex(ValueError, "capture"):
                inspect_bundle(rewritten)

    def test_duplicate_entry_and_existing_destination_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            duplicate = root / "duplicate.zip"
            with zipfile.ZipFile(bundle) as source, zipfile.ZipFile(duplicate, "w") as target:
                for name in source.namelist():
                    target.writestr(name, source.read(name))
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    target.writestr("README.txt", b"duplicate")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                inspect_bundle(duplicate)
            output = root / "existing"
            output.mkdir()
            with self.assertRaisesRegex(ValueError, "already exists"):
                extract_bundle(bundle, output)

    def test_symlink_prone_entry_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            unsafe = root / "unsafe.zip"
            with zipfile.ZipFile(bundle) as source, zipfile.ZipFile(unsafe, "w") as target:
                for info in source.infolist():
                    if info.filename == "engine.log":
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    target.writestr(info, source.read(info.filename))
            with self.assertRaisesRegex(ValueError, "entry type"):
                inspect_bundle(unsafe)

    def test_canonical_zip_validator_rejects_method_and_local_header_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            payload = bytearray(bundle.read_bytes())
            with zipfile.ZipFile(bundle) as archive:
                local_offset = archive.getinfo("engine.log").header_offset
            central_offset = _central_offset(payload)
            struct.pack_into("<H", payload, central_offset + 10, zipfile.ZIP_BZIP2)
            unsupported = root / "unsupported.zip"
            unsupported.write_bytes(payload)
            with self.assertRaisesRegex(ValueError, "compression method"):
                inspect_bundle(unsupported)
            payload = bytearray(bundle.read_bytes())
            struct.pack_into("<I", payload, local_offset + 14, 0x12345678)
            mismatch = root / "mismatch.zip"
            mismatch.write_bytes(payload)
            with self.assertRaisesRegex(ValueError, "local header mismatch"):
                inspect_bundle(mismatch)

    def test_extraction_write_failure_rolls_back_and_clean_retry_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            destination = root / "extracted"
            calls = 0

            def failing_write(path: Path, data: bytes) -> int:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected write failure")
                return path.write_bytes(data)

            with self.assertRaisesRegex(OSError, "injected write failure"):
                extract_bundle(bundle, destination, write_bytes=failing_write)
            self.assertFalse(destination.exists())
            self.assertEqual(list(root.glob(".extracted.extracting-*")), [])
            extract_bundle(bundle, destination)
            self.assertEqual((destination / "trace.jsonl").read_bytes(), b'{"event":"boot"}\n')

    def test_extraction_replace_failure_rolls_back_without_final_destination(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = self._bundle(root)
            destination = root / "extracted"

            def failing_replace(_temporary: Path, _final: Path) -> None:
                raise OSError("injected replace failure")

            with self.assertRaisesRegex(OSError, "injected replace failure"):
                extract_bundle(bundle, destination, replace=failing_replace)
            self.assertFalse(destination.exists())
            self.assertEqual(list(root.glob(".extracted.extracting-*")), [])

    def test_transport_checksum_is_required_and_exact(self) -> None:
        payload = b"private bundle"
        digest = hashlib.sha256(payload).hexdigest()
        self.assertTrue(transport_hash_matches(payload, digest))
        self.assertFalse(transport_hash_matches(payload, ""))
        self.assertFalse(transport_hash_matches(payload, "0" * 64))

    def test_bundle_request_identifies_the_fetch_client(self) -> None:
        request = bundle_request("https://relay.test/", "01234567-89ab-cdef-0123-456789abcdef", "private")
        self.assertEqual(request.full_url, "https://relay.test/v1/admin/reports/01234567-89ab-cdef-0123-456789abcdef/bundle")
        self.assertEqual(request.get_header("User-agent"), "poke-wilds-feedback-fetch/1.0")
        self.assertEqual(request.get_header("Authorization"), "Bearer private")

    def test_fetch_rejects_insecure_endpoints_before_constructing_admin_auth(self) -> None:
        report_id = "01234567-89ab-cdef-0123-456789abcdef"
        for endpoint in ("http://relay.test", "//relay.test", "https://user:pass@relay.test",
                         "https://@relay.test", "https://relay.test?", "https://relay.test#fragment",
                         "https://relay.test:", "https://relay.test:notaport",
                         "https://relay.test/path with space",
                         "https://relay.test\\unsafe"):
            with self.subTest(endpoint=endpoint), self.assertRaisesRegex(ValueError, "HTTPS"):
                bundle_request(endpoint, report_id, "private")

    def test_privileged_feedback_requests_reject_every_redirect(self) -> None:
        request = urllib.request.Request(
            "https://relay.test/private", headers={"Authorization": "placeholder"}
        )
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code), self.assertRaisesRegex(urllib.error.HTTPError, "redirect refused") as raised:
                _RejectRedirects().redirect_request(
                    request, None, code, "Redirect", {}, "http://different-origin.test/private"
                )
            self.assertEqual(raised.exception.code, code)
            raised.exception.close()
        self.assertIs(package_playtest.register_invite.__kwdefaults__["urlopen"], open_no_redirect)
        self.assertIs(download_bundle.__kwdefaults__["urlopen"], open_no_redirect)

    def test_packaging_cleanup_runs_when_export_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_info = root / "generated" / "playtest_build.json"
            build_lock = root / "generated" / ".playtest-package.lock"
            args = SimpleNamespace(friend="Friend", channel="friends-1", endpoint="https://relay.test", target="linux")
            invite = {"tester_id": "T-TEST", "token": "never-print", "nickname": "Friend", "cohort_id": "friends-1"}
            with mock.patch.object(package_playtest, "ROOT", root), \
                    mock.patch.object(package_playtest, "BUILD_INFO", build_info), \
                    mock.patch.object(package_playtest, "BUILD_LOCK", build_lock), \
                    mock.patch.object(package_playtest, "invite_for", return_value=invite), \
                    mock.patch.object(package_playtest, "register_invite"), \
                    mock.patch.object(package_playtest, "run", side_effect=["a" * 40, "v1"]), \
                    mock.patch.object(package_playtest, "godot_binary", return_value="godot"), \
                    mock.patch.object(package_playtest.subprocess, "run", side_effect=RuntimeError("export failed")):
                with self.assertRaisesRegex(RuntimeError, "export failed"):
                    package_playtest.build_package(args, "admin-token-not-printed")
            self.assertFalse(build_info.exists())

    def test_packaging_rejects_insecure_endpoints_before_sending_admin_auth(self) -> None:
        args = SimpleNamespace(friend="Friend", channel="friends-1", endpoint="", target="linux")
        with mock.patch.object(package_playtest, "invite_for") as invite_for, \
                mock.patch.object(package_playtest, "register_invite") as register_invite:
            for endpoint in ("http://relay.test", "//relay.test", "https://user:pass@relay.test",
                             "https://relay.test:"):
                args.endpoint = endpoint
                with self.subTest(endpoint=endpoint), self.assertRaisesRegex(RuntimeError, "HTTPS"):
                    package_playtest.build_package(args, "admin")
        invite_for.assert_not_called()
        register_invite.assert_not_called()

    def test_packaging_lock_preserves_active_build_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            build_info = root / "generated" / "playtest_build.json"
            build_lock = root / "generated" / ".playtest-package.lock"
            args = SimpleNamespace(friend="Friend", channel="friends-1", endpoint="https://relay.test", target="linux")
            invite = {"tester_id": "T-TEST", "token": "private", "nickname": "Friend", "cohort_id": "friends-1"}
            with mock.patch.object(package_playtest, "ROOT", root), \
                    mock.patch.object(package_playtest, "BUILD_INFO", build_info), \
                    mock.patch.object(package_playtest, "BUILD_LOCK", build_lock), \
                    mock.patch.object(package_playtest, "invite_for", return_value=invite), \
                    mock.patch.object(package_playtest, "register_invite"), \
                    mock.patch.object(package_playtest, "run", side_effect=["a" * 40, "v1"]), \
                    package_playtest.build_metadata_lock():
                build_info.write_text("active-owner\n", encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "already running"):
                    package_playtest.build_package(args, "admin")
                self.assertEqual(build_info.read_text(encoding="utf-8"), "active-owner\n")

    def test_release_cleanliness_check_includes_untracked_files(self) -> None:
        with mock.patch.object(package_playtest, "run", return_value="?? scenes/untracked.tscn") as status:
            self.assertTrue(package_playtest.worktree_is_dirty())
        status.assert_called_once_with("git", "status", "--porcelain")

    def test_desktop_export_presets_embed_project_data(self) -> None:
        parser = configparser.ConfigParser()
        parser.read(package_playtest.ROOT / "export_presets.cfg", encoding="utf-8")
        self.assertTrue(parser.getboolean("preset.0.options", "binary_format/embed_pck"))
        self.assertTrue(parser.getboolean("preset.1.options", "binary_format/embed_pck"))

    def test_runtime_bundle_checks_zip_results_and_atomically_repairs_install_id(self) -> None:
        source = (package_playtest.ROOT / "scripts/runtime/feedback_bundle.gd").read_text(encoding="utf-8")
        trace_logger = (package_playtest.ROOT / "scripts/core/trace_logger.gd").read_text(encoding="utf-8")
        self.assertIn("var write_error := packer.write_file", source)
        self.assertIn("var entry_close_error := packer.close_file()", source)
        self.assertIn('if packer.close() != OK:', source)
        self.assertIn('pattern.compile("^[0-9a-f]{32}$")', source)
        self.assertIn("DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary)", source)
        self.assertIn("const MAX_UNCOMPRESSED_BYTES := 24 * 1024 * 1024", source)
        reduction = source[source.index("func _reduce_to_limit"):source.index("func _reduce_trace_middle")]
        self.assertIn("FileAccess.get_file_as_bytes(path).size() > MAX_BUNDLE_BYTES", reduction)
        self.assertIn("or _uncompressed_size(artifacts) > MAX_UNCOMPRESSED_BYTES", reduction)
        bundle_marker = source[source.index("func _reduce_trace_middle"):source.index("func _artifact_manifest")]
        engine_tail = source[source.index("static func _engine_log_slice_at"):source.index("func _write_zip")]
        logger_marker = trace_logger[trace_logger.index('var gap := (JSON.stringify({"event": "feedback_trace_truncated"'):
                                     trace_logger.index("var tail_size :=", trace_logger.index("var gap :="))]
        self.assertIn('"ts_msec": Time.get_ticks_msec()', bundle_marker)
        self.assertIn('"ts_msec": Time.get_ticks_msec()', logger_marker)
        self.assertIn("while first_newline < bytes.size()", engine_tail)
        self.assertLess(engine_tail.index("bytes = bytes.slice(first_newline + 1)"),
                        engine_tail.index("bytes.get_string_from_utf8()"))

    def test_runtime_outbox_checks_sidecar_write_and_retry_scheduler_rescans(self) -> None:
        outbox = (package_playtest.ROOT / "scripts/runtime/feedback_outbox.gd").read_text(encoding="utf-8")
        reporter = (package_playtest.ROOT / "scripts/runtime/feedback_reporter.gd").read_text(encoding="utf-8")
        self.assertIn("var wrote := file.store_string", outbox)
        self.assertIn("var write_error := file.get_error()", outbox)
        self.assertIn("if not wrote or write_error != OK:", outbox)
        self.assertIn('result = {"status": "queued", "reason": "upload_in_progress"}', reporter)
        self.assertIn("func _reconcile_retry_schedule()", reporter)
        self.assertIn("if not _outbox.mark_blocked(prepared, reason):", reporter)
        self.assertIn("_outbox.quarantine_blocked(prepared)", reporter)
        self.assertIn("_session_quarantined[report_id] = true", outbox)
        self.assertIn('metadata["upload_status"] = "sent"', outbox)
        finalize = outbox[outbox.index("func finalize_sent("):outbox.index("func _quarantine_sent(")]
        self.assertLess(finalize.index("_atomic_write_json(metadata_path"), finalize.index("for path in ["))
        self.assertIn("if not _remove(path):", finalize)
        self.assertIn("if _outbox.finalize_sent(prepared", reporter)
        submit = reporter[reporter.index("func submit("):reporter.index("func _upload(")]
        self.assertLess(submit.index("_configuration_error"), submit.index("_outbox.commit"))
        upload = reporter[reporter.index("func _upload("):reporter.index("func retry_pending(")]
        self.assertIn('return {"status": "blocked", "reason": configuration_error}', upload)
        self.assertLess(upload.index("_configuration_error"), upload.index("_http.request_raw"))
        self.assertIn("_http.max_redirects = 0", reporter)
        self.assertIn("HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED", upload)
        self.assertIn("_endpoint_authority_valid(authority)", reporter)
        self.assertIn('result = {"status": "sent_cleanup_failed"', reporter)
        retry = reporter[reporter.index("func retry_pending("):reporter.index("func _persist_blocked(")]
        self.assertNotIn('elif result.get("status") == "queued":\n\t\t\tbreak', retry)
        self.assertNotIn("\t\t\t_retry_timer.stop()", reporter)

    def test_private_retry_route_is_committed_last_and_never_uploaded(self) -> None:
        outbox = (package_playtest.ROOT / "scripts/runtime/feedback_outbox.gd").read_text(encoding="utf-8")
        reporter = (package_playtest.ROOT / "scripts/runtime/feedback_reporter.gd").read_text(encoding="utf-8")
        commit = outbox[outbox.index("func commit("):outbox.index("func pending(")]
        self.assertLess(commit.index("_atomic_write_json(route_path"), commit.index("_atomic_write_json(metadata_path"))
        self.assertIn('"route_path": route_path', outbox)
        self.assertIn('_remove(str(prepared.get("route_path", "")))', outbox)
        self.assertIn('var metadata_json := JSON.stringify(prepared["metadata"])', reporter)
        self.assertNotIn('JSON.stringify(prepared["build"])', reporter)

    def test_explicit_request_timeout_remains_retryable(self) -> None:
        reporter = (package_playtest.ROOT / "scripts/runtime/feedback_reporter.gd").read_text(encoding="utf-8")
        self.assertIn("code == 202 or code == 408 or code == 429", reporter)

    def test_public_tester_id_is_stable_pokemon_themed_and_token_only(self) -> None:
        first = package_playtest.public_tester_id("opaque-token-one")
        self.assertEqual(first, package_playtest.public_tester_id("opaque-token-one"))
        self.assertNotEqual(first, package_playtest.public_tester_id("opaque-token-two"))
        self.assertRegex(first, r"^PKMN-[A-Z]+-[A-F0-9]{6}$")
        self.assertLessEqual(len(first), 24)
        self.assertTrue(any(f"-{species}-" in first for species in package_playtest.POKEMON_HANDLE_SPECIES))

    def test_private_registry_is_mode_0600_and_atomically_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            registry = Path(raw) / ".playtest" / "invites.json"
            with mock.patch.object(package_playtest, "REGISTRY", registry):
                package_playtest.save_registry({"schema_version": 1, "friends": {}})
            if package_playtest.os.name != "nt":
                self.assertEqual(stat.S_IMODE(registry.stat().st_mode), stat.S_IRUSR | stat.S_IWUSR)
            self.assertEqual(json.loads(registry.read_text(encoding="utf-8")), {"schema_version": 1, "friends": {}})
            self.assertEqual(list(registry.parent.glob(".*.tmp")), [])

    def test_private_registry_is_secured_before_contents_are_written(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            registry = Path(raw) / ".playtest" / "invites.json"

            def assert_empty(path: Path) -> None:
                self.assertEqual(path.read_bytes(), b"")

            with (
                mock.patch.object(package_playtest, "REGISTRY", registry),
                mock.patch.object(package_playtest, "_secure_private_file", side_effect=assert_empty),
            ):
                package_playtest.save_registry({"schema_version": 1, "friends": {}})
            self.assertEqual(json.loads(registry.read_text(encoding="utf-8")), {"schema_version": 1, "friends": {}})

    def test_private_registry_acl_failure_removes_the_temporary_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            registry = Path(raw) / ".playtest" / "invites.json"
            with (
                mock.patch.object(package_playtest, "REGISTRY", registry),
                mock.patch.object(package_playtest, "_secure_private_file", side_effect=RuntimeError("timeout")),
                self.assertRaisesRegex(RuntimeError, "timeout"),
            ):
                package_playtest.save_registry({"schema_version": 1, "friends": {}})
            self.assertEqual(list(registry.parent.glob(".*.tmp")), [])

    def test_windows_private_registry_removes_inheritance_and_grants_only_the_owner(self) -> None:
        runner = mock.Mock()
        package_playtest._secure_private_file(
            Path("private.json"),
            platform="nt",
            identity=r"DOMAIN\Player",
            runner=runner,
        )
        runner.assert_called_once_with(
            ["icacls", "private.json", "/inheritance:r", "/grant:r", r"DOMAIN\Player:(F)"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )

    def test_windows_private_registry_timeout_is_bounded(self) -> None:
        runner = mock.Mock(side_effect=subprocess.TimeoutExpired("icacls", 10))
        with self.assertRaisesRegex(RuntimeError, "timed out securing"):
            package_playtest._secure_private_file(
                Path("private.json"),
                platform="nt",
                identity=r"DOMAIN\Player",
                runner=runner,
            )

    def test_invite_registration_identifies_the_package_client(self) -> None:
        invite = {"tester_id": "PKMN-EEVEE-ABCDEF", "token": "private", "nickname": "Friend", "cohort_id": "friends-1"}
        captured = []

        class Response:
            status = 201

            def __enter__(self):
                return self

            def __exit__(self, *_args) -> None:
                return None

        def urlopen(request, *, timeout: int):
            captured.append((request, timeout))
            return Response()

        package_playtest.register_invite("https://relay.test/", "admin", invite, urlopen=urlopen)
        self.assertEqual(captured[0][0].get_header("User-agent"), "poke-wilds-playtest-package/1.0")
        self.assertEqual(captured[0][0].get_header("Authorization"), "Bearer admin")

    def test_report_uuid_is_accepted_directly(self) -> None:
        self.assertEqual(
            resolve_report_id("01234567-89AB-CDEF-0123-456789ABCDEF"),
            "01234567-89ab-cdef-0123-456789abcdef",
        )

    def test_issue_url_resolves_hidden_report_marker_without_authentication(self) -> None:
        report_id = "01234567-89ab-cdef-0123-456789abcdef"
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args) -> None:
                return None

            def read(self) -> bytes:
                return json.dumps({"body": f"<!-- feedback-report-id:{report_id} -->"}).encode()

        def urlopen(request, *, timeout: int):
            requests.append((request, timeout))
            return Response()

        self.assertEqual(
            resolve_report_id("https://github.com/example/poke-wilds/issues/42", urlopen=urlopen), report_id
        )
        self.assertEqual(requests[0][0].full_url, "https://api.github.com/repos/example/poke-wilds/issues/42")
        self.assertNotIn("Authorization", requests[0][0].headers)

    def test_issue_url_rejects_missing_marker_and_malformed_url(self) -> None:
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args) -> None:
                return None

            def read(self) -> bytes:
                return b'{"body":"No private report marker here."}'

        with self.assertRaisesRegex(ValueError, "marker"):
            resolve_report_id("https://github.com/example/poke-wilds/issues/42", urlopen=lambda *_args, **_kwargs: Response())
        with self.assertRaisesRegex(ValueError, "UUID or public GitHub issue URL"):
            resolve_report_id("https://github.com/example/poke-wilds/pull/42")


def _central_offset(payload: bytes) -> int:
    for offset in range(len(payload) - 22, -1, -1):
        if payload[offset:offset + 4] == b"PK\x05\x06":
            return struct.unpack_from("<I", payload, offset + 16)[0]
    raise AssertionError("missing EOCD")


if __name__ == "__main__":
    unittest.main()
