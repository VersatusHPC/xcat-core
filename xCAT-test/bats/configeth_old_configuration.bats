#!/usr/bin/env bats
#
# configeth records the state of the nic before it changes it. The record is not an error,
# and at local4.err it reaches cluster.log as one on every confignetwork run.

load 'helpers/shell_source'

setup()
{
    local configeth
    configeth="$(require_repo_file 'xCAT/postscripts/configeth')"
    LIB="${BATS_TEST_TMPDIR}/configeth.sh"
    extract_shell_function "$configeth" log_old_configuration >"$LIB" || {
        echo 'configeth has no log_old_configuration' >&2
        return 1
    }
    STUBS="${BATS_TEST_TMPDIR}/bin"
    LOGGED="${BATS_TEST_TMPDIR}/logger.args"
    mkdir -p "$STUBS"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$LOGGED" >"$STUBS/logger"
    printf '#!/bin/sh\necho "3: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"\n' >"$STUBS/ip"
    chmod +x "$STUBS/logger" "$STUBS/ip"
}

old_configuration()
{
    PATH="$STUBS:$PATH" bash -c '
        log_label=xcat.updatenode.postscript
        NODE=cn1
        str_os_type=linux
        . "$1"
        log_old_configuration ens4
    ' bash "$LIB"
}

@test "the old configuration is logged at info priority" {
    run old_configuration
    [ "$status" -eq 0 ]
    [ "$output" = 'configeth on cn1: old configuration: 3: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500' ]
    [ "$(cat "$LOGGED")" = '-t xcat.updatenode.postscript -p local4.info configeth: old configuration: 3: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500' ]
}
