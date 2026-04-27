#!/usr/bin/env bash
#
# ci/teardown-test-env.sh — Destroy test environment (MN VM + network)
#
set -euo pipefail

STATE_DIR="/var/lib/xcat3-ci"
STATE_FILE="$STATE_DIR/managed-vms.txt"
RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        *)        echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$RUN_ID" ]] && { echo "ERROR: --run-id required" >&2; exit 1; }

MN_NAME="xcat-ci-mn-${RUN_ID}"
NET_NAME="xcat-ci-${RUN_ID}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [teardown] $*" >&2; }

is_managed() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

state_remove() {
    local tmp
    tmp=$(mktemp)
    grep -vxF "$1" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$STATE_FILE"
}

destroy_vm() {
    local name="$1"
    if ! is_managed "$name"; then
        log "REFUSING to destroy $name — not in managed list"
        return 0
    fi
    log "Destroying VM $name"
    virsh destroy "$name" 2>/dev/null || true
    virsh undefine "$name" --remove-all-storage 2>/dev/null || true
    rm -rf "$STATE_DIR/${name}-ci" "$STATE_DIR/${name}-cidata.iso"
    state_remove "$name"
}

destroy_network() {
    local name="$1"
    if ! is_managed "net:$name"; then
        log "REFUSING to destroy network $name — not in managed list"
        return 0
    fi
    log "Destroying network $name"
    virsh net-destroy "$name" 2>/dev/null || true
    virsh net-undefine "$name" 2>/dev/null || true
    state_remove "net:$name"
}

main() {
    log "Tearing down test environment for run $RUN_ID"

    # Destroy any CN VMs matching this run
    if [[ -f "$STATE_FILE" ]]; then
        grep "xcat-ci-cn-${RUN_ID}" "$STATE_FILE" 2>/dev/null | while read -r name; do
            destroy_vm "$name"
        done
    fi

    # Destroy MN VM
    destroy_vm "$MN_NAME"

    # Destroy network
    destroy_network "$NET_NAME"

    log "Teardown complete"
}

main "$@"
