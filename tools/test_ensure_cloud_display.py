#!/usr/bin/env python3
"""Tests for stale-safe Linux Cloud Xvfb startup."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/ensure_cloud_display.sh"


class EnsureCloudDisplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.user_dir = self.base / "user"
        self.fake_bin = self.base / "bin"
        self.socket_dir = self.base / ".X11-unix"
        self.lock_dir = self.base / "locks"
        self.user_dir.mkdir()
        self.fake_bin.mkdir()
        self.socket_dir.mkdir()
        self.lock_dir.mkdir()
        self.live_marker = self.base / "display-live"
        self.xvfb_log = self.base / "xvfb.log"
        self.pid_file = self.base / "xvfb.pid"
        self.env_file = self.user_dir / ".pokewilds-cloud.env"

        self._write_executable(
            self.fake_bin / "xdpyinfo",
            "#!/usr/bin/env bash\n[[ -f \"${FAKE_DISPLAY_LIVE}\" ]]\n",
        )
        self._write_executable(
            self.fake_bin / "Xvfb",
            """#!/usr/bin/env bash
set -euo pipefail
display_num="${1#:}"
lock_file="${POKEWILDS_X11_LOCK_DIR}/.X${display_num}-lock"
if [[ -e "${lock_file}" ]]; then
  printf 'Server is already active for display %s\n' "${display_num}" >&2
  exit 1
fi
printf '%s\n' "$$" > "${lock_file}"
touch "${FAKE_DISPLAY_LIVE}"
""",
        )

    @staticmethod
    def _write_executable(path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    @staticmethod
    def _stop_process(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)

    def _run(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "POKEWILDS_CLOUD_USER_DIR": str(self.user_dir),
                "POKEWILDS_CLOUD_ENV_FILE": str(self.env_file),
                "POKEWILDS_X11_SOCKET_DIR": str(self.socket_dir),
                "POKEWILDS_X11_LOCK_DIR": str(self.lock_dir),
                "POKEWILDS_XVFB_LOG": str(self.xvfb_log),
                "POKEWILDS_XVFB_PID_FILE": str(self.pid_file),
                "FAKE_DISPLAY_LIVE": str(self.live_marker),
            }
        )
        env.pop("DISPLAY", None)
        env.update(overrides)
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_starts_display_and_writes_environment(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("starting Xvfb :99", result.stdout)
        self.assertIn("export DISPLAY=:99", self.env_file.read_text(encoding="utf-8"))

    def test_removes_dead_pid_lock_before_restart(self) -> None:
        lock_file = self.lock_dir / ".X99-lock"
        lock_file.write_text("99999999\n", encoding="utf-8")
        stale_socket = self.socket_dir / "X99"
        stale_socket.write_text("stale\n", encoding="utf-8")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"removing stale {lock_file}", result.stdout)
        self.assertIn(f"removing stale {stale_socket}", result.stdout)
        self.assertTrue(self.live_marker.exists())

    def test_refuses_lock_owned_by_live_process(self) -> None:
        owner = subprocess.Popen(["sleep", "30"])
        self.addCleanup(self._stop_process, owner)
        lock_file = self.lock_dir / ".X99-lock"
        lock_file.write_text(f"{owner.pid}\n", encoding="utf-8")
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lock is owned by live PID", result.stderr)
        self.assertTrue(lock_file.exists())
        self.assertFalse(self.live_marker.exists())

    def test_removes_lock_owned_by_zombie_process(self) -> None:
        owner = subprocess.Popen(["sh", "-c", "exit 0"])
        try:
            time.sleep(0.1)
            lock_file = self.lock_dir / ".X99-lock"
            lock_file.write_text(f"{owner.pid}\n", encoding="utf-8")
            result = self._run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"removing stale {lock_file}", result.stdout)
            self.assertTrue(self.live_marker.exists())
        finally:
            owner.wait(timeout=5)

    def test_refuses_non_numeric_display(self) -> None:
        result = self._run(POKEWILDS_XVFB_DISPLAY="../../bad")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be numeric", result.stderr)


if __name__ == "__main__":
    unittest.main()
