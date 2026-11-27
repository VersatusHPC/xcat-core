#!/usr/bin/env bats
# A node that forwards its log to the master must not start rsyslog before
# it has a route to the master: rsyslog drops each forwarded line it cannot
# send. The syslog postscript orders rsyslog.service after
# network-online.target. systemctl is a shell function and the unit
# directory is a scratch directory, so nothing on the host changes.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    SYSLOG="$(require_repo_file 'xCAT/postscripts/syslog')"
    LIB="${BATS_TEST_TMPDIR}/syslog.sh"
    extract_shell_function "$SYSLOG" order_rsyslog_after_network >"$LIB"
    export XCAT_SYSTEMD_UNIT_DIR="${BATS_TEST_TMPDIR}/systemd"
    DROPIN="$XCAT_SYSTEMD_UNIT_DIR/rsyslog.service.d/xcat-network-online.conf"
    EVENTS="${BATS_TEST_TMPDIR}/events.log"
    : >"$EVENTS"
}

run_order()
{
    systemctl() { echo "systemctl $*" >>"$EVENTS"; return 0; }
    # shellcheck disable=SC1090
    . "$LIB"
    order_rsyslog_after_network
}

@test "rsyslog waits for network-online.target on a forwarding node" {
    run run_order
    [ "$status" -eq 0 ]
    [ "$(cat "$DROPIN")" = "$(printf '%s\n' '[Unit]' 'Wants=network-online.target' 'After=network-online.target')" ]
    grep -qx 'systemctl daemon-reload' "$EVENTS"
}

@test "a second run leaves one drop-in with the same content" {
    run run_order
    run run_order
    [ "$status" -eq 0 ]
    [ "$(ls "$XCAT_SYSTEMD_UNIT_DIR/rsyslog.service.d")" = 'xcat-network-online.conf' ]
    [ "$(grep -c '^After=network-online.target$' "$DROPIN")" -eq 1 ]
}
