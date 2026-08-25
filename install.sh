#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_SRC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_SRC="${2:?--config requires a file path}"
            shift 2
            ;;
        --config=*)
            CONFIG_SRC="${1#--config=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: sudo ./install.sh [--config <moveit-pro-cd.conf>]" >&2
            exit 2
            ;;
    esac
done

if [[ -n "$CONFIG_SRC" && ! -f "$CONFIG_SRC" ]]; then
    echo "Config file not found: $CONFIG_SRC" >&2
    exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must run as root: sudo ./install.sh [--config <file>]" >&2
    exit 1
fi

# shellcheck disable=SC1091 # /etc/os-release is provided by the OS.
. /etc/os-release
case "${VERSION_ID:-}" in
    22.04 | 24.04 | 26.04) ;;
    *)
        echo "Warning: untested on ${PRETTY_NAME:-this system}." >&2
        echo "Supported: Ubuntu 22.04, 24.04, and 26.04." >&2
        ;;
esac

# Ubuntu server images do not all ship curl, and a freshly imaged machine may
# have no package lists at all, so bootstrap both before anything reaches out.
# python3 runs notify-crash.py from the unit's ExecStopPost and notify_lib.py
# from the CD runner, so name it here rather than relying on some other
# package to drag it in.
echo "Refreshing package lists and installing prerequisites"
apt-get update
apt-get install -y ca-certificates curl gnupg python3

# The CD objective runner is Node (foxglove-ros-adapter over the web bridge on
# 3201). Node 22 is the floor: it is what 26.04 ships in apt, and 18 and 20 are
# both past end-of-life. Bump NODE_MAJOR_MIN when 22 goes EOL in April 2027.
NODE_MAJOR_MIN=22

# Probe /usr/bin directly rather than PATH. A shell running install.sh may have
# an nvm or fnm shim in front, but the /usr/bin/*.mjs shebangs and the `npm`
# call below resolve against the system PATH, which never sees it.
system_node_major() {
    if [[ -x /usr/bin/node ]]; then
        /usr/bin/node -p 'process.versions.node.split(".")[0]' 2> /dev/null || echo 0
    else
        echo 0
    fi
}

# Ubuntu packages npm separately from nodejs, so a new-enough node is not on its
# own proof that npm is there. NodeSource ships both in one package.
if [[ "$(system_node_major)" -lt "$NODE_MAJOR_MIN" || ! -x /usr/bin/npm ]]; then
    echo "Installing Node.js ${NODE_MAJOR_MIN} LTS (via NodeSource)"
    # No `sudo -E`: we are already root, and 26.04's sudo-rs ignores -E anyway.
    # NodeSource's repo is distro-independent (Suites: nodistro), so one URL
    # covers all three releases.
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_MIN}.x" | bash -
    apt-get install -y nodejs
fi
echo "Using Node $(/usr/bin/node --version) with npm $(/usr/bin/npm --version)"

echo "Installing shared libraries to /usr/lib/moveit-pro-scripts/"
install -d -m 0755 -o root -g root /usr/lib/moveit-pro-scripts
install -m 644 "$SCRIPT_DIR/example_scripts/cd_objective_lib.mjs" /usr/lib/moveit-pro-scripts/cd_objective_lib.mjs
install -m 644 "$SCRIPT_DIR/example_scripts/ws-polyfill.mjs" /usr/lib/moveit-pro-scripts/ws-polyfill.mjs
install -m 644 "$SCRIPT_DIR/example_scripts/package.json" /usr/lib/moveit-pro-scripts/package.json
install -m 644 "$SCRIPT_DIR/bin/notify_lib.py" /usr/lib/moveit-pro-scripts/notify_lib.py

echo "Installing Node dependencies for the CD runner"
npm install --omit=dev --prefix /usr/lib/moveit-pro-scripts

echo "Installing objective scripts to /usr/bin/"
install -m 755 "$SCRIPT_DIR/example_scripts/3-waypoint-pick-and-place.mjs" /usr/bin/3-waypoint-pick-and-place.mjs
install -m 755 "$SCRIPT_DIR/example_scripts/ml-segment-image.mjs" /usr/bin/ml-segment-image.mjs
install -m 755 "$SCRIPT_DIR/example_scripts/move-all-boxes.mjs" /usr/bin/move-all-boxes.mjs

echo "Installing notify-crash.py to /usr/bin/"
install -m 755 "$SCRIPT_DIR/bin/notify-crash.py" /usr/bin/notify-crash.py

echo "Installing install-moveit-pro to /usr/local/sbin/"
install -m 755 -o root -g root \
    "$SCRIPT_DIR/bin/install-moveit-pro" /usr/local/sbin/install-moveit-pro
install -d -m 0755 -o root -g root /var/cache/moveit-pro

if [[ -n "$CONFIG_SRC" ]]; then
    echo "Installing CD config to /etc/moveit-pro-cd.conf from $CONFIG_SRC"
    install -m 0644 -o root -g root "$CONFIG_SRC" /etc/moveit-pro-cd.conf
fi

echo "Installing systemd services"
cp "$SCRIPT_DIR/bin/moveit-pro@.service" /etc/systemd/system/moveit-pro@.service

# Install virtual-screen service if not already present.
if [ ! -f /etc/systemd/system/virtual-screen.service ]; then
    echo "Installing xvfb"
    apt-get install -y xvfb
    echo "Installing virtual-screen.service"
    tee /etc/systemd/system/virtual-screen.service > /dev/null << 'EOF'
[Unit]
Description=Virtual Screen Service

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1024x768x24
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable virtual-screen.service
    systemctl start virtual-screen.service
else
    echo "virtual-screen.service already installed, skipping"
fi

systemctl daemon-reload

# Detect the local user (the user who invoked sudo, not root).
LOCAL_USER="${SUDO_USER:-$USER}"
echo "Enabling moveit-pro@${LOCAL_USER}.service"
systemctl enable "moveit-pro@${LOCAL_USER}.service"

echo "Installing CI sudoers drop-in for user ${LOCAL_USER}"
SUDOERS_SRC="$SCRIPT_DIR/bin/ci-runner.sudoers.template"
SUDOERS_DST="/etc/sudoers.d/${LOCAL_USER}-ci"
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT
sed "s/__CI_USER__/${LOCAL_USER}/g" "$SUDOERS_SRC" > "$SUDOERS_TMP"
/usr/sbin/visudo -cf "$SUDOERS_TMP"
install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_DST"

echo "Done. Start with: sudo systemctl start moveit-pro@${LOCAL_USER}.service"
echo "Verify CI can invoke installer without a password:"
echo "  sudo -n /usr/local/sbin/install-moveit-pro <version>"
