#!/usr/bin/env bats
#
# Smoke tests for xCAT make* commands (R2)
#
# Prerequisites:
#   - xCAT-server installed and xcatd running
#   - Dummy nodes defined (testnode01, testnode02)
#

setup() {
    export XCATROOT=/opt/xcat
    export PATH="$XCATROOT/bin:$XCATROOT/sbin:$XCATROOT/share/xcat/tools:$PATH"
    export PERL5LIB="$XCATROOT/lib/perl:${PERL5LIB:-}"
}

# ── P2.1: makehosts ─────────────────────────────────────────────────────────

@test "P2.1: makehosts exits 0" {
    run makehosts
    [ "$status" -eq 0 ]
}

@test "P2.1: /etc/hosts contains testnode01" {
    makehosts
    grep -q "testnode01" /etc/hosts
}

@test "P2.1: /etc/hosts contains testnode02" {
    makehosts
    grep -q "testnode02" /etc/hosts
}

# ── P2.2: makedns ───────────────────────────────────────────────────────────

@test "P2.2: makedns -n exits 0" {
    run makedns -n
    [ "$status" -eq 0 ]
}

# ── P2.3: makedhcp ──────────────────────────────────────────────────────────

@test "P2.3: makedhcp -n exits 0" {
    run makedhcp -n
    [ "$status" -eq 0 ]
}

@test "P2.3: makedhcp -a exits 0" {
    run makedhcp -a
    [ "$status" -eq 0 ]
}

# ── P2.4: makeknownhosts ────────────────────────────────────────────────────

@test "P2.4: makeknownhosts exits 0" {
    run makeknownhosts
    [ "$status" -eq 0 ]
}

# ── P2.5: makeconservercf ───────────────────────────────────────────────────

@test "P2.5: makeconservercf exits 0" {
    run makeconservercf
    [ "$status" -eq 0 ]
}

# ── P2.6: makentp ───────────────────────────────────────────────────────────

@test "P2.6: makentp exits 0" {
    run makentp
    [ "$status" -eq 0 ]
}
