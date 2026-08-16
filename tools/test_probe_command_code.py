#!/usr/bin/env python3
"""Tests for the secret-safe Command Code connectivity probe."""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_command_code


class CommandCodeProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.cmd = self.base / "cmd"

    def _write_cmd(self, body: str) -> None:
        self.cmd.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        self.cmd.chmod(self.cmd.stat().st_mode | stat.S_IXUSR)

    def _main(self) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": str(self.base)}, clear=False):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = probe_command_code.main(["--timeout", "5"])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_success_requires_exact_token(self) -> None:
        self._write_cmd("printf 'COMMAND_CODE_CONNECTIVITY_OK\\n'\n")
        code, stdout, stderr = self._main()
        self.assertEqual(code, 0, stderr)
        self.assertIn("API/model connectivity ready", stdout)

    def test_network_failure_names_required_host_without_raw_output(self) -> None:
        self._write_cmd(
            "printf 'Error: Unable to connect to the API. secret-marker' >&2\nexit 6\n"
        )
        code, _stdout, stderr = self._main()
        self.assertEqual(code, 1)
        self.assertIn("check Node proxy/system-CA support", stderr)
        self.assertNotIn("secret-marker", stderr)

    def test_auth_failure_is_classified_without_raw_output(self) -> None:
        self._write_cmd("printf 'Unauthorized secret-marker' >&2\nexit 7\n")
        code, _stdout, stderr = self._main()
        self.assertEqual(code, 1)
        self.assertIn("authentication failed", stderr)
        self.assertNotIn("secret-marker", stderr)

    def test_unexpected_success_response_is_not_echoed(self) -> None:
        self._write_cmd("printf 'unexpected-secret-marker\\n'\n")
        code, _stdout, stderr = self._main()
        self.assertEqual(code, 1)
        self.assertIn("unexpected response", stderr)
        self.assertNotIn("unexpected-secret-marker", stderr)


if __name__ == "__main__":
    unittest.main()
