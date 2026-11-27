#!/usr/bin/env bats
#
# A node that boots its old disk instead of the installer also reaches status=booted. After a
# diskful install, "nodeset next" sets currstate to "boot"; a node that never ran the installer
# keeps the "install ..." currstate that rinstall set. retry_install.sh must not report that try
# as a provision success.
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
    : >"$RINSTALL_CALLS"
    export WAIT_FOR_PROVISION=1
    export PING_RETRY_SLEEP=0
    export PING_TRIES=1

    lsdef()
    {
        case "$*" in
        *"-i vmhost"*) echo "$1: vmhost=" ;;
        *"-i status"*) echo "$1: status=booted" ;;
        *"-i currstate"*) echo "$1: currstate=$CURRSTATE" ;;
        "-l "*) echo "    status=booted" ;;
        esac
    }
    rinstall() { echo "$*" >>"$RINSTALL_CALLS"; }
    sleep() { :; }
    ssh() { :; }
    ping() { :; }
    xdsh() { :; }
    export -f lsdef rinstall sleep ssh ping xdsh
}

rinstall_calls()
{
    wc -l <"$RINSTALL_CALLS" | tr -d ' '
}

@test "a booted node whose currstate is still install did not install and fails every try" {
    export CURRSTATE='install alma9.8-x86_64-compute'
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -ne 0 ]
    [ "$(rinstall_calls)" -eq 2 ]
    [[ "$output" == *"$NODE booted without running the installer"* ]]
    [[ "$output" != *"The provision succeeded"* ]]
}

@test "a booted node whose install set currstate to boot succeeds on the first try" {
    export CURRSTATE=boot
    run bash "$SCRIPT" "$NODE" "$IMAGE"
    [ "$status" -eq 0 ]
    [ "$(rinstall_calls)" -eq 1 ]
}

@test "a booted diskless node keeps its netboot currstate and succeeds on the first try" {
    export CURRSTATE='netboot alma9.8-x86_64-compute'
    run bash "$SCRIPT" "$NODE" img-netboot-compute
    [ "$status" -eq 0 ]
    [ "$(rinstall_calls)" -eq 1 ]
}
