#!/usr/bin/env bash
# Runs install.sh end-to-end inside a bare Ubuntu container and checks that
# everything it lays down actually works on that release.
#
# Expects the repo bind-mounted read-only at /src, and a container (not a real
# machine) — it creates a user, overwrites systemctl with a stub, and installs
# system-wide.
#
# Usage, from the repo root:
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/container_smoke.sh
#
# The CI workflow runs this across every supported release; see
# .github/workflows/pre-commit.yaml.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CI_USER=ciuser

echo "::: bootstrapping container"
apt-get update -qq > /dev/null
apt-get install -y -qq sudo > /dev/null
useradd -m "$CI_USER"

# systemd does not run in a container, so the unit-management calls cannot
# succeed. Stub systemctl to a no-op that echoes; everything else runs for real.
printf '#!/bin/sh\necho "  [stub] systemctl $*"\n' > /usr/bin/systemctl
chmod 755 /usr/bin/systemctl

# shellcheck disable=SC1091 # /etc/os-release is provided by the OS.
. /etc/os-release
echo "::: ${PRETTY_NAME} / $(sudo --version 2> /dev/null | head -1)"

cp -r /src /work
cd /work

echo "::: running install.sh"
SUDO_USER="$CI_USER" ./install.sh

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

echo "::: checking Node toolchain"
[[ -x /usr/bin/node ]] || fail "no /usr/bin/node"
[[ -x /usr/bin/npm ]] || fail "no /usr/bin/npm — apt packages npm separately from nodejs"
node_major="$(/usr/bin/node -p 'process.versions.node.split(".")[0]')"
[[ "$node_major" -ge 22 ]] || fail "node major $node_major is below the supported floor"
echo "  node $(/usr/bin/node --version), npm $(/usr/bin/npm --version)"

echo "::: checking installed files"
for f in /usr/bin/3-waypoint-pick-and-place.mjs /usr/bin/ml-segment-image.mjs \
    /usr/bin/move-all-boxes.mjs /usr/bin/notify-crash.py \
    /usr/local/sbin/install-moveit-pro; do
    [[ -x "$f" ]] || fail "$f missing or not executable"
done
for f in /usr/lib/moveit-pro-scripts/cd_objective_lib.mjs \
    /usr/lib/moveit-pro-scripts/ws-polyfill.mjs \
    /usr/lib/moveit-pro-scripts/notify_lib.py \
    /usr/lib/moveit-pro-scripts/node_modules/foxglove-ros-adapter/package.json \
    /etc/systemd/system/moveit-pro@.service \
    /etc/systemd/system/virtual-screen.service; do
    [[ -f "$f" ]] || fail "$f missing"
done

echo "::: checking the sudoers drop-in parses on this release's sudo"
/usr/sbin/visudo -cf "/etc/sudoers.d/${CI_USER}-ci" > /dev/null \
    || fail "sudoers drop-in rejected by visudo"

echo "::: checking CI can invoke the granted commands without a password"
# install-moveit-pro rejects the bogus version, but reaching that check proves
# sudo matched the rule rather than demanding a password.
out="$(su "$CI_USER" -c "sudo -n /usr/local/sbin/install-moveit-pro not-a-version" 2>&1 || true)"
grep -q "Invalid version format" <<< "$out" \
    || fail "sudo -n install-moveit-pro did not match the sudoers rule: $out"
for verb in restart stop; do
    su "$CI_USER" -c "sudo -n systemctl $verb moveit-pro@${CI_USER}.service" > /dev/null 2>&1 \
        || fail "sudo -n systemctl $verb was not permitted"
done

echo "::: checking the Node runner loads under this release's node"
node --input-type=module \
    -e 'import "/usr/lib/moveit-pro-scripts/cd_objective_lib.mjs";' \
    || fail "cd_objective_lib.mjs failed to load"

echo "::: checking the notifiers run under this release's python3"
command -v python3 > /dev/null || fail "install.sh did not provide python3"
echo "  $(python3 --version)"
python3 /usr/lib/moveit-pro-scripts/notify_lib.py \
    --title smoke --reason smoke --dry-run > /dev/null \
    || fail "notify_lib CLI shim failed"
/usr/bin/notify-crash.py --dry-run > /dev/null || fail "notify-crash.py --dry-run failed"
python3 -m unittest discover -s test -q || fail "notify_lib unit tests failed"

echo "::: OK on ${PRETTY_NAME}"
