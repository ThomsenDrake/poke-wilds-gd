#!/usr/bin/env python3
"""Tests for the dedicated Codex Cloud Linux setup entry point."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/setup_codex_cloud.sh"


class CodexCloudSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.home = self.base / "home"
        self.fake_bin = self.base / "bin"
        (self.repo / "tools").mkdir(parents=True)
        self.home.mkdir()
        self.fake_bin.mkdir()
        shutil.copy2(SCRIPT, self.repo / "tools/setup_codex_cloud.sh")
        self._write_executable(
            self.repo / "tools/setup_worktree.py",
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
Path(os.environ["SETUP_LOG"]).write_text(json.dumps(sys.argv[1:]))
raise SystemExit(int(os.environ.get("SETUP_EXIT", "0")))
""",
        )
        self._write_executable(
            self.fake_bin / "uname",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
  printf '%s\n' "${FAKE_UNAME_S:-Linux}"
elif [[ "${1:-}" == "-m" ]]; then
  printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
else
  printf '%s\n' "${FAKE_UNAME_S:-Linux}"
fi
""",
        )
        self._write_executable(
            self.fake_bin / "ldconfig",
            """#!/usr/bin/env bash
printf '%s\n' 'libfontconfig.so.1 (libc6,x86-64) => /usr/lib/libfontconfig.so.1'
""",
        )
        self.curl_log = self.base / "curl.log"
        self._write_executable(
            self.fake_bin / "curl",
            """#!/usr/bin/env bash
set -euo pipefail
output=""
while (($#)); do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
cp "${FAKE_GODOT_ZIP}" "${output}"
printf 'download\n' >> "${FAKE_CURL_LOG}"
""",
        )
        self.fixture_zip = self.base / "godot.zip"
        with zipfile.ZipFile(self.fixture_zip, "w") as archive:
            archive.writestr(
                "Godot_v4.6.1-stable_linux.x86_64",
                "#!/usr/bin/env bash\nprintf '4.6.1.stable.official.test\\n'\n",
            )
        self.fixture_sha = hashlib.sha512(self.fixture_zip.read_bytes()).hexdigest()
        self.setup_log = self.base / "setup.json"

    @staticmethod
    def _write_executable(path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "CODEX_CLOUD_GODOT_DIR": str(self.home / "godot"),
                "CODEX_CLOUD_GODOT_SHA512": self.fixture_sha,
                "FAKE_GODOT_ZIP": str(self.fixture_zip),
                "FAKE_CURL_LOG": str(self.curl_log),
                "SETUP_LOG": str(self.setup_log),
            }
        )
        env.update(overrides)
        return subprocess.run(
            ["bash", "tools/setup_codex_cloud.sh"],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_installs_persists_and_runs_full_bootstrap(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        godot_bin = self.home / "godot/godot"
        self.assertTrue(godot_bin.is_file())
        self.assertEqual(
            json.loads(self.setup_log.read_text(encoding="utf-8")),
            ["--godot-bin", str(godot_bin)],
        )
        env_text = (self.home / ".pokewilds-codex-cloud.env").read_text(
            encoding="utf-8"
        )
        self.assertIn(f'export GODOT_BIN="{godot_bin}"', env_text)
        hook = '[ -f "$HOME/.pokewilds-codex-cloud.env" ] && . "$HOME/.pokewilds-codex-cloud.env"'
        self.assertEqual((self.home / ".bashrc").read_text().count(hook), 1)
        self.assertEqual((self.home / ".profile").read_text().count(hook), 1)

    def test_warm_rerun_skips_download_and_keeps_one_shell_hook(self) -> None:
        first = self._run()
        second = self._run()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.curl_log.read_text(encoding="utf-8").splitlines(), ["download"])
        hook = '[ -f "$HOME/.pokewilds-codex-cloud.env" ] && . "$HOME/.pokewilds-codex-cloud.env"'
        self.assertEqual((self.home / ".bashrc").read_text().count(hook), 1)

    def test_refuses_non_linux_host(self) -> None:
        result = self._run(FAKE_UNAME_S="Darwin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Linux", result.stderr)
        self.assertFalse(self.setup_log.exists())

    def test_refuses_wrong_architecture(self) -> None:
        result = self._run(FAKE_UNAME_M="aarch64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires x86_64", result.stderr)
        self.assertFalse(self.setup_log.exists())

    def test_refuses_archive_checksum_mismatch(self) -> None:
        result = self._run(CODEX_CLOUD_GODOT_SHA512="0" * 128)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse((self.home / "godot/godot").exists())
        self.assertFalse(self.setup_log.exists())

    def test_propagates_repo_bootstrap_failure(self) -> None:
        result = self._run(SETUP_EXIT="7")
        self.assertEqual(result.returncode, 7)


if __name__ == "__main__":
    unittest.main()
