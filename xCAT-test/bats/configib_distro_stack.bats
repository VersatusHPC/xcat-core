#!/usr/bin/env bats
#
# configib on a node with the rdma-core stack of the distribution. That stack has no openibd
# service: MLNX_OFED installs openibd. udev loads ib_ipoib when it finds an IB device, but only
# if rdma-core was installed before the device was found, so configib loads ib_ipoib itself.

load 'helpers/configib'

setup()
{
    setup_configib
    el_root
    ib_device ib0
}

ib_el10()
{
    run_configib OSVER=rhels10 NMCLI_USED=1 NIC_IBNICS=ib0 NETWORKS_LINES=1 \
        NETWORKS_LINE1="$(ib_network ib4 10.10.0.0 255.255.0.0)" \
        'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
}

@test "the distribution stack loads ib_ipoib" {
    ib_el10
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'modprobe ib_ipoib' "$EVENTS" || { show_events; false; }
}

@test "the distribution stack does not use openibd" {
    ib_el10
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -q '^logger .*distribution RDMA stack' "$EVENTS" || { show_events; false; }
    refute_grep -q 'openibd' "$EVENTS"
}

@test "a node with MLNX_OFED keeps openibd and does not load ib_ipoib" {
    mkdir -p "$ROOT/etc/init.d"
    printf '#!/bin/sh\n' >"$ROOT/etc/init.d/openibd"
    ib_el10
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -q '^logger .*openibd' "$EVENTS" || { show_events; false; }
    refute_grep -q 'modprobe ib_ipoib' "$EVENTS"
}

@test "a failed modprobe is a warning, not a failure" {
    printf '#!/bin/sh\necho "modprobe $*" >>"$EVENTS"\nexit 1\n' >"$BIN/modprobe"
    ib_el10
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -q '^logger .*ib_ipoib' "$EVENTS" || { show_events; false; }
}
