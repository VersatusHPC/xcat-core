#!/usr/bin/env bats
#
# retry_install.sh retries rinstall when a try does not end in "booted". A node whose status stays
# "powering-on" for the whole try never reached the network boot, and a second rinstall on the
# same node and network does not change that. The script must stop after the first try and name
# the cause.
#
# The stubs replace the xCAT commands and sleep(1) as exported shell functions, so the script runs
# its real loop in a child bash without an xCAT database and without waiting.

load 'helpers/shell_source'

NODE=cn01
IMAGE=img-install-compute

setup()
{
    SCRIPT="$(require_repo_file 'xCAT-test/autotest/testcase/commoncmd/retry_install.sh')"
    export RINSTALL_CALLS="${BATS_TEST_TMPDIR}/rinstall-calls"
    export STATUS_READS="${BATS_TEST_TMPDIR}/status-reads"
    : >"$RINSTALL_CALLS"
    : >"$STATUS_READS"
    export WAIT_FOR_PROVISION=1
    export PING_RETRY_SLEEP=0
    export PING_TRIES=1

    # The status is STATUS_FIRST for the first STATUS_FIRST_READS reads, then STATUS_THEN.
    node_status()
    {
        local n
        n=$(($(wc -l <"$STATUS_READS") + 1))
        echo "$n" >>"$STATUS_READS"
        if [ "$n" -le "$STATUS_FIRST_READS" ]; then
            echo "$STATUS_FIRST"
        else
            echo "$STATUS_THEN"
        fi
    }
    lsdef()
    {
        case "$*" in
        *"-i vmhost"*) echo "$1: vmhost=" ;;
        *"-i status"*) echo "$1: status=$(node_status)" ;;
        "-l "*) echo "    status=$(node_status)" ;;
        esac
    }
    rinstall() { echo "$*" >>"$RINSTALL_CALLS"; }
    sleep() { :; }
    ssh() { :; }
    ping() { [ "$STATUS_THEN" = booted ]; }
    xdsh() { [ "$STATUS_THEN" = booted ]; }
    export -f node_status lsdef rinstall sleep ssh ping xdsh
}

rinstall_calls()
{
    wc -l <"$RINSTALL_CALLS" | tr -d ' '
}

@test "a node that stays powering-on for the whole try fails at once as never netbooted" {
    export STATUS_FIRST=powering-on STATUS_FIRST_READS=0 STATUS_THEN=powering-on
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -ne 0 ]
    [ "$(rinstall_calls)" -eq 1 ]
    [[ "$output" == *"$NODE never netbooted"* ]]
}

@test "a node that left powering-on and then stalled still gets the second try" {
    # The discriminator: a stop after every failed first try also passes the test above.
    export STATUS_FIRST=powering-on STATUS_FIRST_READS=2 STATUS_THEN=installing
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -ne 0 ]
    [ "$(rinstall_calls)" -eq 2 ]
    [[ "$output" != *"never netbooted"* ]]
}

@test "a node that boots after powering-on succeeds on the first try" {
    export STATUS_FIRST=powering-on STATUS_FIRST_READS=3 STATUS_THEN=booted
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -eq 0 ]
    [ "$(rinstall_calls)" -eq 1 ]
}

@test "a node that is booted at the first status read succeeds on the first try" {
    export STATUS_FIRST=booted STATUS_FIRST_READS=0 STATUS_THEN=booted
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -eq 0 ]
    [ "$(rinstall_calls)" -eq 1 ]
}
