#!/usr/bin/env bats

load 'helpers/shell_source'

setup()
{
    SCRIPT_LIB="$(repo_path 'xCAT-server/share/xcat/install/scripts/scriptlib')"
    [ -r "$SCRIPT_LIB" ] || skip "$SCRIPT_LIB is required"
    export SCRIPT_LIB
    ARGV_LOG="${BATS_TEST_TMPDIR}/updateflag-argv"
    export XCAT_FLAGGER_ARGV="$ARGV_LOG"
}

# The real flagger opens a TCP socket. The stub records its arguments instead, so the test reads
# the address the caller chose.
stub_flagger()
{
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$bin"
    cat >"$bin/updateflag.awk" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >"$XCAT_FLAGGER_ARGV"
STUB
    chmod 0755 "$bin/updateflag.awk"
    PATH="$bin:$PATH"
}

call_updateflag()
{
    stub_flagger
    source "$SCRIPT_LIB"
    xcat_updateflag updateflag.awk "$@"
}

@test "the install status callback dials the resolved address" {
    MASTER=xcat58-mn
    MASTER_IP=192.0.2.1

    run call_updateflag 3002
    [ "$status" -eq 0 ]
    [ "$(read_file_or_empty "$ARGV_LOG")" = "192.0.2.1 3002" ]
}

@test "the failed install status callback dials the resolved address" {
    MASTER=xcat58-mn
    MASTER_IP=192.0.2.1

    run call_updateflag 3002 "installstatus failed"
    [ "$status" -eq 0 ]
    [ "$(read_file_or_empty "$ARGV_LOG")" = "192.0.2.1 3002 installstatus failed" ]
}

@test "a node with no resolved address keeps the management node name" {
    MASTER=xcat58-mn
    MASTER_IP=

    run call_updateflag 3002
    [ "$status" -eq 0 ]
    [ "$(read_file_or_empty "$ARGV_LOG")" = "xcat58-mn 3002" ]
}
