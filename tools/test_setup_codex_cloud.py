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
printf '%s\n' \
  'libfontconfig.so.1 (libc6,x86-64) => /usr/lib/libfontconfig.so.1' \
  'libX11.so.6 (libc6,x86-64) => /usr/lib/libX11.so.6' \
  'libXcursor.so.1 (libc6,x86-64) => /usr/lib/libXcursor.so.1' \
  'libXi.so.6 (libc6,x86-64) => /usr/lib/libXi.so.6' \
  'libXinerama.so.1 (libc6,x86-64) => /usr/lib/libXinerama.so.1' \
  'libXrandr.so.2 (libc6,x86-64) => /usr/lib/libXrandr.so.2' \
  'libXrender.so.1 (libc6,x86-64) => /usr/lib/libXrender.so.1' \
  'libGL.so.1 (libc6,x86-64) => /usr/lib/libGL.so.1'
""",
        )
        self._write_executable(
            self.fake_bin / "Xvfb",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        self._write_executable(
            self.fake_bin / "xdpyinfo",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        self._write_executable(
            self.fake_bin / "node",
            "#!/usr/bin/env bash\nprintf 'v22.22.0\\n'\n",
        )
        self.npm_log = self.base / "npm.log"
        self._write_executable(
            self.fake_bin / "npm",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "list" ]]; then
  [[ -x "${FAKE_LOCAL_PREFIX}/bin/cmd" ]]
  exit
fi
prefix=""
while (($#)); do
  if [[ "$1" == "--prefix" ]]; then
    prefix="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "${prefix}" ]]
mkdir -p "${prefix}/bin"
cat > "${prefix}/bin/cmd" <<'CMD'
#!/usr/bin/env bash
printf '1.26.0\n'
CMD
chmod +x "${prefix}/bin/cmd"
printf 'install\n' >> "${FAKE_NPM_LOG}"
""",
        )
        self.lvp_icd = self.base / "lvp_icd.x86_64.json"
        self.lvp_icd.write_text("{}\n", encoding="utf-8")
        self.apt_log = self.base / "apt.log"
        self._write_executable(
            self.fake_bin / "apt-get",
            """#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_APT_LOG}"
if [[ " $* " == *" install "* ]]; then
  printf '{}\n' > "${CODEX_CLOUD_LVP_ICD}"
fi
""",
        )
        self._write_executable(
            self.fake_bin / "sudo",
            "#!/usr/bin/env bash\nexec \"$@\"\n",
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
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "CODEX_CLOUD_USER_DIR": str(self.home),
                "CODEX_CLOUD_LOCAL_PREFIX": str(self.home / ".local"),
                "CODEX_CLOUD_GODOT_DIR": str(self.home / "godot"),
                "CODEX_CLOUD_GODOT_SHA512": self.fixture_sha,
                "CODEX_CLOUD_LVP_ICD": str(self.lvp_icd),
                "FAKE_GODOT_ZIP": str(self.fixture_zip),
                "FAKE_CURL_LOG": str(self.curl_log),
                "FAKE_LOCAL_PREFIX": str(self.home / ".local"),
                "FAKE_NPM_LOG": str(self.npm_log),
                "FAKE_APT_LOG": str(self.apt_log),
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
        self.assertIn(f"export GODOT_BIN={godot_bin}", env_text)
        self.assertIn("COMMANDCODE_SKIP_UPDATES=1", env_text)
        self.assertTrue((self.home / ".local/bin/cmd").is_file())
        hook = '[ -f "$HOME/.pokewilds-codex-cloud.env" ] && . "$HOME/.pokewilds-codex-cloud.env"'
        self.assertEqual((self.home / ".bashrc").read_text().count(hook), 1)
        self.assertEqual((self.home / ".profile").read_text().count(hook), 1)

    def test_warm_rerun_skips_download_and_keeps_one_shell_hook(self) -> None:
        first = self._run()
        second = self._run()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.curl_log.read_text(encoding="utf-8").splitlines(), ["download"])
        self.assertEqual(self.npm_log.read_text(encoding="utf-8").splitlines(), ["install"])
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

    def test_refuses_old_node_without_nvm(self) -> None:
        self._write_executable(
            self.fake_bin / "node",
            "#!/usr/bin/env bash\nprintf 'v20.20.2\\n'\n",
        )
        result = self._run(CODEX_CLOUD_NVM_DIR=str(self.base / "missing-nvm"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Node 22+", result.stderr)
        self.assertFalse(self.setup_log.exists())

    def test_upgrades_old_node_through_nvm(self) -> None:
        self._write_executable(
            self.fake_bin / "node",
            "#!/usr/bin/env bash\nprintf 'v20.20.2\\n'\n",
        )
        node22_bin = self.base / "node22/bin"
        node22_bin.mkdir(parents=True)
        self._write_executable(
            node22_bin / "node",
            "#!/usr/bin/env bash\nprintf 'v22.22.0\\n'\n",
        )
        nvm_dir = self.base / "nvm"
        nvm_dir.mkdir()
        (nvm_dir / "nvm.sh").write_text(
            """nvm() {
  case "$1" in
    install) return 0 ;;
    use) export PATH="${FAKE_NODE22_BIN}:$PATH" ;;
    *) return 1 ;;
  esac
}
""",
            encoding="utf-8",
        )
        result = self._run(
            CODEX_CLOUD_NVM_DIR=str(nvm_dir),
            FAKE_NODE22_BIN=str(node22_bin),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        env_text = (self.home / ".pokewilds-codex-cloud.env").read_text(
            encoding="utf-8"
        )
        self.assertIn(str(node22_bin), env_text)

    def test_installs_missing_windowed_runtime(self) -> None:
        self.lvp_icd.unlink()
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        apt_calls = self.apt_log.read_text(encoding="utf-8")
        self.assertIn("update -qq", apt_calls)
        self.assertIn("xvfb", apt_calls)
        self.assertIn("mesa-vulkan-drivers", apt_calls)
        self.assertIn("libx11-6", apt_calls)


if __name__ == "__main__":
    unittest.main()
