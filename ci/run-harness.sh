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

TOTAL_PASS=0
TOTAL_FAIL=0

echo "========================================="
echo "  xCAT CI Test Harness: unit-smoke"
echo "========================================="

# ── R0: Verify xcatd is accepting connections ───────
echo ""
echo "--- R0: Verify xcatd connectivity ---"
if command -v lsdef &>/dev/null; then
    echo "Waiting for xcatd to accept connections (up to 60s)..."
    for i in $(seq 1 30); do
        lsdef -t site clustersite &>/dev/null && break
        sleep 2
    done
    if lsdef -t site clustersite &>/dev/null; then
        echo "  PASS: xcatd accepting connections"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  FAIL: xcatd not accepting connections after 60s"
        systemctl status xcatd --no-pager 2>/dev/null || true
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
fi

# ── R1: Unit tests ──────────────────────────────────
echo ""
echo "--- R1: Unit tests (xcattest -s ci_test) ---"
if command -v xcattest &>/dev/null && rpm -q xCAT-test &>/dev/null; then
    if xcattest -s ci_test -q 2>&1 | tail -20; then
        echo "  PASS: xcattest -s ci_test"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  FAIL: xcattest -s ci_test"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
else
    echo "  SKIP: xCAT-test not installed"
fi

# ── R2: make* smoke tests (BATS) ───────────────────
echo ""
echo "--- R2: make* smoke tests (bats) ---"
if command -v lsdef &>/dev/null && command -v bats &>/dev/null; then
    bats --tap /opt/xcat-ci-tests/smoke-make-commands.bats
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  PASS: bats smoke tests"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  FAIL: bats smoke tests (exit $rc)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
else
    if ! command -v lsdef &>/dev/null; then
        echo "  SKIP: xCAT-server not installed — running perl-xCAT fallback"
        if PERL5LIB=/opt/xcat/lib/perl perl -e 'use xCAT::Table; print "  PASS: perl-xCAT loads OK\n"'; then
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo "  FAIL: perl-xCAT modules broken"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    else
        echo "  SKIP: bats not installed"
    fi
fi

echo ""
echo "========================================="
echo "  Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "========================================="

[[ $TOTAL_FAIL -eq 0 ]] || exit 1
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
