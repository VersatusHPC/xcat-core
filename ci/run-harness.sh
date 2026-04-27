#!/usr/bin/env bash
#
# ci/run-harness.sh — Execute validation harness on the MN
#
# Exit 0 = all checks pass, nonzero = failure
#
set -euo pipefail

STATE_DIR="/var/lib/xcat3-ci"
SSH_KEY="$STATE_DIR/ci-ssh-key"
MN_IP=""
HARNESS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mn-ip)    MN_IP="$2"; shift 2 ;;
        --harness)  HARNESS="$2"; shift 2 ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$MN_IP" ]] && { echo "ERROR: --mn-ip required" >&2; exit 1; }
[[ -z "$HARNESS" ]] && { echo "ERROR: --harness required" >&2; exit 1; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [run-harness] $*" >&2; }

ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

run_unit_smoke() {
    log "Running unit-smoke harness"
    ssh_cmd root@"$MN_IP" bash << 'REMOTE'
set -euo pipefail
export XCATROOT=/opt/xcat
export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
export MANPATH="${XCATROOT}/share/man:${MANPATH:-}"
export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"

PASS=0
FAIL=0
report() {
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "========================================="
echo "  xCAT CI Test Harness: unit-smoke"
echo "========================================="

# ── R1: Unit tests ──────────────────────────────────
echo ""
echo "--- R1: Unit tests (xcattest -s ci_test) ---"
if command -v xcattest &>/dev/null && rpm -q xCAT-test &>/dev/null; then
    xcattest -s ci_test -q 2>&1 | tail -20
    report "xcattest -s ci_test" "${PIPESTATUS[0]}"
else
    echo "  SKIP: xCAT-test not installed"
fi

# ── R2: make* smoke tests ──────────────────────────
echo ""
echo "--- R2: make* smoke tests ---"

if ! command -v lsdef &>/dev/null; then
    echo "  SKIP: xCAT commands not available (xCAT-server not installed)"
    echo ""
    echo "--- Fallback: perl-xCAT module validation ---"
    PERL5LIB=/opt/xcat/lib/perl perl -e 'use xCAT::Table; print "  PASS: perl-xCAT loads OK\n"' \
        && PASS=$((PASS + 1)) \
        || { echo "  FAIL: perl-xCAT modules broken"; FAIL=$((FAIL + 1)); }
else
    # P2.1: makehosts
    makehosts 2>&1 | tail -5
    rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]] && grep -q "testnode01" /etc/hosts 2>/dev/null; then
        report "makehosts (P2.1)" 0
    else
        report "makehosts (P2.1)" 1
    fi

    # P2.2: makedns
    makedns -n 2>&1 | tail -5
    report "makedns -n (P2.2)" "${PIPESTATUS[0]}"

    # P2.3: makedhcp
    makedhcp -n 2>&1 | tail -5
    rc1=${PIPESTATUS[0]}
    makedhcp -a 2>&1 | tail -5
    rc2=${PIPESTATUS[0]}
    [[ $rc1 -eq 0 && $rc2 -eq 0 ]] && report "makedhcp -n && -a (P2.3)" 0 || report "makedhcp -n && -a (P2.3)" 1

    # P2.4: makeknownhosts
    makeknownhosts 2>&1 | tail -5
    report "makeknownhosts (P2.4)" "${PIPESTATUS[0]}"

    # P2.5: makeconservercf
    makeconservercf 2>&1 | tail -5
    report "makeconservercf (P2.5)" "${PIPESTATUS[0]}"

    # P2.6: makentp
    makentp 2>&1 | tail -5
    report "makentp (P2.6)" "${PIPESTATUS[0]}"
fi

echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

[[ $FAIL -eq 0 ]] || exit 1
REMOTE
}

run_deploy() {
    log "BLOCKED: deployment harness not yet implemented"
    exit 1
}

case "$HARNESS" in
    unit-smoke)
        run_unit_smoke
        ;;
    deploy-*)
        run_deploy
        ;;
    *)
        echo "ERROR: unknown harness type: $HARNESS" >&2
        exit 1
        ;;
esac
