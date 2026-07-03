// Shared CD objective runner (Foxglove web bridge).
//
// Connects to the always-on MoveIt Pro web bridge (foxglove_bridge, port 3201),
// waits up to 1 hour for the /do_objective action server, sends the objective
// goal, then exits. On timeout: stops the moveit-pro service, posts a Slack
// failure notification, and opens or updates a deduplicated GitHub issue (both
// via notify_lib.py). Unlike the previous roslibpy version this needs no
// --enable-rosbridge sidecar — it speaks the Foxglove protocol to port 3201.
//
// Intended to be launched detached from CI over SSH; the calling shell can exit
// immediately and the script keeps running on the host.

import "./ws-polyfill.mjs"; // must precede the adapter import (installs global WebSocket on Node < 22)
import { Ros, ActionClient } from "foxglove-ros-adapter";

import { execFileSync } from "node:child_process";
import os from "node:os";

const BRIDGE_URL = process.env.MOVEIT_WEB_BRIDGE_URL ?? "ws://localhost:3201";
const ACTION_NAME = "/do_objective";
const ACTION_TYPE = "moveit_studio_sdk_msgs/action/DoObjectiveSequence";

const TOTAL_TIMEOUT_MS = 3600_000;
const POLL_INTERVAL_MS = 10_000;
const CONNECT_TIMEOUT_MS = 10_000;
const ACTION_WAIT_MS = 10_000;
const SEND_GOAL_DRAIN_MS = 5_000;

// notify_lib.py is installed alongside this module; override for local testing.
const NOTIFY_LIB =
  process.env.MOVEIT_NOTIFY_LIB ?? "/usr/lib/moveit-pro-scripts/notify_lib.py";

// Objective context for the GitHub issue title, set once the runner knows which
// objective(s) it is driving. null until then (e.g. the bridge never came up).
let currentObjective = null;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function failureTitle() {
  const suffix = currentObjective ? ` — ${currentObjective}` : "";
  return `QA deployment failure: ${os.hostname()}${suffix}`;
}

// Notifications are auxiliary: a missing/broken notify_lib must not stop the
// runner from stopping the service. Degrade loudly.
function notify(title, reason) {
  try {
    execFileSync("python3", [NOTIFY_LIB, "--title", title, "--reason", reason], {
      stdio: "inherit",
    });
  } catch (err) {
    console.error(`notify_lib failed, notifications skipped: ${err.message}`);
  }
}

function stopService() {
  const user = process.env.USER || process.env.LOGNAME || "";
  if (!user) {
    console.error("Cannot determine user for systemctl stop");
    return;
  }
  const unit = `moveit-pro@${user}.service`;
  console.log(`Stopping ${unit}`);
  try {
    execFileSync("sudo", ["-n", "/bin/systemctl", "stop", unit], {
      stdio: "inherit",
    });
  } catch (err) {
    console.error(`systemctl stop failed: ${err.message}`);
  }
}

function fail(reason) {
  console.error(reason);
  notify(failureTitle(), reason);
  stopService();
  process.exit(1);
}

// Wait for the web bridge to accept a WebSocket connection. The adapter does not
// auto-reconnect, so retry a fresh Ros per attempt until the deadline.
async function connectWithRetry(deadline) {
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt += 1;
    const ros = new Ros({ url: BRIDGE_URL });
    const connected = await new Promise((resolve) => {
      let settled = false;
      const finish = (ok) => {
        if (!settled) {
          settled = true;
          resolve(ok);
        }
      };
      const timer = setTimeout(() => finish(false), CONNECT_TIMEOUT_MS);
      ros.on("connection", () => {
        clearTimeout(timer);
        finish(true);
      });
      ros.on("error", () => {
        clearTimeout(timer);
        finish(false);
      });
      ros.on("close", () => {
        clearTimeout(timer);
        finish(false);
      });
    });
    if (connected) {
      console.log(`Web bridge connected at ${BRIDGE_URL} (attempt ${attempt})`);
      return ros;
    }
    try {
      ros.close();
    } catch {
      // ignore
    }
    console.log(`Waiting for web bridge at ${BRIDGE_URL}... (attempt ${attempt})`);
    await sleep(POLL_INTERVAL_MS);
  }
  fail("Timeout: web bridge did not connect within 1h");
}

