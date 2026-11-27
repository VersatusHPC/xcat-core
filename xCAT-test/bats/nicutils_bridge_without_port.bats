#!/usr/bin/env bats
# create_bridge_interface_nmcli in nicutils.sh builds a bridge from the
# nicdevices of the bridge. nmcli, logger and the table helpers are shell
# functions, so nothing on the host changes.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    NICUTILS="$(require_repo_file 'xCAT/postscripts/nicutils.sh')"
    LOGGER="${BATS_TEST_TMPDIR}/logger.log"
    NMCLI="${BATS_TEST_TMPDIR}/nmcli.log"
    : >"$LOGGER"
    : >"$NMCLI"
    export LOGGER NMCLI
}

run_bridge()
{
    . "$NICUTILS"
    nmcli() { echo "nmcli $*" >>"$NMCLI"; return 0; }
    logger() { echo "logger $*" >>"$LOGGER"; }
    query_nicnetworks_net() { echo 30_5_0_0-255_255_0_0; }
    get_network_attr() { [ "$2" = mask ] && echo 255.255.0.0; return 0; }
    create_bridge_interface_nmcli "$@"
}

@test "a bridge with no port device fails before nmcli is called" {
    run run_bridge ifname=br22 _brtype=bridge _port= _pretype= _ipaddr=30.5.106.8
    [ "$status" -eq 1 ]
    grep -q 'local4.err bridge br22 has no port device in nics.nicdevices' "$LOGGER"
    run -1 grep -q 'nmcli' "$NMCLI"
}

@test "check_and_set_device_managed refuses an empty device name" {
    check()
    {
        . "$NICUTILS"
        nmcli() { echo "nmcli $*" >>"$NMCLI"; return 0; }
        logger() { echo "logger $*" >>"$LOGGER"; }
        check_and_set_device_managed ''
    }
    run check
    [ "$status" -eq 1 ]
    run -1 grep -q 'nmcli' "$NMCLI"
}
