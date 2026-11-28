#!/usr/bin/env bats
# create_vlan_interface_nmcli in nicutils.sh adds the NetworkManager connection of
# a VLAN. A VLAN with no nicips, such as the port of a bridge, must get no IP
# configuration: NetworkManager starts DHCP on a connection whose ipv4.method is
# auto. nmcli, logger and the table helpers are shell functions, so nothing on the
# host changes.

bats_require_minimum_version 1.5.0

load 'helpers/shell_source'

setup()
{
    NICUTILS="$(require_repo_file 'xCAT/postscripts/nicutils.sh')"
    NMCLI="${BATS_TEST_TMPDIR}/nmcli.log"
    : >"$NMCLI"
    export NMCLI
}

run_vlan()
{
    . "$NICUTILS"
    nmcli() { echo "nmcli $*" >>"$NMCLI"; return 0; }
    logger() { :; }
    ip() { :; }
    load_kmod() { :; }
    check_and_set_device_managed() { return 0; }
    is_nmcli_connection_exist() { return 1; }
    is_connection_activate_intime() { return 1; }
    add_extra_params_nmcli() { return 0; }
    query_nicnetworks_net() { echo 30_5_0_0-255_255_0_0; }
    get_network_attr() { [ "$2" = mask ] && echo 255.255.0.0; return 0; }
    create_vlan_interface_nmcli "$@"
}

@test "a VLAN that is the port of a bridge gets no IPv4 or IPv6 configuration" {
    run run_vlan ifname=bond0 vlanid=2 next_nic=br22
    [ "$status" -eq 0 ]
    grep -q '^nmcli con add type vlan con-name xcat-vlan-bond0.2 dev bond0 id 2 ' "$NMCLI"
    grep '^nmcli con add type vlan' "$NMCLI" | grep -q ' ipv4.method disabled ipv6.method ignore '
}

@test "a VLAN with no nicips gets no IPv4 or IPv6 configuration" {
    run run_vlan ifname=eth1 vlanid=5
    [ "$status" -eq 0 ]
    grep '^nmcli con add type vlan' "$NMCLI" | grep -q ' ipv4.method disabled ipv6.method ignore '
}

@test "a VLAN with an address keeps that address and is not disabled" {
    run run_vlan ifname=eth1 vlanid=5 ipaddrs=30.5.106.8
    [ "$status" -eq 0 ]
    grep '^nmcli con add type vlan' "$NMCLI" | grep -q ' ip4 30.5.106.8/'
    run -1 grep -q 'ipv4.method disabled' "$NMCLI"
}
