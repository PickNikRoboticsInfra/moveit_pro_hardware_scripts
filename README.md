# MoveIt Pro Hardware Scripts

Reference installer, systemd unit, and sudoers template for running [MoveIt Pro](https://docs.picknik.ai/) as a service on hardware targeted by a Continuous Deployment pipeline.

The full setup walkthrough lives at [Set Up CI/CD](https://docs.picknik.ai/how_to/computer_configuration/ci_cd_for_objectives/) in the MoveIt Pro docs. This README covers what is in the repo and how to use it directly.

## Supported systems

Ubuntu 22.04, 24.04, and 26.04, on each release's stock `sudo` (26.04 defaults to
`sudo-rs`) and stock `python3` (3.10, 3.12, and 3.14 — everything here is
standard library, so nothing is pip-installed and PEP 668 never comes up).

Nothing here needs a language runtime beyond the system `python3`. The objective
runner drives the `/do_objective` action through `moveit_pro shell`, so ROS 2 and
`moveit_studio_sdk_msgs` stay inside the Runtime container and the host installs
no ROS 2 packages of its own.

`test/container_smoke.sh` runs the installer end-to-end in a bare container and
checks the result. CI runs it on all three releases; to run it yourself:

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:26.04 bash /src/test/container_smoke.sh
```

## Contents

- `install.sh` — one-shot installer. Installs apt prerequisites, then copies the wrapper, systemd unit, and sudoers drop-in into place. Must be run as root; run it on each target machine.
- `bin/moveit-pro-run` — the unit's `ExecStart`. Passes `--headless` on every series: below 10.x the launcher refuses to start without a `DISPLAY` unless it is set, and it drops only the `web_ui` service, so the REST API, the web bridge on `3201`, and video stay reachable and no browser opens. It also reads `moveit_pro --version` to add `--no-discovery` from 10.x, where that flag stops the unit from supervising a discovery daemon the MoveIt Pro deploy script owns; 9.4.x has no such option and its CLI rejects unknown ones, so an unreadable version omits it.
- `bin/install-moveit-pro` — root-owned installer wrapper. Validates the version string against a strict regex, downloads the `.deb` to a root-owned cache, installs it, and deletes the file.
- `bin/moveit-pro@.service` — systemd template unit. Runs `moveit-pro-run` as `%i`. Does not restart on failure (`Restart=no`) — the `ExecStopPost` hook reports the crash instead. Reads optional environment from `/etc/default/moveit-pro`.
- `bin/notify-crash.py` — posts to Slack and opens/updates a GitHub issue via `ExecStopPost` when the service exits non-zero. Reads `SLACK_WEBHOOK_URL` and `MOVEIT_CD_GITHUB_TOKEN` from the environment; each notification is skipped if its variable is unset.
- `bin/notify_lib.py` — shared notification helpers (`slack_post`, `github_issue`) used by `notify-crash.py` (Python import) and by the CD objective runner (`cd_objective_lib.py`, via a Python import). Installed to `/usr/lib/moveit-pro-scripts/`. `github_issue` deduplicates by exact title within a label: a repeated failure bumps an occurrence counter and appends a row instead of opening a new issue.
- `bin/ci-runner.sudoers.template` — sudoers drop-in. `install.sh` substitutes `__CI_USER__` with the local account and installs at `/etc/sudoers.d/<user>-ci`. Grants NOPASSWD on the installer and the user's own systemd unit only.
- `example_scripts/cd_objective_lib.py` — helper library for sending an Objective goal to the `/do_objective` action. It shells out to `moveit_pro shell ros2 action send_goal`, which runs inside the Runtime container where ROS 2 already lives, and blocks until the goal reaches a terminal state. Nothing touches the web bridge, so there is no TLS handshake, no `MOVEIT_FRONTEND_KEY`, and no port to keep in sync. On timeout or an unreachable action server it posts to Slack, opens/updates a GitHub issue, and stops the systemd unit (via `notify_lib.py`).
- `test/container_smoke.sh` — runs `install.sh` in a bare Ubuntu container and verifies the result. See [Supported systems](#supported-systems).
- `example_scripts/3-waypoint-pick-and-place.py`, `example_scripts/ml-segment-image.py`, `example_scripts/move-all-boxes.py` — example smoke-test scripts, each a two-line wrapper around `cd_objective_lib.run_objective(<name>)`.

## Install

On the target machine:

```bash
git clone https://github.com/PickNikRoboticsInfra/moveit_pro_hardware_scripts.git
cd moveit_pro_hardware_scripts
sudo ./install.sh
```

This installs:

- Prerequisites via apt (`ca-certificates`, `curl`, `python3`).
- The objective scripts to `/usr/bin/`.
- `cd_objective_lib.py` and `notify_lib.py` to `/usr/lib/moveit-pro-scripts/`.
- `notify-crash.py` to `/usr/bin/`.
- `install-moveit-pro` and `moveit-pro-run` to `/usr/local/sbin/` (root-owned, `0755`).
- `/var/cache/moveit-pro/` as a root-owned download cache.
- `moveit-pro@.service` to `/etc/systemd/system/`.
- `/etc/sudoers.d/<user>-ci` (validated with `visudo -cf`) granting NOPASSWD on the installer and `systemctl restart`/`stop` of the user's own service unit.

The install script enables — but does not start — the MoveIt Pro service for the current user.

### Optional: per-machine workspace override

`install-moveit-pro` reads `/etc/moveit-pro-cd.conf` (if present, root-owned) to pick the workspace repo cloned on each CD run. Without a config file, it clones [moveit_pro_example_ws](https://github.com/PickNikRobotics/moveit_pro_example_ws) pinned to the release version. Pass `--config` to `install.sh` to lay down a per-machine override:

```bash
sudo ./install.sh --config moveit-pro-cd.<machine>.conf
```

Schema:

```bash
# Public example_ws pinned to release (default — equivalent to no file):
WORKSPACE_REPO=https://github.com/PickNikRobotics/moveit_pro_example_ws.git
WORKSPACE_DIR=moveit_pro_example_ws
WORKSPACE_PIN_TO_RELEASE=true

# Private workspace on a fixed branch:
WORKSPACE_REPO=git@github.com:<owner>/<repo>.git
WORKSPACE_DIR=<repo>
WORKSPACE_BRANCH=main
WORKSPACE_PIN_TO_RELEASE=false
```

`WORKSPACE_REPO` is regex-restricted to `https://github.com/<owner>/<repo>.git` or `git@github.com:<owner>/<repo>.git`. For the SSH form, the CI user needs a deploy key with read-only access.

### Optional: failure notifications (Slack + GitHub issues)

Both notifiers read their config from `/etc/default/moveit-pro` (root-owned). The systemd unit loads this file via `EnvironmentFile=`, so `notify-crash.py` and the CD objective runner pick it up for crash and CD-failure events. Each notifier is independent: set only the variables you want.

```bash
sudo install -m 0640 -o root -g root /dev/stdin /etc/default/moveit-pro <<'EOF'
# Slack incoming webhook. Unset -> Slack skipped.
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/XXX/YYY/ZZZ

# GitHub issue on failure. Unset -> issue creation skipped.
MOVEIT_CD_GITHUB_TOKEN=github_pat_xxx
# Optional overrides (defaults shown):
# MOVEIT_CD_ISSUE_REPO=PickNikRobotics/moveit_pro
# MOVEIT_CD_ISSUE_LABEL=qa-deployment-failure
EOF
```

If a variable is unset, that notification is silently skipped — this is how non-QA machines opt out of issue creation.

`MOVEIT_CD_GITHUB_TOKEN` must be a **fine-grained PAT scoped to the issue repo with `Issues: Read and write` and nothing else** — the narrowest credential that can file an issue. Do not grant `Contents` or any other scope: a QA machine is a higher-exposure host, and the token only needs to open and comment on issues. The `qa-deployment-failure` label must already exist on the repo (the API does not create labels on demand).

Repeated failures of the same kind on the same machine deduplicate to a single issue (matched by title within the label) — each recurrence bumps an occurrence counter, appends a table row with the version/time/reason, and adds a comment for visibility.

## Desktop App pairing

A QA machine is only reachable from the MoveIt Pro Desktop App if the host runs an
instance discovery daemon and the Runtime registers with it. Those are two jobs with
two owners, and this repo owns only the second.

**Starting the daemon is not done here.** It is a systemd user service, and the MoveIt
Pro deploy script sets it up (`moveit_pro discovery up`, which also enables the user
lingering that keeps the daemon alive past logout). Nothing in this repo starts it
or enables that lingering.

**Registering with it is done here, by staying out of the way.** From 10.x the unit
passes `--no-discovery`, so `moveit_pro run` never starts or supervises a daemon of its
own; it registers with whichever one is already serving. That behavior needs
[moveit_pro#21965](https://github.com/PickNikRobotics/moveit_pro/pull/21965), merged to
`v10.0`, which made the flag mean "do not supervise" rather than "do not pair". On a
10.x release built before that merge the flag still suppresses pairing, so the machine
will not be discoverable.

To check the daemon side of the arrangement on a target:

```bash
moveit_pro discovery status   # as the CI user
```

## Verify the install

```bash
# Sudo without password
sudo -n /usr/local/sbin/install-moveit-pro 9.4.0

# Start the service
sudo systemctl start moveit-pro@$USER.service

# Status / logs
systemctl status moveit-pro@$USER.service
journalctl -u moveit-pro@$USER.service -e
```

A password prompt on the first command means the sudoers drop-in did not land. Re-run `install.sh` and check `sudo visudo -c`.

## CD pipeline

The CI runner SSHes into each target machine over a mesh VPN (Tailscale, WireGuard, or any other) and runs these commands in order:

1. `sudo -n /usr/local/sbin/install-moveit-pro <version>` — downloads and installs the `.deb`.
2. `moveit_pro discovery up` — **MoveIt Pro 10 and later only.** Starts the host's instance discovery daemon so a Desktop App can find this machine. 9.4.x has no `discovery` subcommand; skip it there.
3. `sudo -n /bin/systemctl restart moveit-pro@<user>.service` — restarts the service.
4. `/usr/bin/<objective>.py` — optional smoke test of an Objective through `moveit_pro shell`.

Three things about step 2 are easy to get wrong:

- **Run it as the CI user, not through `sudo`.** The daemon is a systemd *user* service and its owner-local socket path derives from that account's uid, so a root-owned daemon is one the Runtime cannot register with.
- **Run it on every deploy, not once at provisioning.** It is idempotent, and re-running it refreshes the unit files after a release upgrade replaces the daemon's code.
- **It belongs in the CD job rather than `install.sh`.** An SSH session gives the CI user a systemd user manager, which `moveit_pro discovery up` needs in order to install its units and to enable the lingering that keeps the daemon alive after logout. `install.sh` runs as root at provisioning time, often before any release is on the machine at all.

The Runtime does not fight this: from 10.x the unit passes `--no-discovery`, so it registers with the daemon step 2 started instead of supervising one of its own. See [Desktop App pairing](#desktop-app-pairing).

The sudoers drop-in grants NOPASSWD on **only** steps 1 and 3. The installer validates the version string with a strict regex and downloads to a root-owned path, so a compromised CI account cannot escalate by planting a malicious `.deb`.

See [Set Up CI/CD](https://docs.picknik.ai/how_to/computer_configuration/ci_cd_for_objectives/) for the full pipeline, a sample GitHub Actions workflow, and the security model.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
