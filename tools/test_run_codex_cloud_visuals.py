#!/usr/bin/env python3
"""Tests for the Codex Cloud windowed Command Code launcher."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/run_codex_cloud_visuals.sh"
PROBE = ROOT / "tools/probe_command_code.py"


class CodexCloudVisualLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.user_dir = self.base / "user"
        self.fake_bin = self.base / "bin"
        (self.repo / "tools").mkdir(parents=True)
        self.user_dir.mkdir()
        self.fake_bin.mkdir()
        shutil.copy2(SCRIPT, self.repo / "tools/run_codex_cloud_visuals.sh")
        shutil.copy2(PROBE, self.repo / "tools/probe_command_code.py")

        self.godot = self.user_dir / "godot"
        self._write_executable(
            self.godot,
            "#!/usr/bin/env bash\nprintf '4.6.1.stable.official.test\\n'\n",
        )
        self._write_executable(
            self.fake_bin / "uname",
            "#!/usr/bin/env bash\nprintf 'Linux\\n'\n",
        )
        self._write_executable(
            self.fake_bin / "xdpyinfo",
            "#!/usr/bin/env bash\n[[ \"${DISPLAY:-}\" == \":99\" ]]\n",
        )
        self._write_executable(
            self.fake_bin / "cmd",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '1.26.0\n'
else
  printf 'COMMAND_CODE_CONNECTIVITY_OK\n'
fi
""",
        )
        self.python_log = self.base / "python.json"
        self._write_executable(
            self.fake_bin / "python3",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "tools/probe_command_code.py" ]]; then
  exec "${FAKE_REAL_PYTHON}" "$@"
fi
python_args=("$@")
printf '%s\n' "${VLM_RUNTIME:-}" "${VLM_REQUIRED:-}" "${POKEWILDS_COMMAND_CODE_PREFLIGHTED:-}" "${GODOT_AUDIO_DRIVER:-}" > "${FAKE_ENV_LOG}"
printf '%s\n' "${python_args[@]}" > "${FAKE_PYTHON_LOG}"
""",
        )
        self.env_log = self.base / "env.log"
        self.setup_env = self.user_dir / ".pokewilds-codex-cloud.env"
        self.setup_env.write_text(
            f"export GODOT_BIN={self.godot}\n"
            f"export PATH={self.fake_bin}:$PATH\n",
            encoding="utf-8",
        )
        self._write_executable(
            self.repo / "tools/ensure_cloud_display.sh",
            """#!/usr/bin/env bash
printf 'export DISPLAY=:99\n' > "${POKEWILDS_CLOUD_ENV_FILE}"
printf 'export GODOT_AUDIO_DRIVER=Dummy\n' >> "${POKEWILDS_CLOUD_ENV_FILE}"
""",
        )

    @staticmethod
    def _write_executable(path: Path, text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run(self, *args: str, auth: bool = True, **overrides: str) -> subprocess.CompletedProcess[str]:
        runtime_env = self.user_dir / ".pokewilds-cloud.env"
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "CODEX_CLOUD_USER_DIR": str(self.user_dir),
                "CODEX_CLOUD_ENV_FILE": str(self.setup_env),
                "POKEWILDS_CLOUD_ENV_FILE": str(runtime_env),
                "FAKE_PYTHON_LOG": str(self.python_log),
                "FAKE_ENV_LOG": str(self.env_log),
                "FAKE_REAL_PYTHON": sys.executable,
            }
        )
        if auth:
            env["COMMAND_CODE_API_KEY"] = "test-only-placeholder"
        else:
            env.pop("COMMAND_CODE_API_KEY", None)
        env.update(overrides)
        return subprocess.run(
            ["bash", "tools/run_codex_cloud_visuals.sh", *args],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_check_only_verifies_readiness(self) -> None:
        result = self._run("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("visual preflight: ready", result.stdout)
        self.assertFalse(self.python_log.exists())

    def test_full_runs_windowed_gate_with_command_code(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.python_log.read_text(encoding="utf-8").splitlines(),
            ["tools/verify_all.py", "--windowed-timeout", "1800"],
        )
        self.assertEqual(
            self.env_log.read_text(encoding="utf-8").splitlines(),
            ["command_code", "1", "1", "Dummy"],
        )

    def test_focused_runs_visual_sweep(self) -> None:
        result = self._run("--focused", "--timeout", "42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.python_log.read_text(encoding="utf-8").splitlines(),
            [
                "tools/run_playtests.py",
                "--scenario",
                "visual_sweep",
                "--report",
                ".godot-smoke/visual-sweep-command-code.json",
                "--timeout",
                "42",
            ],
        )

    def test_refuses_missing_runtime_auth(self) -> None:
        result = self._run("--check", auth=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("secrets are setup-only", result.stderr)
        self.assertFalse(self.python_log.exists())

    def test_refuses_forced_headless_transport(self) -> None:
        result = self._run("--check", PLAYTEST_FORCE_HEADLESS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PLAYTEST_FORCE_HEADLESS is set", result.stderr)

    def test_fails_before_capture_when_command_code_cannot_reach_api(self) -> None:
        self._write_executable(
            self.fake_bin / "cmd",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '1.26.0\n'
else
  printf 'Error: Unable to connect to the API. secret-marker\n' >&2
  exit 6
fi
""",
        )
        result = self._run("--focused")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must allow api.commandcode.ai over HTTPS, including POST", result.stderr)
        self.assertNotIn("secret-marker", result.stderr)
        self.assertFalse(self.python_log.exists())


if __name__ == "__main__":
    unittest.main()
