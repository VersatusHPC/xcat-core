#!/usr/bin/env bats
# msgutil_r must return when every remote log path fails and nc never ends.
# A log server that accepts the connection and never closes it keeps nc
# running, and updatenode then waits for the postscript forever.
# xcatlib.sh serves the postscripts; scriptlib serves the install scripts.

load 'helpers/shell_source'

setup()
{
    STUBS="${BATS_TEST_TMPDIR}/bin"
    NC_PID="${BATS_TEST_TMPDIR}/nc.pid"
    NC_ARGS="${BATS_TEST_TMPDIR}/nc.args"
    LOGFILE="${BATS_TEST_TMPDIR}/xcat.log"
    mkdir -p "$STUBS"

    # logger fails, so the logger -n path and the /dev/udp path both fail.
    printf '#!/bin/sh\nexit 1\n' >"$STUBS/logger"
    # nc stays connected and idle, like a server that never closes.
    printf '#!/bin/sh\necho $$ >"%s"\necho "$*" >"%s"\nexec sleep 600\n' "$NC_PID" "$NC_ARGS" >"$STUBS/nc"
    chmod +x "$STUBS/logger" "$STUBS/nc"
}

teardown()
{
    [ -s "$NC_PID" ] && kill "$(cat "$NC_PID")" 2>/dev/null
    return 0
}

# log_with <library> -- run msgutil_r from <library>, bounded at 30 seconds.
log_with()
{
    run timeout 30 env PATH="$STUBS:$PATH" bash -c \
        'source "$1"; msgutil_r 192.0.2.1 info "configeth done" "$2" xcat' \
        _ "$1" "$LOGFILE"
}

@test "xcatlib.sh msgutil_r returns when nc to the log server does not end" {
    log_with "$(require_repo_file 'xCAT/postscripts/xcatlib.sh')"
    [ "$status" -ne 124 ]
    grep -q 'configeth done' "$LOGFILE"
    grep -q '192.0.2.1 514$' "$NC_ARGS"
}

@test "scriptlib msgutil_r returns when nc to the log server does not end" {
    log_with "$(require_repo_file 'xCAT-server/share/xcat/install/scripts/scriptlib')"
    [ "$status" -ne 124 ]
    grep -q 'configeth done' "$LOGFILE"
    grep -q '192.0.2.1 514$' "$NC_ARGS"
}
