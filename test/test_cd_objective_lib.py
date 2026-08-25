#!/usr/bin/env python3
"""Tests for the CD objective runner's command construction and failure paths.

Network-free and container-free: `moveit_pro shell` is stubbed so the retry,
timeout, and failure branches are exercised deterministically. Run with:

    python3 -m unittest discover -s test
"""

import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "example_scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))

import cd_objective_lib  # noqa: E402


def _completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


ACTION_LIST_WITH_SERVER = "/do_objective\n/other_action\n"


class TestProShell(unittest.TestCase):
    def test_invokes_the_cli_shell_subcommand(self):
        with mock.patch.object(cd_objective_lib.subprocess, "run") as run:
            run.return_value = _completed()
            cd_objective_lib._pro_shell(["ros2", "action", "list"], 5)
        argv = run.call_args[0][0]
        self.assertEqual(argv[:2], [cd_objective_lib.MOVEIT_PRO_CLI, "shell"])
        self.assertEqual(argv[2:], ["ros2", "action", "list"])

    def test_timeout_returns_none_rather_than_raising(self):
        with mock.patch.object(
            cd_objective_lib.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("x", 1),
        ):
            self.assertIsNone(cd_objective_lib._pro_shell(["true"], 1))


class TestWaitForActionServer(unittest.TestCase):
    def test_returns_once_the_action_is_advertised(self):
        with mock.patch.object(
            cd_objective_lib,
            "_pro_shell",
            return_value=_completed(stdout=ACTION_LIST_WITH_SERVER),
        ):
            cd_objective_lib._wait_for_action_server(
                cd_objective_lib.time.monotonic() + 60
            )

    def test_retries_until_the_action_appears(self):
        responses = [
            _completed(returncode=1),
            _completed(stdout="/other_action\n"),
            _completed(stdout=ACTION_LIST_WITH_SERVER),
        ]
        with mock.patch.object(
            cd_objective_lib, "_pro_shell", side_effect=responses
        ) as shell, mock.patch.object(cd_objective_lib.time, "sleep"):
            cd_objective_lib._wait_for_action_server(
                cd_objective_lib.time.monotonic() + 60
            )
        self.assertEqual(shell.call_count, 3)

    def test_a_substring_match_does_not_count_as_the_action(self):
        # "/do_objective_other" must not satisfy the wait for "/do_objective".
        with mock.patch.object(
            cd_objective_lib,
            "_pro_shell",
            return_value=_completed(stdout="/do_objective_other\n"),
        ), mock.patch.object(cd_objective_lib.time, "sleep"), mock.patch.object(
            cd_objective_lib, "_fail", side_effect=SystemExit
        ) as fail:
            with self.assertRaises(SystemExit):
                cd_objective_lib._wait_for_action_server(
                    cd_objective_lib.time.monotonic() - 1
                )
        fail.assert_called_once()

    def test_deadline_triggers_failure(self):
        with mock.patch.object(
            cd_objective_lib, "_fail", side_effect=SystemExit
        ) as fail:
            with self.assertRaises(SystemExit):
                cd_objective_lib._wait_for_action_server(
                    cd_objective_lib.time.monotonic() - 1
                )
        self.assertIn("not ready", fail.call_args[0][0])


class TestSendGoal(unittest.TestCase):
    def test_builds_the_documented_goal_argument(self):
        with mock.patch.object(
            cd_objective_lib, "_pro_shell", return_value=_completed()
        ) as shell:
            cd_objective_lib._send_goal("Close Gripper", 30)
        argv = shell.call_args[0][0]
        self.assertEqual(argv[:3], ["ros2", "action", "send_goal"])
        self.assertEqual(argv[3], cd_objective_lib.ACTION_NAME)
        self.assertEqual(argv[4], cd_objective_lib.ACTION_TYPE)
        self.assertEqual(argv[5], "{objective_name: 'Close Gripper'}")

    def test_passes_the_timeout_through(self):
        with mock.patch.object(
            cd_objective_lib, "_pro_shell", return_value=_completed()
        ) as shell:
            cd_objective_lib._send_goal("Anything", 17)
        self.assertEqual(shell.call_args[0][1], 17)

    def test_timeout_fails(self):
        with mock.patch.object(
            cd_objective_lib, "_pro_shell", return_value=None
        ), mock.patch.object(cd_objective_lib, "_fail", side_effect=SystemExit) as fail:
            with self.assertRaises(SystemExit):
                cd_objective_lib._send_goal("Stuck", 5)
        self.assertIn("did not terminate", fail.call_args[0][0])

    def test_nonzero_exit_fails(self):
        with mock.patch.object(
            cd_objective_lib,
            "_pro_shell",
            return_value=_completed(returncode=1, stderr="boom"),
        ), mock.patch.object(cd_objective_lib, "_fail", side_effect=SystemExit) as fail:
            with self.assertRaises(SystemExit):
                cd_objective_lib._send_goal("Broken", 5)
        self.assertIn("boom", fail.call_args[0][0])

    def test_terminal_nonsuccess_status_is_not_a_failure(self):
        # An aborted Objective still exits 0 from the CLI; only transport errors fail.
        with mock.patch.object(
            cd_objective_lib, "_pro_shell", return_value=_completed()
        ), mock.patch.object(
            cd_objective_lib, "_fail", side_effect=AssertionError("must not fail")
        ):
            cd_objective_lib._send_goal("Aborts", 5)


class TestRunObjectivesForever(unittest.TestCase):
    def test_empty_list_fails_before_touching_the_container(self):
        with mock.patch.object(
            cd_objective_lib, "_fail", side_effect=SystemExit
        ) as fail, mock.patch.object(cd_objective_lib, "_pro_shell") as shell:
            with self.assertRaises(SystemExit):
                cd_objective_lib.run_objectives_forever([])
        shell.assert_not_called()
        self.assertIn("empty objectives list", fail.call_args[0][0])

    def test_each_objective_is_sent_in_order_each_iteration(self):
        sent = []

        def fake_send(name, timeout):
            sent.append(name)
            if len(sent) >= 4:
                raise SystemExit  # break the infinite loop

        with mock.patch.object(
            cd_objective_lib, "_wait_for_action_server"
        ), mock.patch.object(
            cd_objective_lib, "_send_goal", side_effect=fake_send
        ), mock.patch.object(cd_objective_lib.time, "sleep"):
            with self.assertRaises(SystemExit):
                cd_objective_lib.run_objectives_forever(["A", "B"])
        self.assertEqual(sent, ["A", "B", "A", "B"])


class TestFailureTitle(unittest.TestCase):
    def test_includes_the_current_objective_once_known(self):
        cd_objective_lib._current_objective = "Pick Box"
        self.assertIn("Pick Box", cd_objective_lib._failure_title())

    def test_omits_the_suffix_before_an_objective_is_known(self):
        cd_objective_lib._current_objective = None
        self.assertNotIn("—", cd_objective_lib._failure_title())


if __name__ == "__main__":
    unittest.main()
