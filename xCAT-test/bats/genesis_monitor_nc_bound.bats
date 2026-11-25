#!/usr/bin/env bats
#
# send_monitor_msg must return when the monitor server accepts the connection and never
# closes it. nc keeps reading until the server closes, and sysclone waits for nc.

load 'helpers/shell_source'

setup()
{
    local functions
    functions="$(require_repo_file 'xCAT-genesis-scripts/etc/init.d/functions')"
    LIB="${BATS_TEST_TMPDIR}/monitor.sh"
    extract_shell_function "$functions" send_monitor_msg >"$LIB"
    STUBS="${BATS_TEST_TMPDIR}/bin"
    NC_PID="${BATS_TEST_TMPDIR}/nc.pid"
    NC_ARGS="${BATS_TEST_TMPDIR}/nc.args"
    NC_INPUT="${BATS_TEST_TMPDIR}/nc.input"
    mkdir -p "$STUBS"
    # nc reads the message, then stays connected and idle, like a server that never closes.
    printf '#!/bin/sh\necho $$ >"%s"\necho "$*" >"%s"\nhead -n 1 >"%s"\nexec sleep 600\n' \
        "$NC_PID" "$NC_ARGS" "$NC_INPUT" >"$STUBS/nc"
    chmod +x "$STUBS/nc"
}

teardown()
{
    [ -s "$NC_PID" ] && kill "$(cat "$NC_PID")" 2>/dev/null
    return 0
}

@test "send_monitor_msg returns when the monitor server does not close the connection" {
    run timeout 30 env PATH="$STUBS:$PATH" bash -c '
        MONITOR_SERVER=192.0.2.1
        mac=42.00.c0.a8.00.0a
        . "$1"
        send_monitor_msg "status=0:speed=0"
    ' bash "$LIB"
    [ "$status" -ne 124 ]
    grep -q '192.0.2.1 8181$' "$NC_ARGS"
    grep -q '^mac=42.00.c0.a8.00.0a:.*:status=0:speed=0$' "$NC_INPUT"
}
