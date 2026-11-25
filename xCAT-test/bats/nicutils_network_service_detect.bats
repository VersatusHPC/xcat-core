#!/usr/bin/env bats
# check_NetworkManager_or_network_service in nicutils.sh picks the network
# configuration path for confignetwork. checkservicestatus, the service
# helpers, ps and logger are shell functions, so nothing on the host changes.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    NICUTILS="$(require_repo_file 'xCAT/postscripts/nicutils.sh')"
    LOGGER="${BATS_TEST_TMPDIR}/logger.log"
    : >"$LOGGER"
    export LOGGER
    ACTIVE=''
}

# $ACTIVE lists the units that checkservicestatus reports active.
run_detect()
{
    checkservicestatus()
    {
        case " $ACTIVE " in *" $1 "*) return 0 ;; esac
        return 1
    }
    stopservice() { :; }
    disableservice() { :; }
    ps() { :; }
    logger() { echo "logger $*" >>"$LOGGER"; }
    . "$NICUTILS"
    check_NetworkManager_or_network_service
}

@test "a systemd-networkd node takes the non-NetworkManager path without an error" {
    ACTIVE='systemd-networkd'
    run run_detect
    [ "$status" -eq 2 ]
    run -1 grep -q 'local4.err' "$LOGGER"
    grep -q 'local4.info systemd-networkd is active' "$LOGGER"
}

@test "a node with no network service still logs an error" {
    run run_detect
    [ "$status" -eq 2 ]
    grep -q 'local4.err NetworkManager, network.service and networking service are not active' "$LOGGER"
}

@test "a node with network.service still uses it" {
    ACTIVE='network systemd-networkd'
    run run_detect
    [ "$status" -eq 0 ]
    run -1 grep -q 'local4.err' "$LOGGER"
}
