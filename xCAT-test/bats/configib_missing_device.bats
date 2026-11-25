#!/usr/bin/env bats
#
# configib on a node where an InfiniBand nic of the nics table has no InfiniBand device. A broken
# driver in an image looks exactly like this, and the CI cannot provision over IB, so configib
# fails loudly: it names the nic, writes no configuration for it, and exits non-zero.

load 'helpers/configib'

setup()
{
    setup_configib
}

ib_el10()
{
    el_root
    run_configib OSVER=rhels10 NMCLI_USED=1 NIC_IBNICS=ib0 NETWORKS_LINES=1 \
        NETWORKS_LINE1="$(ib_network ib4 10.10.0.0 255.255.0.0)" \
        'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4' "$@"
}

ib_noble()
{
    ubuntu_root
    mkdir -p "$ROOT/etc/netplan"
    run_configib OSVER=ubuntu24.04 NIC_IBNICS=ib0 NETWORKS_LINES=1 \
        NETWORKS_LINE1="$(ib_network ib4 10.10.0.0 255.255.0.0)" \
        'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4' "$@"
}

MISSING='configib: ERROR: ib0 is an InfiniBand nic in the nics table, but the node has no InfiniBand device ib0'

@test "EL 10 without the device: configib fails, names the nic and writes no connection" {
    ib_el10
    [ "$status" -ne 0 ] || { show_events; false; }
    [[ "$output" == *"$MISSING"* ]] || { show_events; false; }
    grep -qF "logger -p local4.err -t xcat $MISSING" "$EVENTS" || { show_events; false; }
    refute_grep -q 'nmcli con add' "$EVENTS"
    refute_grep -q 'nmcli con up' "$EVENTS"
}

@test "EL 10 with an Ethernet device named ib0: configib fails" {
    ib_device ib0 1
    ib_el10
    [ "$status" -ne 0 ] || { show_events; false; }
    [[ "$output" == *'configib: ERROR: ib0 is an InfiniBand nic in the nics table, but the link layer of ib0 is not InfiniBand'* ]] \
        || { show_events; false; }
    refute_grep -q 'nmcli con add' "$EVENTS"
}

@test "EL 10 with the device: a connection that does not come up fails configib" {
    ib_device ib0
    ib_el10 NMCLI_UP_RC=4
    [ "$status" -ne 0 ] || { show_events; false; }
    grep -qx 'nmcli con up ib0' "$EVENTS"
}

@test "Ubuntu 24.04 without the device: configib fails and writes no drop-in" {
    ib_noble
    [ "$status" -ne 0 ] || { show_events; false; }
    [[ "$output" == *"$MISSING"* ]] || { show_events; false; }
    [ ! -e "$ROOT/etc/netplan/90-xcat-ib0.yaml" ]
    refute_grep -q 'netplan apply' "$EVENTS"
}

@test "Ubuntu 24.04 with the device: a failed netplan apply fails configib" {
    ib_device ib0
    printf '#!/bin/sh\necho "netplan $*" >>"$EVENTS"\nexit 1\n' >"$BIN/netplan"
    ib_noble
    [ "$status" -ne 0 ] || { show_events; false; }
}
