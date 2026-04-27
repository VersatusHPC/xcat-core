#!/usr/bin/env bash
#
# ci/init-harness.sh — Prepare a specific test harness inside the MN
#
set -euo pipefail

STATE_DIR="/var/lib/xcat3-ci"
SSH_KEY="$STATE_DIR/ci-ssh-key"
MN_IP=""
HARNESS=""
ISO_DIR="/opt/xcat-ci/isos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mn-ip)    MN_IP="$2"; shift 2 ;;
        --harness)  HARNESS="$2"; shift 2 ;;
        --iso-dir)  ISO_DIR="$2"; shift 2 ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$MN_IP" ]] && { echo "ERROR: --mn-ip required" >&2; exit 1; }
[[ -z "$HARNESS" ]] && { echo "ERROR: --harness required" >&2; exit 1; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [init-harness] $*" >&2; }

ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

install_bats() {
    log "Installing bats on MN"
    ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
if ! command -v bats &>/dev/null; then
    dnf install -y epel-release 2>&1 | tail -3
    dnf install -y bats 2>&1 | tail -3
fi
bats --version
REMOTE
}

copy_tests_to_mn() {
    log "Copying test files to MN"
    ssh_cmd root@"$MN_IP" 'mkdir -p /opt/xcat-ci-tests'
    tar -C "$SCRIPT_DIR/tests" -cf - . \
        | ssh_cmd root@"$MN_IP" 'tar -C /opt/xcat-ci-tests -xf -'
}

init_unit_smoke() {
    log "Initializing unit-smoke harness"

    install_bats
    copy_tests_to_mn

    ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$PATH"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"

if ! command -v lsdef &>/dev/null; then
    echo "WARN: xCAT commands not in PATH, skipping node setup"
    exit 0
fi

echo "Defining dummy nodes for make* smoke tests..."
mkdef testnode01 groups=compute,all ip=10.250.0.101 mac=52:54:00:ci:00:01 2>/dev/null || true
mkdef testnode02 groups=compute,all ip=10.250.0.102 mac=52:54:00:ci:00:02 2>/dev/null || true

echo "Dummy nodes defined"
lsdef testnode01 testnode02
REMOTE
    log "unit-smoke harness initialized"
}

init_deploy() {
    local os boot method
    os=$(echo "$HARNESS" | cut -d- -f2)
    boot=$(echo "$HARNESS" | cut -d- -f3)
    method=$(echo "$HARNESS" | cut -d- -f4)

    log "Initializing deploy harness: os=$os boot=$boot method=$method"
    log "TODO: copycds, genimage/packimage, mkdef CN, mkvm"
    log "BLOCKED: deployment harness not yet implemented"
    exit 1
}

case "$HARNESS" in
    unit-smoke)
        init_unit_smoke
        ;;
    deploy-*)
        init_deploy
        ;;
    *)
        echo "ERROR: unknown harness type: $HARNESS" >&2
        exit 1
        ;;
esac
