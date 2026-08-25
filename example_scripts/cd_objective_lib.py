"""Shared CD objective runner (native ROS 2).

Sends an Objective goal to the `/do_objective` action through the MoveIt Pro
CLI's container shell:

    moveit_pro shell ros2 action send_goal /do_objective ...

`ros2 action send_goal` runs inside the Runtime container, where ROS 2 and
`moveit_studio_sdk_msgs` already live, and blocks until the goal reaches a
terminal state. Nothing here touches the web bridge, so there is no TLS
handshake, no `MOVEIT_FRONTEND_KEY`, and no port to keep in sync.

On timeout or a failure to reach the action server it stops the MoveIt Pro
service, posts a Slack notification, and opens or updates a deduplicated GitHub
issue (both via notify_lib.py).

Intended to be launched detached from CI over SSH; the calling shell can exit
immediately and the script keeps running on the host.

Prerequisites on the target machine:
  * MoveIt Pro installed, with an active user workspace configured
    (`moveit_pro configure`) so `moveit_pro shell` has something to attach to.
  * The service running, so the shell attaches to the live container rather
    than starting an ephemeral one.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, "/usr/lib/moveit-pro-scripts")

try:
    from notify_lib import build_payload, github_issue, slack_post
except ImportError as exc:  # pragma: no cover - exercised only on a broken install
    # Notifications are auxiliary: a missing notify_lib must not stop the runner
    # from stopping the service. Degrade loudly.
    print(f"notify_lib unavailable, notifications disabled: {exc}", file=sys.stderr)

    def build_payload(process_time, date=None):
        return {"process_time": process_time}

    def slack_post(payload, dry_run=False):
        pass

    def github_issue(title, reason, version=None, dry_run=False):
        pass


MOVEIT_PRO_CLI = os.environ.get("MOVEIT_PRO_CLI", "/usr/bin/moveit_pro")
ACTION_NAME = "/do_objective"
ACTION_TYPE = "moveit_studio_sdk_msgs/action/DoObjectiveSequence"

# Overall budget for the objective server to come up after a deploy.
TOTAL_TIMEOUT_S = 3600
POLL_INTERVAL_S = 10
# Per-attempt ceiling while waiting for the server. Long enough for `ros2 action
# list` to finish DDS discovery on a busy machine, short enough to retry often.
DISCOVERY_TIMEOUT_S = 30

# Objective context for the GitHub issue title, set once the runner knows which
# objective(s) it is driving. None until then (e.g. the container never came up).
_current_objective = None


def _failure_title():
    import socket

    suffix = f" — {_current_objective}" if _current_objective else ""
    return f"QA deployment failure: {socket.gethostname()}{suffix}"


def _notify(reason):
    """Best-effort Slack + GitHub notification. Never raises."""
    try:
        slack_post(build_payload(reason))
    except Exception as exc:  # noqa: BLE001 - notifications are best-effort
        print(f"Slack notify failed: {exc}", file=sys.stderr)
    try:
        github_issue(_failure_title(), reason)
    except Exception as exc:  # noqa: BLE001 - notifications are best-effort
        print(f"GitHub issue failed: {exc}", file=sys.stderr)


def _stop_service():
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    if not user:
        print("Cannot determine user for systemctl stop", file=sys.stderr)
        return
    unit = f"moveit-pro@{user}.service"
    print(f"Stopping {unit}")
    try:
        subprocess.run(
            ["sudo", "-n", "/bin/systemctl", "stop", unit],
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"systemctl stop failed: {exc}", file=sys.stderr)


def _fail(reason):
    print(reason, file=sys.stderr)
    _notify(reason)
    _stop_service()
    sys.exit(1)


def _pro_shell(command, timeout):
    """Run `command` (a token list) inside the Runtime container.

    Returns the CompletedProcess, or None when the call timed out or the CLI is
    missing. `moveit_pro shell <cmd>` allocates no TTY, so this works from a
    detached SSH session.
    """
    try:
        return subprocess.run(
            [MOVEIT_PRO_CLI, "shell", *command],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None
    except OSError as exc:
        _fail(f"Cannot run {MOVEIT_PRO_CLI}: {exc}")


def _wait_for_action_server(deadline):
    """Block until `/do_objective` is advertised, or fail at the deadline.

    The action appears only once the objective server has loaded the robot
    model, the Behavior plugins, and every Objective, so this doubles as a
    readiness check for the whole Runtime.
    """
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        result = _pro_shell(["ros2", "action", "list"], DISCOVERY_TIMEOUT_S)
        if result is not None and result.returncode == 0:
            if ACTION_NAME in result.stdout.split():
                print(f"{ACTION_NAME} action server is up (attempt {attempt})")
                return
        print(f"Waiting for {ACTION_NAME} action server... (attempt {attempt})")
        time.sleep(POLL_INTERVAL_S)
    _fail(f"Timeout: {ACTION_NAME} action server not ready within 1h")


def _send_goal(objective_name, timeout_s):
    """Send one goal and block until it terminates. Returns on any terminal state.

    Any terminal status (success, abort, cancel) counts as completion — the
    result payload is opaque to this script, and real crashes are caught by the
    systemd notify-crash hook. Only an unreachable action server or a timeout
    calls _fail().
    """
    print(f"Sending objective: {objective_name}")
    result = _pro_shell(
        [
            "ros2",
            "action",
            "send_goal",
            ACTION_NAME,
            ACTION_TYPE,
            f"{{objective_name: '{objective_name}'}}",
        ],
        timeout_s,
    )
    if result is None:
        _fail(
            f"Timeout: objective '{objective_name}' did not terminate within {timeout_s}s"
        )
    if result.returncode != 0:
        _fail(
            f"Failed to send objective '{objective_name}' "
            f"(exit {result.returncode}): {result.stderr.strip()}"
        )
    print(f"Objective '{objective_name}' terminated")


def run_objective(objective_name):
    """Send one objective goal and wait for it to terminate."""
    global _current_objective
    _current_objective = objective_name
    deadline = time.monotonic() + TOTAL_TIMEOUT_S
    _wait_for_action_server(deadline)
    _send_goal(objective_name, TOTAL_TIMEOUT_S)


def run_objectives_forever(
    objectives, iteration_pause_s=5, per_objective_timeout_s=3600
):
    """Send each objective in order, wait for it, pause, then repeat — forever.

    Used by customer-config CD machines whose Behavior Tree XML does not
    self-loop. A stuck objective or an unreachable action server calls _fail()
    (Slack + GitHub issue + stop the unit); healthy iterations log and continue.
    """
    global _current_objective
    if not objectives:
        _fail("run_objectives_forever called with empty objectives list")

    # Seed the issue-title context with the whole list; _send_goal narrows it to
    # the specific objective once sending starts. This initial value is only what
    # a pre-send failure (the container never came up) reports.
    _current_objective = ", ".join(objectives)

    deadline = time.monotonic() + TOTAL_TIMEOUT_S
    _wait_for_action_server(deadline)

    iteration = 0
    while True:
        iteration += 1
        print(f"--- Iteration {iteration} ---")
        for objective_name in objectives:
            _current_objective = objective_name
            _send_goal(objective_name, per_objective_timeout_s)
        time.sleep(iteration_pause_s)
