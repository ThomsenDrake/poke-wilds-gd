from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest import mock

import setup_worktree


class SetupWorktreeTests(unittest.TestCase):
    def test_quick_mode_skips_heavy_work(self) -> None:
        args = setup_worktree._parse_args(["--quick"])
        self.assertTrue(args.quick)
        self.assertTrue(args.skip_cache)
        self.assertTrue(args.skip_import)
        self.assertIsNone(args.seed_from)

    def test_quick_mode_refuses_cache_seed(self) -> None:
        with mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                setup_worktree._parse_args(["--quick", "--seed-from", "/tmp/warm"])

    def test_quick_mode_never_enters_shared_lock_or_heavy_operations(self) -> None:
        with (
            mock.patch.object(setup_worktree, "_worktree_root", return_value=setup_worktree.ROOT),
            mock.patch.object(setup_worktree, "_tracked_state", return_value={}),
            mock.patch.object(setup_worktree, "_check_versions", return_value="/godot"),
            mock.patch.object(setup_worktree, "_refuse_shared_cache_links"),
            mock.patch.object(setup_worktree, "_setup_lock") as setup_lock,
            mock.patch.object(setup_worktree, "_prepare_pokeapi_cache") as prepare_cache,
            mock.patch.object(setup_worktree, "_import_resources") as import_resources,
        ):
            self.assertEqual(setup_worktree.run(["--quick"]), 0)
        setup_lock.assert_not_called()
        prepare_cache.assert_not_called()
        import_resources.assert_not_called()

    def test_full_import_silences_progress_but_preserves_errors(self) -> None:
        root = Path("/tmp/worktree")
        with mock.patch.object(setup_worktree, "_run") as run_command:
            setup_worktree._import_resources(
                root, "/godot", timeout=30, dry_run=False
            )
        argv = run_command.call_args.args[0]
        self.assertEqual(argv[:3], ["/godot", "--quiet", "--headless"])

    def test_godot_version_pin(self) -> None:
        self.assertTrue(setup_worktree.is_supported_godot_version(
            "4.6.1.stable.official.14d19694e"))
        self.assertFalse(setup_worktree.is_supported_godot_version("4.6-stable"))
        self.assertFalse(setup_worktree.is_supported_godot_version("4.7.0.stable"))

    def test_api_cache_requires_the_importer_sentinel(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertFalse(setup_worktree._api_cache_complete(root))
            sentinel = root / setup_worktree.POKEAPI_SENTINEL
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("{}", encoding="utf-8")
            self.assertTrue(setup_worktree._api_cache_complete(root))

    def test_pinned_api_cache_requires_matching_setup_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pin_sha = "a" * 40
            pin = root / "tools/api_data_pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text('{"sha": "' + pin_sha + '"}', encoding="utf-8")
            sentinel = root / setup_worktree.POKEAPI_SENTINEL
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("{}", encoding="utf-8")
            self.assertFalse(setup_worktree._pinned_api_cache_ready(root))
            stamp = root / setup_worktree.POKEAPI_STAMP
            stamp.write_text(pin_sha + "\n", encoding="utf-8")
            self.assertTrue(setup_worktree._pinned_api_cache_ready(root))
            stamp.write_text("b" * 40 + "\n", encoding="utf-8")
            self.assertFalse(setup_worktree._pinned_api_cache_ready(root))

    def test_pokeapi_seed_requires_identical_committed_pin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = base / "source"
            target = base / "target"
            (source / "tools").mkdir(parents=True)
            (target / "tools").mkdir(parents=True)
            (source / "tools/api_data_pin.json").write_text("same", encoding="utf-8")
            (target / "tools/api_data_pin.json").write_text("same", encoding="utf-8")
            self.assertTrue(setup_worktree._pins_match(source, target))
            (target / "tools/api_data_pin.json").write_text("different", encoding="utf-8")
            self.assertFalse(setup_worktree._pins_match(source, target))

    def test_tracked_fingerprint_detects_changes_to_preexisting_dirty_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tracked = root / "already-dirty.txt"
            tracked.write_text("before", encoding="utf-8")
            before = setup_worktree._fingerprint_paths(root, {tracked.name})
            tracked.write_text("after", encoding="utf-8")
            after = setup_worktree._fingerprint_paths(root, {tracked.name})
            self.assertEqual(
                setup_worktree.changed_tracked_state(before, after), [tracked.name]
            )

    def test_tracked_state_reports_new_and_deleted_paths(self) -> None:
        before = {"deleted.txt": "file:0:a"}
        after = {"new.txt": "file:0:b"}
        self.assertEqual(
            setup_worktree.changed_tracked_state(before, after),
            ["deleted.txt", "new.txt"],
        )

    def test_cache_seed_is_an_independent_copy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            target = root / "target"
            source.mkdir()
            (source / "value.txt").write_text("source", encoding="utf-8")
            setup_worktree._copy_cache_tree(source, target, dry_run=False)
            (target / "value.txt").write_text("target", encoding="utf-8")
            self.assertEqual((source / "value.txt").read_text(encoding="utf-8"), "source")
            self.assertEqual((target / "value.txt").read_text(encoding="utf-8"), "target")

    def test_shared_writable_cache_symlink_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared"
            shared.mkdir()
            (root / ".godot").symlink_to(shared, target_is_directory=True)
            with self.assertRaises(setup_worktree.SetupError) as raised:
                setup_worktree._refuse_shared_cache_links(root)
            self.assertEqual(raised.exception.code, "shared_cache_symlink_refused")


if __name__ == "__main__":
    unittest.main()
