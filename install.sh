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
# python3 runs notify-crash.py from the unit's ExecStopPost and the CD
# objective runner, so name it here rather than relying on some other
# package to drag it in.
echo "Refreshing package lists and installing prerequisites"
apt-get update
apt-get install -y ca-certificates curl python3

echo "Installing shared libraries to /usr/lib/moveit-pro-scripts/"
install -d -m 0755 -o root -g root /usr/lib/moveit-pro-scripts
install -m 644 "$SCRIPT_DIR/example_scripts/cd_objective_lib.py" /usr/lib/moveit-pro-scripts/cd_objective_lib.py
install -m 644 "$SCRIPT_DIR/bin/notify_lib.py" /usr/lib/moveit-pro-scripts/notify_lib.py

echo "Installing objective scripts to /usr/bin/"
install -m 755 "$SCRIPT_DIR/example_scripts/3-waypoint-pick-and-place.py" /usr/bin/3-waypoint-pick-and-place.py
install -m 755 "$SCRIPT_DIR/example_scripts/ml-segment-image.py" /usr/bin/ml-segment-image.py
install -m 755 "$SCRIPT_DIR/example_scripts/move-all-boxes.py" /usr/bin/move-all-boxes.py

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
