#!/usr/bin/env bats
#
# configib on EL 9 and later: the IPoIB interface is a NetworkManager connection made with nmcli.
# The tests read the nmcli arguments and check that no ifcfg file is written.

load 'helpers/configib'

setup()
{
    setup_configib
    el_root
    ib_device ib0
}

ib_el10()
{
    run_configib OSVER=rhels10 NMCLI_USED=1 NIC_IBNICS=ib0 NETWORKS_LINES=2 \
        NETWORKS_LINE1="$(ib_network ib4 10.10.0.0 255.255.0.0)" \
        NETWORKS_LINE2="$(ib_network ib6 fd00:10:: /64)" "$@"
}

@test "an IPv4 address makes an infiniband connection with the network prefix" {
    ib_el10 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'nmcli con add type infiniband con-name ib0 ifname ib0 ipv4.method manual ipv4.addresses 10.10.0.5/16' "$EVENTS" \
        || { show_events; false; }
    grep -qx 'nmcli con up ib0' "$EVENTS" || { show_events; false; }
}

@test "an IPv6 address keeps the prefix of its network" {
    ib_el10 'NICIPS=ib0!fd00:10::5' 'NICNETWORKS=ib0!ib6'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'nmcli con add type infiniband con-name ib0 ifname ib0 ipv6.method manual ipv6.addresses fd00:10::5/64' "$EVENTS" \
        || { show_events; false; }
}

@test "an existing connection is modified, not added again" {
    : >"$ROOT/nmcli/ib0"
    ib_el10 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'nmcli con modify ib0 type infiniband con-name ib0 ifname ib0 connection.autoconnect yes ipv4.method manual ipv4.addresses 10.10.0.5/16' "$EVENTS" \
        || { show_events; false; }
    refute_grep -q 'nmcli con add' "$EVENTS"
}

@test "a second address is added to the connection and does not replace the first" {
    ib_el10 'NICIPS=ib0!10.10.0.5|fd00:10::5' 'NICNETWORKS=ib0!ib4|ib6'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'nmcli con add type infiniband con-name ib0 ifname ib0 ipv4.method manual ipv4.addresses 10.10.0.5/16' "$EVENTS" \
        || { show_events; false; }
    grep -qx 'nmcli con modify ib0 ipv6.method manual +ipv6.addresses fd00:10::5/64' "$EVENTS" \
        || { show_events; false; }
}

@test "no ifcfg file is written on EL 10" {
    ib_el10 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    [ -z "$(ls -A "$ROOT/etc/sysconfig/network-scripts")" ]
}
