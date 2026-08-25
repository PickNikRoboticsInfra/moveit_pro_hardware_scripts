#!/usr/bin/env python3
"""Tests for the version-aware ExecStart wrapper.

Below 10.x the launcher aborts without a DISPLAY unless --headless is passed;
10.x renders through EGL and gives --headless an unrelated meaning. The wrapper
picks the flag from the installed version. The real CLI is replaced
here with a stub that reports a version and echoes the arguments it receives.
Run with:

    python3 -m unittest discover -s test
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

WRAPPER = Path(__file__).resolve().parent.parent / "bin" / "moveit-pro-run"

# Mirrors `moveit_pro --version` on both supported series.
# Shell braces rule out str.format here, so the placeholder is substituted directly.
STUB = """#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  @VERSION_BEHAVIOR@
fi
echo "ARGS: $*"
"""


def _make_stub(tmpdir, version_behavior):
    path = Path(tmpdir) / "moveit_pro_stub"
    path.write_text(STUB.replace("@VERSION_BEHAVIOR@", version_behavior))
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


def _run(stub, *args):
    env = dict(os.environ, MOVEIT_PRO_CLI=str(stub))
    return subprocess.run(
        [str(WRAPPER), *args], capture_output=True, text=True, env=env, timeout=30
    )


class TestVersionAwareFlag(unittest.TestCase):
    def _args_for_version(self, line):
        with tempfile.TemporaryDirectory() as tmp:
            stub = _make_stub(tmp, f'echo "{line}"; exit 0')
            result = _run(stub)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_9_4_gets_the_flag(self):
        self.assertIn("--headless", self._args_for_version("MoveIt Pro version: 9.4.2"))

    def test_10_x_does_not_get_the_flag(self):
        # On 10.x --headless suppresses driver X11 forwarding, which is not wanted.
        self.assertNotIn(
            "--headless", self._args_for_version("MoveIt Pro version: 10.0.0-rc11")
        )

    def test_a_release_candidate_below_10_still_gets_the_flag(self):
        self.assertIn(
            "--headless", self._args_for_version("MoveIt Pro version: 9.4.3-rc1")
        )

    def test_a_future_major_does_not_get_the_flag(self):
        self.assertNotIn(
            "--headless", self._args_for_version("MoveIt Pro version: 11.0.0")
        )

    def test_run_and_verbose_are_always_passed(self):
        args = self._args_for_version("MoveIt Pro version: 10.0.0")
        self.assertIn("run", args)
        self.assertIn("-v", args)


class TestDegradedVersionLookup(unittest.TestCase):
    """An unreadable version must omit the flag: on 10.x it would be fatal."""

    def _stdout_stderr(self, version_behavior):
        with tempfile.TemporaryDirectory() as tmp:
            stub = _make_stub(tmp, version_behavior)
            result = _run(stub)
        return result

    def test_nonzero_version_exit_omits_the_flag_and_still_runs(self):
        result = self._stdout_stderr("exit 3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--headless", result.stdout)

    def test_unparseable_version_omits_the_flag_and_warns(self):
        result = self._stdout_stderr('echo "something else entirely"; exit 0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--headless", result.stdout)
        self.assertIn("omitting --headless", result.stderr)

    def test_extra_arguments_are_forwarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = _make_stub(tmp, 'echo "MoveIt Pro version: 10.0.0"; exit 0')
            result = _run(stub, "--config-package", "lab_sim")
        self.assertIn("--config-package lab_sim", result.stdout)


if __name__ == "__main__":
    unittest.main()
