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

echo "::: checking installed files"
for f in /usr/bin/3-waypoint-pick-and-place.py /usr/bin/ml-segment-image.py \
    /usr/bin/move-all-boxes.py /usr/bin/notify-crash.py \
    /usr/local/sbin/install-moveit-pro /usr/local/sbin/moveit-pro-run; do
    [[ -x "$f" ]] || fail "$f missing or not executable"
done
for f in /usr/lib/moveit-pro-scripts/cd_objective_lib.py \
    /usr/lib/moveit-pro-scripts/notify_lib.py \
    /etc/systemd/system/moveit-pro@.service; do
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

echo "::: checking the ExecStart wrapper picks the flag per installed version"
# --headless is required on both series. --no-discovery exists only from 10.x, and
# keeps the unit from supervising the deploy script's daemon; passing it to 9.4
# aborts its typer CLI.
stub_cli() {
    # Single-quoted on purpose: $1 and $* must reach the stub literally.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "MoveIt Pro version: %s"; exit 0; fi\necho "ARGS: $*"\n' \
        "$1" > /tmp/moveit_pro_stub
    chmod 755 /tmp/moveit_pro_stub
}
wrapper_args() {
    stub_cli "$1"
    MOVEIT_PRO_CLI=/tmp/moveit_pro_stub /usr/local/sbin/moveit-pro-run
}
for version in 9.4.2 10.0.0-rc11; do
    if ! wrapper_args "$version" | grep -q -- "--headless"; then
        fail "$version did not get --headless"
    fi
done
if wrapper_args "9.4.2" | grep -q -- "--no-discovery"; then
    fail "9.4 was given --no-discovery, which aborts its typer CLI"
fi
if ! wrapper_args "10.0.0-rc11" | grep -q -- "--no-discovery"; then
    fail "10.x did not get --no-discovery, so the unit may supervise its own daemon"
fi
echo "  --headless on both, --no-discovery on 10.x only"

echo "::: checking the objective runner imports under this release's python3"
# Importing exercises the notify_lib path resolution the wrappers rely on.
python3 -c 'import sys; sys.path.insert(0, "/usr/lib/moveit-pro-scripts"); import cd_objective_lib' \
    || fail "cd_objective_lib.py failed to import"

echo "::: checking the notifiers run under this release's python3"
command -v python3 > /dev/null || fail "install.sh did not provide python3"
echo "  $(python3 --version)"
python3 /usr/lib/moveit-pro-scripts/notify_lib.py \
    --title smoke --reason smoke --dry-run > /dev/null \
    || fail "notify_lib CLI shim failed"
/usr/bin/notify-crash.py --dry-run > /dev/null || fail "notify-crash.py --dry-run failed"
python3 -m unittest discover -s test -q || fail "notify_lib unit tests failed"

echo "::: OK on ${PRETTY_NAME}"