// Poll until the /do_objective action server is advertised. waitForAction checks
// the hidden action services the bridge exposes; it rejects if not ready within
// its own timeout, so wrap it in the overall deadline loop.
async function waitForActionServer(ros, deadline) {
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt += 1;
    try {
      await ros.waitForAction(ACTION_NAME, ACTION_WAIT_MS);
      console.log(`${ACTION_NAME} action server is up (attempt ${attempt})`);
      return;
    } catch {
      console.log(`Waiting for ${ACTION_NAME} action server... (attempt ${attempt})`);
      await sleep(POLL_INTERVAL_MS);
    }
  }
  fail(`Timeout: ${ACTION_NAME} action server not ready within 1h`);
}

// Send one objective goal and return immediately after a short drain, without
// waiting for the action to terminate. Used for fire-and-forget smoke tests
// whose Behavior Tree self-loops or runs indefinitely.
export async function runObjective(objectiveName) {
  currentObjective = objectiveName;
  const deadline = Date.now() + TOTAL_TIMEOUT_MS;
  const ros = await connectWithRetry(deadline);
  try {
    await waitForActionServer(ros, deadline);
    const client = new ActionClient({
      ros,
      name: ACTION_NAME,
      actionType: ACTION_TYPE,
    });
    console.log(`Sending objective: ${objectiveName}`);
    client.sendGoal(
      { objective_name: objectiveName },
      () => {},
      () => {},
      (err) => console.error(`Action error for '${objectiveName}': ${err}`),
    );
    await sleep(SEND_GOAL_DRAIN_MS);
    console.log(`Objective '${objectiveName}' sent successfully`);
  } finally {
    try {
      ros.close();
    } catch {
      // ignore
    }
  }
}

// Send one objective goal and block until the action terminates. Any terminal
// status (success, abort, cancel) counts as completion — the result payload is
// opaque to this script, and real crashes are caught by the systemd
// notify-crash hook. Only rosbridge errors or a per-objective timeout fail().
async function sendAndWait(client, objectiveName, perObjectiveTimeoutMs) {
  currentObjective = objectiveName;
  console.log(`Sending objective: ${objectiveName}`);
  const goalId = client.sendGoal(
    { objective_name: objectiveName },
    () => {},
    () => {},
    (err) => console.error(`Action error for '${objectiveName}': ${err}`),
  );
  try {
    await client.waitGoal(goalId, perObjectiveTimeoutMs);
  } catch {
    fail(
      `Timeout: objective '${objectiveName}' did not terminate within ` +
        `${Math.round(perObjectiveTimeoutMs / 1000)}s`,
    );
  }
  console.log(`Objective '${objectiveName}' terminated`);
}

// Send each objective in order, wait for it to terminate, pause, then repeat —
// forever. Used by customer-config CD machines whose BT XML does not self-loop.
// Stuck objectives or bridge errors call fail() (Slack + GitHub issue + stop the
// unit); healthy iterations log and continue.
export async function runObjectivesForever(
  objectives,
  { iterationPauseMs = 5_000, perObjectiveTimeoutMs = 3600_000 } = {},
) {
  if (!objectives || objectives.length === 0) {
    fail("runObjectivesForever called with empty objectives list");
  }

  // Seed the issue-title context with the whole list; sendAndWait narrows it to
  // the specific objective once sending starts. This initial value is only what
  // a pre-send failure (bridge / action server never came up) reports.
  currentObjective = objectives.join(", ");

  const deadline = Date.now() + TOTAL_TIMEOUT_MS;
  const ros = await connectWithRetry(deadline);
  try {
    await waitForActionServer(ros, deadline);
    const client = new ActionClient({
      ros,
      name: ACTION_NAME,
      actionType: ACTION_TYPE,
    });
    let iteration = 0;
    for (;;) {
      iteration += 1;
      console.log(`--- Iteration ${iteration} ---`);
      for (const objectiveName of objectives) {
        await sendAndWait(client, objectiveName, perObjectiveTimeoutMs);
      }
      await sleep(iterationPauseMs);
    }
  } finally {
    try {
      ros.close();
    } catch {
      // ignore
    }
  }
}
