#!/usr/bin/env bats
#
# xcat-network.sh turns the installer bootstrap network plan into the rc.conf
# block and the saved ownership plan of the installed node. The awk planner
# must then reproduce that plan from the node inventory.

load 'helpers/freebsd'

MAC='52:54:00:00:00:01'
NICTYPES_V='vtnet0!ethernet,vtnet1!ethernet,lagg0!lagg,vlan100!vlan,bridge0!bridge'
NICDEVICES_V='lagg0!vtnet0|vtnet1,vlan100!lagg0,bridge0!vlan100'
NICEXTRAPARAMS_V='lagg0!LAGGPROTO=failover,bridge0!STP=no'

setup()
{
    HELPER="$(freebsd_installer_dir)/xcat-network.sh"
    PLANNER="${XCAT_FREEBSD_NETWORK_PLANNER:-$(repo_path 'xCAT/postscripts/confignetwork-freebsd.awk')}"
    WORK="$BATS_TEST_TMPDIR"
}

# produce <interface> <nictypes> <nicdevices> <nicextraparams> <nicsadapter> [mtu]
# The Perl producer writes the encoded description and the bootstrap plan.
produce()
{
    perl -I"$(repo_path 'xCAT-server/lib/perl')" -I"$(repo_path 'perl-xCAT')" -MxCAT::FreeBSDNetwork -e '
        my ($dir, $planner, $if, $mac, $types, $devices, $extra, $adapter, $mtu) = @ARGV;
        my %nics = (nictypes => $types, nicsadapter => $adapter);
        $nics{nicdevices} = $devices if length $devices;
        $nics{nicextraparams} = $extra if length $extra;
        my $encoded = xCAT::FreeBSDNetwork::encode($if, $mac, \%nics, $planner, length($mtu) ? $mtu : ());
        open(my $e, ">", "$dir/encoded") or die $!; print {$e} $encoded; close($e) or die $!;
        open(my $p, ">", "$dir/bootstrap.plan") or die $!;
        print {$p} xCAT::FreeBSDNetwork::compile($encoded, $planner); close($p) or die $!;
    ' "$WORK" "$PLANNER" "$1" "$MAC" "$2" "$3" "$4" "$5" "${6:-}"
}

# handoff <gateway>: run xcat_network_rc with the produced plan at the compiler seam.
handoff()
{
    XCAT_WORK="$WORK" FIXTURE_PLAN="$WORK/bootstrap.plan" \
        XCAT_BOOTSTRAP_NETWORK_BASE64="$(cat "$WORK/encoded")" XCAT_MAC="$MAC" \
        XCAT_IPV4=192.0.2.10 XCAT_NETMASK=255.255.255.0 XCAT_GATEWAY="$1" \
        run sh -eu -c '. "$1"; xcat_network_plan() { cp "$FIXTURE_PLAN" "$3"; }; xcat_network_rc' sh "$HELPER"
}

virtual_inventory()
{
    produce bridge0 "$NICTYPES_V" "$NICDEVICES_V" "$NICEXTRAPARAMS_V" \
        "vtnet0!mac=$MAC linkstate=UP,vtnet1!mac=52:54:00:00:00:02,vtnet9!mac=52:54:00:00:00:09" 9000
}

# adopt [extra awk arguments]: compile the installed-node plan from the inventory.
adopt()
{
    NICTYPES="$NICTYPES_V" NICDEVICES="$NICDEVICES_V" NICEXTRAPARAMS="${EXTRA:-$NICEXTRAPARAMS_V}" \
        NICIPS='bridge0!192.0.2.10' NICNETWORKS='bridge0!provision' IPADDR=192.0.2.10 NETWORKS_LINES=1 \
        NETWORKS_LINE1="netname=provision||net=192.0.2.0||mask=255.255.255.0||gateway=${GATEWAY:-192.0.2.1}||mtu=9000||disable=" \
        run awk -v bootnic=vtnet0 -v bootmac="$MAC" -v configure_boot=1 "$@" -f "$PLANNER"
}

@test "the installer handoff writes the managed rc.conf block for a virtual leaf" {
    virtual_inventory
    handoff 192.0.2.1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '# BEGIN xCAT FreeBSD network' ]
    [[ "$output" == *$'\nifconfig_bridge0_alias0="inet 192.0.2.10/24"\n'* ]]
    [[ "$output" == *$'\nifconfig_bridge0="ether 52:54:00:00:00:01 '* ]]
    [[ "$output" == *$'\ndefaultrouter="192.0.2.1"\n'* ]]
    [[ "$output" == *$'\nstatic_routes=""\n'* ]]
    [[ "$output" == *$'\nipv6_static_routes=""'* ]]
}

@test "the saved plan uses the installed network contract and keeps no bootstrap records" {
    virtual_inventory
    handoff 192.0.2.1
    [ "$status" -eq 0 ]
    state="$(cat "$WORK/target-network.plan")"
    [ "$(head -n1 "$WORK/target-network.plan")" = $'F\txcat-freebsd-network-1' ]
    grep -qx $'A\tbridge0\tinet\t192.0.2.10\t24' "$WORK/target-network.plan"
    grep -qx $'D\tinet\t192.0.2.1' "$WORK/target-network.plan"
    ! grep -q $'^[BM]\t' "$WORK/target-network.plan"
}

@test "the awk planner adopts the installed plan unchanged" {
    virtual_inventory
    handoff 192.0.2.1
    adopt
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$WORK/target-network.plan")" ]
}

@test "the controller gateway token keeps the default route that the installer owns" {
    virtual_inventory
    handoff 192.0.2.1
    GATEWAY='<xcatmaster>' adopt -v owned_ipv4_gateway=192.0.2.1
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$WORK/target-network.plan")" ]
}

@test "DHCP on the management bridge keeps the MAC and replaces the static address" {
    virtual_inventory
    handoff 192.0.2.1
    EXTRA="$NICEXTRAPARAMS_V BOOTPROTO=dhcp" GATEWAY='<xcatmaster>' adopt -v owned_ipv4_gateway=192.0.2.1
    [ "$status" -eq 0 ]
    [[ "$output" == *$'K\tifconfig_bridge0\tSYNCDHCP ether '"$MAC "* ]]
    ! grep -qE $'^K\tifconfig_bridge0_alias[0-9]+\tinet ' <<<"$output"
    ! grep -q $'^D\tinet\t' <<<"$output"
}

@test "a physical bootstrap interface keeps its primary address command" {
    produce vtnet0 'vtnet0!ethernet' '' '' "vtnet0!mac=$MAC"
    handoff ''
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nifconfig_vtnet0="inet 192.0.2.10/24 mtu 1500 up"\n'* ]]
    [[ "$output" != *ifconfig_vtnet0_alias* ]]
}
