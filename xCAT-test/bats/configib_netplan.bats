#!/usr/bin/env bats
#
# configib on Ubuntu 24.04. netplan renders the network of the node and ifupdown is not
# installed, so /etc/network/interfaces and ifup configure nothing. configib writes a netplan
# drop-in for each IB nic and runs netplan apply.

load 'helpers/configib'

setup()
{
    setup_configib
    ubuntu_root
    mkdir -p "$ROOT/etc/netplan"
    ib_device ib0
    YAML="$ROOT/etc/netplan/90-xcat-ib0.yaml"
}

ib_noble()
{
    run_configib OSVER=ubuntu24.04 NIC_IBNICS=ib0 NETWORKS_LINES=2 \
        NETWORKS_LINE1="$(ib_network ib4 10.10.0.0 255.255.0.0)" \
        NETWORKS_LINE2="$(ib_network ib6 fd00:10:: /64)" "$@"
}

# The addresses: list of the drop-in, one address per line.
yaml_addresses()
{
    sed -n 's/^        - //p' "$YAML"
}

@test "an IPv4 address is written to a netplan drop-in with its prefix" {
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    [ -f "$YAML" ] || { show_events; false; }
    grep -qx '    ib0:' "$YAML"
    grep -qx '      dhcp4: false' "$YAML"
    grep -qx '      dhcp6: false' "$YAML"
    [ "$(yaml_addresses)" = '10.10.0.5/16' ]
}

@test "netplan apply makes the drop-in live, and nothing uses ifupdown" {
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx 'netplan apply' "$EVENTS" || { show_events; false; }
    refute_grep -q '^ifup ' "$EVENTS"
    [ ! -e "$ROOT/etc/network/interfaces" ]
}

@test "an IPv4 and an IPv6 address are both kept, in order" {
    ib_noble 'NICIPS=ib0!10.10.0.5|fd00:10::5' 'NICNETWORKS=ib0!ib4|ib6'
    [ "$status" -eq 0 ] || { show_events; false; }
    [ "$(yaml_addresses | tr '\n' ' ')" = '10.10.0.5/16 fd00:10::5/64 ' ]
}

@test "a second run replaces the drop-in and does not add the address again" {
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    ib_noble 'NICIPS=ib0!10.10.0.6' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    [ "$(yaml_addresses)" = '10.10.0.6/16' ]
}

@test "the drop-in is readable by root only, as netplan requires" {
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4'
    [ "$status" -eq 0 ] || { show_events; false; }
    [ "$(stat -c %a "$YAML")" = 600 ]
}

@test "an MTU in nicextraparams becomes the netplan mtu" {
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4' 'NICEXTRAPARAMS=ib0!MTU=2044'
    [ "$status" -eq 0 ] || { show_events; false; }
    grep -qx '      mtu: 2044' "$YAML"
}

@test "a node where ifupdown runs keeps /etc/network/interfaces" {
    printf '#!/bin/sh\necho "ifup $*" >>"$EVENTS"\n' >"$BIN/ifup"
    chmod 0755 "$BIN/ifup"
    mkdir -p "$ROOT/etc/network"
    : >"$ROOT/etc/network/interfaces"
    ib_noble 'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4' SYSTEMCTL_ACTIVE_RC=0
    [ "$status" -eq 0 ] || { show_events; false; }
    [ ! -e "$YAML" ]
    grep -qx 'iface ib0 inet static' "$ROOT/etc/network/interfaces"
}
