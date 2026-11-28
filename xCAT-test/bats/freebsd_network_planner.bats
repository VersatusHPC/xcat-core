#!/usr/bin/env bats
#
# confignetwork-freebsd.awk is the network planner that confignetwork.freebsd and
# xcat-network.sh run on the FreeBSD node. These tests run the shipped program with
# the postscript exports in the environment and assert on the plan it prints, or on
# its verdict about observed rc.conf, ifconfig, netstat and lease state.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

V6_10='2001:0db8:0001:0000:0000:0000:0000:0010'
LL1='fe80:0000:0000:0000:0000:0000:0000:0001'
ROUTES4=$'Internet:\nDestination Gateway Flags Netif Expire\n'
ROUTES6=$'Internet6:\nDestination Gateway Flags Netif Expire\n'

setup()
{
    PLANNER="${XCAT_FREEBSD_NETWORK_PLANNER:-$(repo_path 'xCAT/postscripts/confignetwork-freebsd.awk')}"
    WORK="$BATS_TEST_TMPDIR"
    declare -gA E=()
}

# base: the postscript exports of one data interface with IPv4 and IPv6.
base()
{
    E=([NICTYPES]='vtnet1!ethernet' [NICIPS]='vtnet1!192.0.2.10|2001:db8:1::10'
        [NICNETWORKS]='vtnet1!data4|data6' [NETWORKS_LINES]=2
        [NETWORKS_LINE1]='netname=data4||net=192.0.2.0||mask=255.255.255.0||gateway=||mtu=||disable='
        [NETWORKS_LINE2]='netname=data6||net=2001:db8:1::||mask=64||gateway=||mtu=||disable='
        [IPADDR]=198.51.100.10 [MASTER_IP]=198.51.100.1)
}

# chain: a bridge on a VLAN on an LACP aggregate.
chain()
{
    base
    E[NICTYPES]='bridge0!bridge,vlan100!vlan,lagg0!bond,vtnet2!ethernet,vtnet1!ethernet'
    E[NICDEVICES]='bridge0!vlan100,vlan100!lagg0,lagg0!vtnet1|vtnet2'
    E[NICIPS]=${E[NICIPS]/vtnet1/bridge0}
    E[NICNETWORKS]=${E[NICNETWORKS]/vtnet1/bridge0}
    E[NICEXTRAPARAMS]='lagg0!LAGGPROTO=lacp'
}

# on_boot_nic: move the data interface of base to the installation NIC vtnet0.
on_boot_nic()
{
    local key
    for key in NICTYPES NICIPS NICNETWORKS; do E[$key]=${E[$key]//vtnet1/vtnet0}; done
    E[IPADDR]=192.0.2.10
}

# planner [awk arguments]: run the planner with only the E exports.
planner()
{
    local -a exports=(PATH="$PATH" LC_ALL=C)
    local key
    for key in "${!E[@]}"; do exports+=("$key=${E[$key]}"); done
    run --separate-stderr env -i "${exports[@]}" awk -f "$PLANNER" "$@" </dev/null
}

# bare [awk arguments]: run the planner with no exports.
bare() { run --separate-stderr env -i PATH="$PATH" LC_ALL=C awk -f "$PLANNER" "$@" </dev/null; }

# compile [configure_boot]: compile the application plan.
compile() { planner -v bootnic=vtnet0 -v configure_boot="${1:-0}"; }

# inspect <mode> <plan> <observed> [awk arguments]: check observed state against a plan.
# IENV is one optional export, BOOT the configure_boot value.
inspect()
{
    printf '%s' "$2" >"$WORK/plan"
    printf '%s' "$3" >"$WORK/observed"
    run --separate-stderr env -i PATH="$PATH" LC_ALL=C ${IENV:+"$IENV"} awk -f "$PLANNER" \
        -v mode="$1" -v configure_boot="${BOOT:-0}" "${@:4}" "$WORK/plan" "$WORK/observed" </dev/null
}

# rows <kind> [text]: the plan records of one kind.
rows() { grep "^$1"$'\t' <<<"${2-$output}" || true; }

# value <kind> <key> [text]: the value of the only record with that key.
value()
{
    awk -F '\t' -v kind="$1" -v key="$2" '$1 == kind && $2 == key { n++; v = $3 } END { if (n != 1) exit 1; print v }' \
        <<<"${3-$output}"
}

undefined() { if value "$@" >/dev/null; then echo "$1 $2 is defined"; return 1; fi; }

is() { [ "$1" = "$2" ] || { printf 'expected: %s\nactual:   %s\n' "$2" "$1"; return 1; }; }

# succeeds / fails [pattern]: the last run status, and for a failure an ERE on stderr.
succeeds() { [ "$status" -eq 0 ] || { echo "status $status: $stderr"; return 1; }; }
fails()
{
    [ "$status" -ne 0 ] || { echo "accepted: $output"; return 1; }
    [ -z "${1-}" ] || [[ "$stderr" =~ $1 ]] || { echo "stderr: $stderr"; return 1; }
}

# rejects <pattern>: the plan is rejected with that diagnostic and nothing on stdout.
rejects()
{
    compile
    fails "$1"
    [ -z "$output" ] || { echo "partial plan: $output"; return 1; }
}

kernel()
{
    cat <<'IFCONFIG'
vtnet1: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
        ether 52:54:00:12:34:56
        inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
        inet6 fe80::5054:ff:fe12:3456%vtnet1 prefixlen 64 scopeid 0x2
        inet6 2001:db8:1::10 prefixlen 64
        media: Ethernet autoselect (10Gbase-T <full-duplex>)
        status: active
        nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
IFCONFIG
}

@test "a smaller management VLAN preserves the provisioning member MTU" {
    base
    E[NICTYPES]='vtnet0!ethernet,vlan100!vlan' E[NICDEVICES]='vlan100!vtnet0' E[NICIPS]='vlan100!192.0.2.10'
    E[NICNETWORKS]='vlan100!data4' E[NICEXTRAPARAMS]='vlan100!MTU=1500' E[IPADDR]=192.0.2.10 E[NETWORKS_LINES]=1
    E[NETWORKS_LINE1]='netname=data4||net=192.0.2.0||mask=255.255.255.0||gateway=||mtu=9000||disable='
    planner -v bootnic=vtnet0 -v bootmac=52:54:00:00:00:01 -v configure_boot=1
    succeeds
    is "$(value T vtnet0)" 9000
    is "$(value T vlan100)" 1500
}

@test "a physical interface with IPv4 and IPv6 uses native rc.conf syntax" {
    base
    compile
    succeeds
    [ -z "$stderr" ]
    is "$(rows I)" $'I\tvtnet1\tethernet'
    is "$(value K ifconfig_vtnet1)" 'inet 192.0.2.10/24 mtu 1500 up'
    is "$(value K ifconfig_vtnet1_ipv6)" "inet6 $V6_10 prefixlen 64"
    undefined I vtnet0
}

@test "multiple addresses share the alias sequence and the network MTU is effective" {
    base
    E[NICIPS]='vtnet1!192.0.2.10|192.0.2.11|2001:db8:1::10|2001:db8:1::11'
    E[NICNETWORKS]='vtnet1!data4|data4|data6|data6'
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/mtu=/mtu=9000}
    E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/mtu=/mtu=9000}
    compile
    succeeds
    is "$(value K ifconfig_vtnet1_alias0)" 'inet 192.0.2.11/24'
    is "$(value K ifconfig_vtnet1_alias1)" 'inet6 2001:0db8:0001:0000:0000:0000:0000:0011/64'
    is "$(value T vtnet1)" 9000
}

@test "network MTUs use numeric ordering" {
    base
    E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/mtu=/mtu=900}
    rejects 'IPv6 requires an MTU'
    base
    E[NICTYPES]+=',vlan100!vlan' E[NICDEVICES]='vlan100!vtnet1' E[NICIPS]='vlan100!192.0.2.10'
    E[NICNETWORKS]='vlan100!data4' E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/mtu=/mtu=900}
    compile
    succeeds
    is "$(value T vlan100)" 900
    is "$(value T vtnet1)" 1500
}

@test "data gateways and xcatmaster preserve the installed IPv4 default" {
    local gateway invalid
    for gateway in '<xcatmaster>' 203.0.113.1; do
        base
        E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=$gateway}
        compile
        succeeds
        undefined K defaultrouter
    done
    base
    on_boot_nic
    E[MASTER_IP]=192.0.2.1 E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=<xcatmaster>}
    compile 1
    succeeds
    undefined K defaultrouter
    planner -v bootnic=vtnet0 -v configure_boot=1 -v owned_ipv4_gateway=192.0.2.1
    succeeds
    is "$(value K defaultrouter)" 192.0.2.1
    for invalid in 198.51.100.1 invalid $'192.0.2.1\n192.0.2.2'; do
        planner -v bootnic=vtnet0 -v configure_boot=1 -v owned_ipv4_gateway="$invalid"
        fails
        [ -z "$output" ]
    done
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/<xcatmaster>/}
    planner -v bootnic=vtnet0 -v configure_boot=1 -v owned_ipv4_gateway=192.0.2.1
    succeeds
    undefined K defaultrouter
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=192.0.2.1}
    compile 1
    succeeds
    is "$(value K defaultrouter)" 192.0.2.1
}

@test "an IPv6 CIDR network and a slash-prefixed mask keep the prefix and the route" {
    base
    E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/'net=2001:db8:1::||mask=64'/'net=2001:db8:1::/64||mask=/64'}
    E[NODEROUTENAMES]=storage6 E[ROUTE_storage6]='2001:db8:2::/64,/64,2001:db8:1::1,vtnet1'
    compile
    succeeds
    is "$(value K ifconfig_vtnet1_ipv6)" "inet6 $V6_10 prefixlen 64"
    is "$(value K ipv6_route_xcat_net_storage6)" \
        '-net 2001:0db8:0002:0000:0000:0000:0000:0000/64 2001:0db8:0001:0000:0000:0000:0000:0001'
}

@test "aggregate, VLAN and bridge dependencies compile in a deterministic order" {
    chain
    compile
    succeeds
    local first="$output"
    is "$(rows I | cut -f2 | paste -sd ' ')" 'vtnet1 vtnet2 lagg0 vlan100 bridge0'
    is "$(rows C)" $'C\tlagg0 vlan100 bridge0'
    is "$(value X lagg0)" 'laggproto lacp laggport vtnet1 laggport vtnet2 mtu 1500 up'
    is "$(value X vlan100)" 'vlan 100 vlandev lagg0 mtu 1500 up'
    is "$(value X bridge0)" 'addm vlan100 stp vlan100 mtu 1500 up'
    E[NICTYPES]=$(tr ',' '\n' <<<"${E[NICTYPES]}" | tac | paste -sd ,)
    E[NICDEVICES]=$(tr ',' '\n' <<<"${E[NICDEVICES]}" | tac | paste -sd ,)
    compile
    succeeds
    is "$output" "$first"
}

@test "selected native routes and the IPv6 default gateway carry the link-local scope" {
    base
    E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=fe80::1}
    E[NODEROUTENAMES]='data,storage6' E[ROUTE_data]='203.0.113.0,255.255.255.0,192.0.2.1,vtnet1'
    E[ROUTE_storage6]='2001:db8:2::,64,fe80::1,vtnet1'
    compile
    succeeds
    is "$(value K route_xcat_net_data)" '-net 203.0.113.0/24 192.0.2.1'
    is "$(value K ipv6_route_xcat_net_storage6)" "-net 2001:0db8:0002:0000:0000:0000:0000:0000/64 $LL1%vtnet1"
    is "$(value K ipv6_defaultrouter)" "$LL1%vtnet1"
    undefined K defaultrouter
}

@test "a static address and a clone MAC use separate native address families" {
    chain
    E[NICEXTRAPARAMS]+=',bridge0!MACADDR=52:54:00:12:34:56'
    E[NICIPS]='bridge0!192.0.2.10|192.0.2.11|2001:db8:1::10' E[NICNETWORKS]='bridge0!data4|data4|data6'
    compile
    succeeds
    is "$(value K ifconfig_bridge0)" 'ether 52:54:00:12:34:56 addm vlan100 stp vlan100 mtu 1500 up'
    is "$(value K ifconfig_bridge0_alias0)" 'inet 192.0.2.10/24'
    is "$(value K ifconfig_bridge0_alias1)" 'inet 192.0.2.11/24'
    [[ "$(value K ifconfig_bridge0_ipv6)" == 'inet6 '* ]]
}

@test "management migration requires the explicit option and the existing IPv4 identity" {
    chain
    E[NICTYPES]=${E[NICTYPES]//vtnet1/vtnet0} E[NICDEVICES]=${E[NICDEVICES]//vtnet1/vtnet0}
    compile
    fails 'confignetwork -s'
    compile 1
    fails
    E[IPADDR]=192.0.2.10
    compile 1
    succeeds
    is "$(rows A | head -n1)" $'A\tbridge0\tinet\t192.0.2.10\t24'
}

@test "invalid interfaces, options, networks, addresses and routes are rejected without a plan" {
    base; E[NICTYPES]+=',vtnet1!ethernet'; rejects 'Duplicate NICTYPES'
    base; E[NICTYPES]=''; rejects 'nictypes'
    base; E[NICTYPES]='vtnet1;id!ethernet'; rejects 'interface!value'
    base; E[NICEXTRAPARAMS]='vtnet1!ONBOOT=no'; rejects 'Unsupported FreeBSD option'
    base; E[NICEXTRAPARAMS]='vtnet1!MTU=1500;id'; rejects 'Invalid MTU'
    base; E[NICEXTRAPARAMS]='vtnet1!MTU=1500 MTU=9000'; rejects 'Duplicate option'
    base; E[NICCUSTOMSCRIPTS]='vtnet1!configure'; rejects 'separate postscript'
    base; E[NICNETWORKS]='vtnet1!missing'; rejects 'Missing, duplicate or disabled network'
    base; E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/disable=/disable=yes}; rejects 'disabled network'
    base; E[NETWORKS_LINES]=3 E[NETWORKS_LINE3]=${E[NETWORKS_LINE1]}; rejects 'duplicate or disabled network'
    base; E[NICIPS]=${E[NICIPS]/192.0.2/192.0.3}; rejects 'outside network'
    base; E[NICNETWORKS]+='|data4'; rejects 'same addresses'
    base; E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/255.255.255.0/255.0.255.0}; rejects 'Noncontiguous'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/mask=64/mask=129}; rejects 'Invalid IPv6 prefix'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/net=2001:db8:1::/net=2001:db8:1::\/63}; rejects 'Conflicting network prefix'
    local address
    for address in 192.0.2.0 192.0.2.255; do
        base; E[NICIPS]=${E[NICIPS]/192.0.2.10/$address}; rejects 'subnet or broadcast'
    done
    for address in 192.0.2.010 224.0.2.10; do
        base; E[NICIPS]=${E[NICIPS]/192.0.2.10/$address}; rejects 'Invalid unicast IPv4'
    done
    for address in ff02::10 ::ffff:c000:20a 2001:::10 2001::1::10; do
        base; E[NICIPS]=${E[NICIPS]/2001:db8:1::10/$address}; rejects 'Invalid unicast IPv6'
    done
    base; E[NICIPS]=${E[NICIPS]/2001:db8:1::10/fe80::10}; rejects 'Link-local node'
    base; E[NICIPS]='vtnet1!192.0.2.10|192.0.2.10' E[NICNETWORKS]='vtnet1!data4'; rejects 'Duplicate node address'
    base; E[NICEXTRAPARAMS]='vtnet1!MTU=1000'; rejects 'MTU of at least 1280'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=2001:db8:99::1}; rejects 'Gateway is outside'
    base; E[NODEROUTENAMES]=missing; rejects 'Missing or invalid selected route'
    base; E[NODEROUTENAMES]=data E[ROUTE_data]='203.0.113.0,255.255.255.0,192.0.2.1,'; rejects 'configured ifname'
    base; E[NODEROUTENAMES]=data E[ROUTE_data]='203.0.113.0,255.255.255.0,198.51.100.1,vtnet1'; rejects 'not reachable'
    base; E[NICTYPES]+=',vtnet2!ethernet' E[NODEROUTENAMES]=data E[ROUTE_data]='2001:db8:2::,64,fe80::1,vtnet2'
    rejects 'not reachable'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/2001:db8:1::/2001:db8:1::1}; rejects 'host bits'
    base; E[NODEROUTENAMES]=data E[ROUTE_data]='2001:db8:2::1,64,2001:db8:1::1,vtnet1'; rejects 'route network'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=2001:db8:1::10}; rejects 'own gateway'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=fe80::1%vtnet2}; rejects 'scope differs'
    base; E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=2001:db8:1::1%vtnet1}; rejects 'Only link-local'
    base; E[NICTYPES]+=',vtnet2!ethernet' E[NICIPS]+=',vtnet2!192.0.2.11' E[NICNETWORKS]+=',vtnet2!data4'
    rejects 'Overlapping subnets'
}

@test "invalid aggregate, VLAN and bridge topologies are rejected without a plan" {
    chain; E[NICDEVICES]=${E[NICDEVICES]/vtnet2/vtnet9}; rejects 'Missing, duplicate or self-referencing'
    chain; E[NICDEVICES]=${E[NICDEVICES]/vtnet2/vtnet1}; rejects 'Missing, duplicate or self-referencing'
    chain; E[NICEXTRAPARAMS]=''; rejects 'Set LAGGPROTO'
    chain; E[NICEXTRAPARAMS]='lagg0!LAGGPROTO=roundrobin'; rejects 'failover or lacp'
    chain; E[NICIPS]+=',vtnet1!192.0.2.11' E[NICNETWORKS]+=',vtnet1!data4'; rejects 'addresses on the aggregate'
    chain; E[NICTYPES]=${E[NICTYPES]/lagg0/bond0} E[NICDEVICES]=${E[NICDEVICES]//lagg0/bond0}
    E[NICEXTRAPARAMS]=${E[NICEXTRAPARAMS]/lagg0/bond0}; rejects 'native lagg interface'
    chain; E[NICEXTRAPARAMS]+=',vlan100!VLAN_TAG=4095'; rejects 'Invalid VLAN_TAG'
    chain; E[NICEXTRAPARAMS]+=' MTU=9000'; rejects 'Incompatible member MTU'
    chain; E[NICEXTRAPARAMS]+=',bridge0!MTU=1400'; rejects 'Incompatible member MTU'
    chain; E[NICTYPES]='vtnet0!ethernet,vlan100!vlan' E[NICDEVICES]='vlan100!vtnet0' E[NICIPS]='vlan100!192.0.2.10'
    E[NICNETWORKS]='vlan100!data4' E[NICEXTRAPARAMS]=''; rejects 'Use confignetwork -s'
}

@test "persistent route names protect unmanaged configuration" {
    base
    E[NODEROUTENAMES]='data,storage6' E[ROUTE_data]='203.0.113.0,255.255.255.0,192.0.2.1,vtnet1'
    E[ROUTE_storage6]='2001:db8:2::,64,2001:db8:1::1,vtnet1'
    compile
    succeeds
    local plan="$output" spec list prefix name route variable existing
    for spec in 'static_routes|route_|data|-net 198.51.100.0/24 127.0.0.1' \
        'ipv6_static_routes|ipv6_route_|storage6|-net 2001:db8:3::/64 ::1'; do
        IFS='|' read -r list prefix name route <<<"$spec"
        variable="${prefix}xcat_net_$name"
        for existing in "$variable: $route" "$list: xcat_net_$name other" "$list: other xcat_net_$name another" \
            "$list: other xcat_net_$name"; do
            inspect rcconflicts "$plan" "$existing"$'\n'
            fails 'route has configuration'
            [ -z "$output" ]
        done
    done
    inspect rcconflicts "$plan" ''
    succeeds
    inspect rcconflicts "$plan" 'static_routes: other xcat_net_data_other xcat_net_storage6
ipv6_static_routes: other xcat_net_storage6_other xcat_net_data
route_xcat_net_data_other: -net 198.51.100.0/24 127.0.0.1
ipv6_route_xcat_net_storage6_other: -net 2001:db8:3::/64 ::1
route_xcat_net_storage6: -net 198.51.100.0/24 127.0.0.1
ipv6_route_xcat_net_data: -net 2001:db8:3::/64 ::1
'
    succeeds
}

@test "persistent clone settings require explicit ownership" {
    chain
    compile
    succeeds
    local plan="$output" variable
    for variable in ifconfig_bridge0 ifconfig_bridge0_ipv6 ifconfig_bridge0_alias0 create_args_lagg0 vlans_vlan100; do
        inspect rcconflicts "$plan" "$variable: existing"$'\n'
        fails 'clone has configuration'
    done
    inspect rcconflicts "$plan" $'ifconfig_vtnet1: inet 192.0.2.10/24\nifconfig_bridge00: up\ncreate_args_lagg10: laggproto failover\n'
    succeeds
    inspect rcconflicts "$plan" $'cloned_interfaces: tap0 bridge0\n'
    fails 'clone has configuration'
}

@test "effective rc.conf lists retain additions outside the saved plan" {
    chain
    E[NODEROUTENAMES]='data,storage6' E[ROUTE_data]='203.0.113.0,255.255.255.0,192.0.2.1,bridge0'
    E[ROUTE_storage6]='2001:db8:2::,64,2001:db8:1::1,bridge0'
    compile
    succeeds
    local plan="$output"
    local lists=$'cloned_interfaces: tap0 lagg0 vlan100 bridge0 bridge7\nstatic_routes: xcat_net_data management4\nipv6_static_routes: management6 xcat_net_storage6'
    inspect rclists "$plan" "$lists"$'\n'
    succeeds
    is "$output" $'cloned_interfaces: tap0 bridge7\nstatic_routes: management4\nipv6_static_routes: management6'
    inspect rclists '' "$lists"$'\n'
    succeeds
    is "$output" "$lists"
    inspect rclists "$plan" $'static_routes: manual;command\n'
    fails 'Invalid names in static_routes'
    [ -z "$output" ]
}

@test "physical adoption protects existing interface options" {
    base
    compile
    succeeds
    local plan="$output" setting
    while IFS= read -r setting; do
        inspect rcoptions "$plan" "$setting"$'\n'
        fails 'Interface options require manual integration'
    done <<'SETTINGS'
ifconfig_vtnet1: up -lro -tso
ifconfig_vtnet1: media 10Gbase-T
ifconfig_vtnet1: -vlanhwtag
ifconfig_vtnet1: ether 52:54:00:12:34:56
ifconfig_vtnet1: fib 1
ifconfig_vtnet1_ipv6: inet6 2001:db8:1::10 prefixlen 64 -auto_linklocal
ifconfig_vtnet1_alias0: inet 192.0.2.11/24 vhid 1
ifconfig_vtnet1_aliases: inet 192.0.2.11/24 fib 1
ifconfig_vtnet1_name: storage
create_args_vtnet1: ether 52:54:00:12:34:56
vlans_vtnet1: 100
ipv6_prefix_vtnet1: 2001:db8:1::
ipv6_ifconfig_vtnet1: 2001:db8:1::10 prefixlen 64
ipv6_ifconfig_vtnet1_alias0: 2001:db8:1::11 prefixlen 64
SETTINGS
    inspect rcoptions "$plan" 'ifconfig_vtnet1: inet 192.0.2.10 netmask 255.255.255.0 broadcast 192.0.2.255 mtu 1500 up
ifconfig_vtnet1_ipv6: inet6 2001:db8:1::10 prefixlen 64
ifconfig_vtnet1_alias0: inet 192.0.2.11/24
ifconfig_vtnet1_aliases: inet6 2001:db8:1::11/64 alias
ifconfig_vtnet10: up -lro
ifconfig_vtnet0: up -tso
'
    succeeds
    inspect rcoptions "$plan" $'ifconfig_vtnet1_ipv6: DHCP NOAUTO SYNCDHCP nosyncdhcp WPA hostap\n'
    succeeds
}

@test "legacy IPv6 settings cannot configure a managed clone at boot" {
    chain
    compile
    succeeds
    local plan="$output" key
    for key in ipv6_ifconfig_bridge0 ipv6_ifconfig_bridge0_alias0; do
        inspect rcoptions "$plan" "$key: 2001:db8:1::11 prefixlen 64"$'\n'
        fails 'Interface options require manual integration'
    done
    inspect rcoptions "$plan" $'ipv6_ifconfig_bridge0: \nipv6_ifconfig_bridge0_alias0: \nipv6_ifconfig_bridge7: 2001:db8:7::1\n'
    succeeds
}

@test "native interface readback verifies the plan and saves the rollback snapshot" {
    base
    compile
    succeeds
    local plan="$output" ifc
    ifc="$(kernel)"$'\n'
    inspect verify "$plan" "$ifc"
    succeeds
    inspect snapshot "$plan" "$ifc"
    succeeds
    is "$(value E vtnet1)" 52:54:00:12:34:56
    is "$(value V vtnet1)" -ifdisabled
    is "$(rows A | cut -f3-5 | tr '\t' ' ' | LC_ALL=C sort)" "inet 192.0.2.10 24
inet6 $V6_10 64
inet6 fe80:0000:0000:0000:5054:00ff:fe12:3456 64"
    local nl=$'\n' changed diagnostic
    while IFS='|' read -r changed diagnostic; do
        eval "changed=$changed"
        inspect verify "$plan" "$changed"
        fails
        [[ "$stderr" == *"$diagnostic"* ]] || { echo "$changed: $stderr"; return 1; }
    done <<'CASES'
"${ifc/mtu 1500/mtu 1400}"|Interface MTU differs
"${ifc//prefixlen 64/prefixlen 63}"|A configured address or prefix is missing
"${ifc/192.0.2.10/192.0.2.11}"|A configured address or prefix is missing
"${ifc//vtnet1/vtnet2}"|Interface did not become ready
"${ifc/<UP,/< }"|Interface did not become ready
"${ifc/PERFORMNUD/PERFORMNUD,IFDISABLED}"|IPv6 interface state differs
"${ifc/prefixlen 64/prefixlen 64 tentative}"|Interface did not become ready
"${ifc/2001:db8:1::10 prefixlen 64/2001:db8:1::10 prefixlen 64 tentative}"|Interface did not become ready
"${ifc/prefixlen 64/prefixlen 64 duplicated}"|Interface did not become ready
"${ifc}        inet 192.0.2.11 netmask 0xffffff00${nl}"|An unexpected address is configured
CASES
}

@test "the conflict preflight protects SLAAC, the management address and unmanaged interfaces" {
    base
    compile
    succeeds
    local plan="$output" ifc unmanaged
    ifc="$(kernel)"$'\n'
    inspect conflicts "$plan" "$ifc"
    succeeds
    inspect conflicts "$plan" "${ifc/PERFORMNUD/PERFORMNUD,ACCEPT_RTADV}"
    fails 'Stop SLAAC configuration'
    IENV=IPADDR=192.0.2.10 inspect conflicts "$plan" "$ifc"
    fails 'interface carrying the management address'
    IENV=IPADDR=192.0.2.10 BOOT=1 inspect conflicts "$plan" "$ifc"
    succeeds
    for unmanaged in $'management_0: flags=8843<UP,BROADCAST> mtu 1500\n    inet 192.0.2.1 netmask 0xffffff00\n' \
        $'bridge7: flags=8843<UP,BROADCAST> mtu 1500\n    member: vtnet1 flags=143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>\n' \
        $'vlan7: flags=8843<UP,BROADCAST> mtu 1500\n    vlan: 7 vlanproto: 802.1q parent interface: vtnet1\n'; do
        inspect conflicts "$plan" "$ifc$unmanaged"
        fails
    done
}

@test "rollback clears addresses before duplicate detection completes" {
    base
    compile
    succeeds
    local plan="$output" ifc ready state changed observed disabled
    ifc="$(kernel)"$'\n'
    inspect snapshot "$plan" "$ifc"
    ready=$(rows A | tr '\t' ' ' | LC_ALL=C sort)
    for state in tentative duplicated; do
        changed=${ifc//prefixlen 64/prefixlen 64 $state}
        inspect verify "$plan" "$changed"
        fails
        inspect snapshot "$plan" "$changed"
        fails
        for disabled in 0 1; do
            observed=$changed
            [ "$disabled" = 0 ] || observed=${observed/PERFORMNUD/PERFORMNUD,IFDISABLED}
            inspect clear "$plan" "$observed"
            succeeds
            is "$(rows A | tr '\t' ' ' | LC_ALL=C sort)" "$ready"
        done
    done
    inspect clear "$plan" "${ifc/prefixlen 64/prefixlen -1}"
    fails
}

@test "disabled IPv6 ignores tentative link-local readiness" {
    base
    E[NICIPS]='vtnet1!192.0.2.10' E[NICNETWORKS]='vtnet1!data4'
    compile
    succeeds
    local plan="$output" observed
    observed="$(kernel | grep -v 'inet6 2001:')"$'\n'
    observed=${observed/prefixlen 64/prefixlen 64 tentative}
    observed=${observed/PERFORMNUD/PERFORMNUD,IFDISABLED}
    inspect verify "$plan" "$observed"
    succeeds
    inspect snapshot "$plan" "$observed"
    succeeds
    is "$(rows A | wc -l)" 1
}

@test "native route readback checks interface, gateway, prefix and default" {
    base
    E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=fe80::1}
    E[NODEROUTENAMES]=storage E[ROUTE_storage]='203.0.113.0,255.255.255.0,192.0.2.1,vtnet1'
    compile
    succeeds
    local plan="$output" routes changed ownership
    routes='Routing tables
Internet:
Destination        Gateway            Flags   Nhop#    Mtu            Netif Expire
203.0.113.0/24     192.0.2.1           UGS         2   1500           vtnet1
Internet6:
Destination                       Gateway                       Flags   Nhop#    Mtu            Netif Expire
default                           fe80::1%vtnet1                UGS         3   1500           vtnet1
'
    inspect routes "$plan" "$routes"
    succeeds
    ownership=$'I\tvtnet1\tethernet\n'
    inspect routeconflicts "$ownership" "$routes"
    fails
    ownership+=$'O\tinet\t203.0.113.0/24\t192.0.2.1\tvtnet1\n'
    inspect routeconflicts "$ownership" "$routes"
    succeeds
    for changed in "${routes//vtnet1/vtnet2}" "${routes/192.0.2.1/192.0.2.2}" "${routes/\/24/\/25}" \
        "$(grep -v '^default' <<<"$routes")"; do
        inspect routes "$plan" "$changed"
        fails
    done
}

@test "DHCP uses reserved addresses and native persistent configuration" {
    local option
    for option in BOOTPROTO=dhcp dhcp4=true; do
        base
        E[NICEXTRAPARAMS]="vtnet1!$option"
        compile
        succeeds
        is "$(value K ifconfig_vtnet1)" 'SYNCDHCP mtu 1500 up'
        is "$(rows H)" $'H\tvtnet1\t192.0.2.10\t24\tyes\tno'
        is "$(value K dhclient_flags_vtnet1)" '-c /var/db/xcat/network/dhcp/vtnet1.conf'
        is "$(value K ifconfig_vtnet1_ipv6)" "inet6 $V6_10 prefixlen 64"
    done
    base
    on_boot_nic
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=192.0.2.1} E[NICEXTRAPARAMS]='vtnet0!BOOTPROTO=dhcp PEERDNS=no'
    compile 1
    succeeds
    is "$(rows H)" $'H\tvtnet0\t192.0.2.10\t24\tno\tyes'
    is "$(value K defaultrouter)" NO
    is "$(rows D)" ''
}

@test "invalid DHCP options and ambiguous DHCP reservations are rejected" {
    local option
    for option in BOOTPROTO=auto dhcp4=yes 'BOOTPROTO=dhcp dhcp4=false' 'BOOTPROTO=static dhcp4=true' \
        PEERDNS=no DEFROUTE=yes 'BOOTPROTO=dhcp PEERDNS=maybe'; do
        base; E[NICEXTRAPARAMS]="vtnet1!$option"; rejects '(BOOTPROTO|dhcp4|DHCP|PEERDNS|DEFROUTE)'
    done
    base; E[NICEXTRAPARAMS]='vtnet1!BOOTPROTO=dhcp' E[NICIPS]='vtnet1!2001:db8:1::10' E[NICNETWORKS]='vtnet1!data6'
    rejects 'DHCP requires exactly one reserved'
    base; E[NICEXTRAPARAMS]='vtnet1!BOOTPROTO=dhcp' E[NICIPS]='vtnet1!192.0.2.10|192.0.2.11' E[NICNETWORKS]='vtnet1!data4'
    rejects 'DHCP requires exactly one reserved'
}

@test "an expired DHCP address permits recovery without accepting a wrong lease" {
    base
    E[NICIPS]='vtnet1!192.0.2.10' E[NICNETWORKS]='vtnet1!data4' E[NICEXTRAPARAMS]='vtnet1!BOOTPROTO=dhcp'
    compile
    succeeds
    local plan="$output" state
    state=$'vtnet1: flags=1008843<UP,BROADCAST,RUNNING> metric 0 mtu 1500\n        ether 52:54:00:12:34:56\n        nd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>\n'
    inspect verify-prior "$plan" "$state"
    succeeds
    inspect verify "$plan" "$state"
    fails
    inspect verify-prior "$plan" "$state"$'        inet 192.0.2.11 netmask 0xffffff00 broadcast 192.0.2.255\n'
    fails
}

@test "a DHCP bridge uses an explicit persistent MAC" {
    base
    E[NICTYPES]='vtnet1!ethernet,bridge0!bridge' E[NICDEVICES]='bridge0!vtnet1'
    E[NICIPS]=${E[NICIPS]//vtnet1/bridge0} E[NICNETWORKS]=${E[NICNETWORKS]//vtnet1/bridge0}
    E[NICEXTRAPARAMS]='bridge0!BOOTPROTO=dhcp'
    compile
    fails 'Set MACADDR for a bridge'
    E[NICEXTRAPARAMS]+=' MACADDR=52:54:00:12:34:56'
    compile
    succeeds
    is "$(value K ifconfig_bridge0)" 'SYNCDHCP ether 52:54:00:12:34:56 addm vtnet1 stp vtnet1 mtu 1500 up'
    is "$(value E bridge0)" 52:54:00:12:34:56
    undefined K ifconfig_bridge0_alias0
    local mac
    for mac in ff:ff:ff:ff:ff:ff 01:00:00:00:00:01 00:00:00:00:00:00 invalid; do
        E[NICEXTRAPARAMS]="bridge0!BOOTPROTO=dhcp MACADDR=$mac"
        compile
        fails
    done
}

@test "DHCPv6 uses the xCAT hardware UUID reservation identity" {
    bare -v mode=dhcp6-duid -v uuid=12345678-1234-ABCD-9876-1234567890AB
    succeeds
    is "$output" 00:04:12:34:56:78:12:34:ab:cd:98:76:12:34:56:78:90:ab
    local uuid
    for uuid in '' 00000000-0000-0000-0000-000000000000 ffffffff-ffff-ffff-ffff-ffffffffffff 1234 '$(command)'; do
        bare -v mode=dhcp6-duid -v uuid="$uuid"
        fails
        [ -z "$output" ]
    done
}

@test "DHCPv6 reservations use a separate persistent client" {
    local option
    for option in DHCPV6C=yes dhcp6=true; do
        base
        E[NICEXTRAPARAMS]="vtnet1!$option PEERDNS=no IPV6_DEFROUTE=yes"
        compile
        succeeds
        is "$(value K ifconfig_vtnet1)" 'inet 192.0.2.10/24 mtu 1500 up'
        is "$(value K ifconfig_vtnet1_ipv6)" 'inet6 -ifdisabled'
        is "$(value K xcat_dhcp6_enable)" YES
        is "$(value K ipv6_defaultrouter)" NO
        is "$(rows H6)" $'H6\tvtnet1\t'"$V6_10"$'\t128\tno\tyes'
        is "$(rows H)" ''
        E[NICEXTRAPARAMS]+=' BOOTPROTO=dhcp'
        compile
        succeeds
        is "$(rows H | wc -l)" 1
        is "$(rows H6 | wc -l)" 1
    done
}

@test "invalid DHCPv6 options and ambiguous DHCPv6 reservations are rejected" {
    local option
    for option in dhcp6=yes DHCPV6C=true 'DHCPV6C=yes dhcp6=false' 'DHCPV6C=no dhcp6=true' IPV6_DEFROUTE=yes \
        'dhcp6=true IPV6_DEFROUTE=auto'; do
        base; E[NICEXTRAPARAMS]="vtnet1!$option"; rejects '(dhcp6|DHCPV6C|DHCP|IPV6_DEFROUTE)'
    done
    base; E[NICEXTRAPARAMS]='vtnet1!dhcp6=true' E[NICIPS]='vtnet1!192.0.2.10' E[NICNETWORKS]='vtnet1!data4'
    rejects 'DHCPv6 requires exactly one'
    base; E[NICEXTRAPARAMS]='vtnet1!dhcp6=true' E[NICIPS]+='|2001:db8:1::11' E[NICNETWORKS]+='|data6'
    rejects 'DHCPv6 requires exactly one'
    base; E[NICEXTRAPARAMS]='vtnet1!dhcp6=true IPV6_DEFROUTE=yes' E[NETWORKS_LINE2]=${E[NETWORKS_LINE2]/gateway=/gateway=fe80::1}
    rejects 'one IPv6 default route owner'
}

lease6()
{
    E=([interface]=vtnet1 [new_dhcp6_ia_na1_ia_addr1]=2001:db8:1::10 [new_dhcp6_name_servers]='2001:db8:1::1 fe80::1'
        [new_dhcp6_domain_search]='example.test storage.example.test')
}

@test "DHCPv6 lease validation precedes resolver output" {
    local -a args=(-v mode=dhcp6-options -v expected=2001:db8:1::10 -v peerdns=yes)
    lease6
    planner "${args[@]}"
    succeeds
    is "$output" "search example.test storage.example.test
nameserver 2001:0db8:0001:0000:0000:0000:0000:0001
nameserver $LL1%vtnet1"
    local spec
    for spec in 'new_dhcp6_ia_na1_ia_addr1=2001:db8:1::11' 'new_dhcp6_ia_na1_ia_addr1=' \
        'new_dhcp6_ia_na1_ia_addr2=2001:db8:1::11' $'new_dhcp6_name_servers=2001:db8::1\noptions debug' \
        'new_dhcp6_domain_search=example.test;command' \
        "new_dhcp6_name_servers=$(printf '2001:db8::1 %.0s' {1..17})"; do
        lease6
        E[${spec%%=*}]=${spec#*=}
        planner "${args[@]}"
        fails
        [ -z "$output" ]
    done
    lease6
    planner "${args[@]}" -v peerdns=no
    succeeds
    [ -z "$output" ]
}

@test "DHCPv6 completion requires its router advertisement default" {
    base
    E[NICEXTRAPARAMS]='vtnet1!dhcp6=true IPV6_DEFROUTE=yes'
    compile
    succeeds
    local plan="$output" route=$'default fe80::1%vtnet1 UG vtnet1\n'
    inspect routes "$plan" "$ROUTES6$route"
    succeeds
    inspect routes "$plan" "$ROUTES6"
    fails
    inspect routes "$plan" "$ROUTES6${route//vtnet1/vtnet2}"
    fails
}

@test "expired DHCPv6 permits recovery while rejecting foreign addresses" {
    base
    E[NICEXTRAPARAMS]='vtnet1!dhcp6=true'
    compile
    succeeds
    local plan="$output" state leased
    state=$'vtnet1: flags=1008843<UP,BROADCAST,RUNNING> metric 0 mtu 1500\n        ether 52:54:00:12:34:56\n        inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255\n        inet6 fe80::5054:ff:fe12:3456%vtnet1 prefixlen 64 scopeid 0x2\n        nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>\n'
    inspect verify-prior "$plan" "$state"
    succeeds
    inspect verify "$plan" "$state"
    fails
    leased="$state"$'        inet6 2001:db8:1::10 prefixlen 128\n'
    inspect verify "$plan" "$leased"
    succeeds
    inspect verify-prior "$plan" "${leased/::10/::11}"
    fails
}

# lease <routers> <classless>: write a saved DHCPv4 lease for 192.0.2.10.
lease() { printf 'old_ip_address\t192.0.2.10\nold_routers\t%s\nold_classless_routes\t%s\n' "$1" "$2" >"$WORK/lease"; }

# lease_default <routers> <classless> <expected record>
lease_default()
{
    lease "$1" "$2"
    bare -v mode=dhcp4-default -v nic=vtnet1 "$WORK/lease"
    succeeds
    is "$output" "$3"
    [ -n "$3" ] || return 0
    local plan="$output" gateway=192.0.2.1
    [[ "$plan" != Q* ]] || gateway='link#2'
    inspect routes "$plan" "${ROUTES4}default $gateway UGS vtnet1"$'\n'
    succeeds
    inspect routes "$plan" "$ROUTES4"
    fails
    inspect routes "$plan" "${ROUTES4}default $gateway UGS vtnet2"$'\n'
    fails
    [[ "$plan" == R* ]] || return 0
    inspect routes "$plan" "${ROUTES4}default 192.0.2.254 UGS vtnet1"$'\n'
    fails
}

@test "DHCPv4 default routes follow native lease precedence" {
    local default=$'R\tinet\tdefault\t192.0.2.1\tvtnet1' onlink=$'Q\tinet\tvtnet1' bad
    lease_default '192.0.2.1 192.0.2.254' '' "$default"
    lease_default '' '' ''
    lease_default 192.0.2.254 '0 192 0 2 1' "$default"
    lease_default 192.0.2.254 '24 203 0 113 192 0 2 1' ''
    lease_default '' '9 10 128 192 0 2 254 0 192 0 2 1' "$default"
    lease_default '' '0 0 0 0 0' "$onlink"
    lease_default 192.0.2.10 '' "$onlink"
    for bad in '0 192 0 2' '33 10 0 0 0 192 0 2 1' '0 256 0 2 1'; do
        printf 'old_classless_routes\t%s\n' "$bad" >"$WORK/lease"
        bare -v mode=dhcp4-default -v nic=vtnet1 "$WORK/lease"
        fails
        [ -z "$output" ]
    done
}

@test "the gateway token can return from DHCP to static IPv4" {
    printf 'old_ip_address\t192.0.2.10\nold_routers\t192.0.2.1\n' >"$WORK/lease"
    bare -v mode=dhcp4-default -v nic=vtnet0 "$WORK/lease"
    succeeds
    local route="$output" gateway
    inspect routes "$route" "${ROUTES4}default 192.0.2.1 UGS vtnet0"$'\n'
    succeeds
    gateway=$(awk -F '\t' '$1 == "R" && $2 == "inet" && $3 == "default" && $5 == "vtnet0" { print $4 }' <<<"$route")
    local -a args=(-v bootnic=vtnet0 -v configure_boot=1 -v owned_dhcp_default=vtnet0)
    base
    on_boot_nic
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=<xcatmaster>}
    planner "${args[@]}" -v leased_ipv4_gateway="$gateway"
    succeeds
    is "$(value K defaultrouter)" 192.0.2.1
    is "$(rows D)" $'D\tinet\t192.0.2.1'
    planner "${args[@]}"
    fails 'set an explicit gateway'
    [ -z "$output" ]
    planner "${args[@]}" -v unmanaged_ipv4_gateway=192.0.2.1
    succeeds
    is "$(rows D)" ''
    E[NICEXTRAPARAMS]='vtnet0!BOOTPROTO=dhcp'
    planner "${args[@]}"
    succeeds
    is "$(value K defaultrouter)" NO
    E[NICEXTRAPARAMS]='' E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/<xcatmaster>/192.0.2.1}
    planner "${args[@]}"
    succeeds
    is "$(value K defaultrouter)" 192.0.2.1
}

@test "the gateway token preserves a verified absence of a DHCP router" {
    local -a saved=(-v mode=dhcp4-default -v nic=vtnet0 -v require_saved_lease=yes "$WORK/lease")
    printf 'old_ip_address\t192.0.2.10\nold_routers\t\n' >"$WORK/lease"
    bare "${saved[@]}"
    succeeds
    [ -z "$output" ]
    local flags incomplete
    inspect routes '' "$ROUTES4" -v expect_no_ipv4_default=yes
    succeeds
    for flags in UGS U; do
        inspect routes '' "${ROUTES4}default 192.0.2.1 $flags vtnet0"$'\n' -v expect_no_ipv4_default=yes
        fails
    done
    inspect routes '' "$ROUTES4${ROUTES6}default fe80::1%vtnet0 UG vtnet0"$'\n' -v expect_no_ipv4_default=yes
    succeeds
    local -a args=(-v bootnic=vtnet0 -v configure_boot=1 -v owned_dhcp_default=vtnet0)
    base
    on_boot_nic
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=/gateway=<xcatmaster>}
    planner "${args[@]}" -v leased_ipv4_default_absent=yes
    succeeds
    is "$(rows D)" ''
    undefined K defaultrouter
    planner "${args[@]}"
    fails
    [ -z "$output" ]
    for incomplete in '' $'old_ip_address\t192.0.2.10\n' $'old_routers\t\n' $'old_ip_address\tinvalid\nold_routers\t\n'; do
        printf '%s' "$incomplete" >"$WORK/lease"
        bare "${saved[@]}"
        fails 'Incomplete saved DHCP lease'
        [ -z "$output" ]
    done
}

@test "an explicit DHCP data default replaces a retained token default" {
    E=([NICTYPES]='vtnet0!ethernet,vtnet1!ethernet' [NICIPS]='vtnet0!192.0.2.10,vtnet1!198.51.100.10'
        [NICNETWORKS]='vtnet0!provision,vtnet1!data' [NICEXTRAPARAMS]='vtnet1!BOOTPROTO=dhcp DEFROUTE=yes'
        [IPADDR]=192.0.2.10 [NETWORKS_LINES]=2
        [NETWORKS_LINE1]='netname=provision||net=192.0.2.0||mask=255.255.255.0||gateway=<xcatmaster>||mtu=||disable='
        [NETWORKS_LINE2]='netname=data||net=198.51.100.0||mask=255.255.255.0||gateway=||mtu=||disable=')
    local -a args=(-v bootnic=vtnet0 -v configure_boot=1 -v owned_ipv4_gateway=192.0.2.1)
    planner "${args[@]}"
    succeeds
    is "$(rows D)" ''
    is "$(rows H)" $'H\tvtnet1\t198.51.100.10\t24\tyes\tyes'
    is "$(value K defaultrouter)" NO
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/<xcatmaster>/192.0.2.1}
    planner "${args[@]}"
    fails
    [ -z "$output" ]
    E[NETWORKS_LINE1]=${E[NETWORKS_LINE1]/gateway=192.0.2.1/gateway=<xcatmaster>}
    E[NICEXTRAPARAMS]='vtnet1!BOOTPROTO=dhcp DEFROUTE=no'
    planner "${args[@]}"
    succeeds
    is "$(value K defaultrouter)" 192.0.2.1
    E[NICEXTRAPARAMS]='vtnet0!BOOTPROTO=dhcp DEFROUTE=yes,vtnet1!BOOTPROTO=dhcp DEFROUTE=yes'
    planner "${args[@]}"
    fails
    [ -z "$output" ]
}

early()
{
    E=([NICTYPES]='vtnet0!ethernet,vtnet1!ethernet,lagg0!bond,vlan100!vlan,bridge0!bridge,vtnet2!ethernet'
        [NICDEVICES]='lagg0!vtnet0|vtnet1,vlan100!lagg0,bridge0!vlan100'
        [NICEXTRAPARAMS]='lagg0!LAGGPROTO=lacp,bridge0!STP=no'
        [NICMACS]='vtnet0!52:54:00:00:00:01,vtnet1!52:54:00:00:00:02')
}

@test "the early bootstrap graph uses the installed-node topology rules" {
    local -a options=(-v mode=bootstrap -v bootstrapnic=bridge0 -v bootmac=52:54:00:00:00:01)
    early
    planner "${options[@]}"
    succeeds
    is "$(rows I | cut -f2 | paste -sd ' ')" 'vtnet0 vtnet1 lagg0 vlan100 bridge0'
    is "$(rows M)" $'M\tvtnet0\t52:54:00:00:00:01\nM\tvtnet1\t52:54:00:00:00:02'
    [[ "$(value X lagg0)" == *'laggproto lacp laggport vtnet0 laggport vtnet1'* ]]
    [[ "$(value X bridge0)" == 'ether 52:54:00:00:00:01 addm vlan100'* ]]
    is "$(rows A)" ''
    local change
    for change in 'NICMACS=vtnet0!52:54:00:00:00:01' 'NICMACS=vtnet0!52:54:00:00:00:01,vtnet1!52:54:00:00:00:01' \
        'NICMACS=vtnet0!52:54:00:00:00:01,vtnet1!ff:ff:ff:ff:ff:ff' \
        'NICDEVICES=lagg0!vtnet1|vtnet0,vlan100!lagg0,bridge0!vlan100' \
        'NICDEVICES=lagg0!vtnet0|bridge0,vlan100!lagg0,bridge0!vlan100' \
        'NICEXTRAPARAMS=lagg0!LAGGPROTO=balance-xor' 'NICEXTRAPARAMS=lagg0!LAGGPROTO=lacp,bridge0!MACADDR=52:54:00:00:00:99'; do
        early
        E[${change%%=*}]=${change#*=}
        planner "${options[@]}"
        fails
        [ -z "$output" ]
    done
}

infiniband()
{
    base
    local key
    for key in NICTYPES NICIPS NICNETWORKS; do E[$key]=${E[$key]//vtnet1/ib0}; done
    E[NICTYPES]='ib0!Infiniband' E[NICEXTRAPARAMS]='ib0!PORT_GUID=02:00:00:00:00:00:00:01'
}

ib_kernel()
{
    cat <<'IB'
ib0: flags=1008043<UP,BROADCAST,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 2044
        lladdr 0.0.0.46.fe.80.0.0.0.0.0.0.2.0.0.0.0.0.0.1
        inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
        inet6 2001:db8:1::10 prefixlen 64
        nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
IB
}

@test "InfiniBand ports compile to a physical interface with native persistent configuration" {
    infiniband
    compile
    succeeds
    is "$(value I ib0)" infiniband
    is "$(value T ib0)" 2044
    is "$(rows C)" $'C\t'
    is "$(rows L)" $'L\tmlx5ib\nL\tipoib'
    is "$(value K ifconfig_ib0)" 'inet 192.0.2.10/24 mtu 2044 up'
    is "$(value K ifconfig_ib0_ipv6)" "inet6 $V6_10 prefixlen 64"
}

@test "InfiniBand readback checks the port GUID and the fabric link" {
    infiniband
    compile
    succeeds
    local plan="$output" ifc nl=$'\n' inactive unconfigured
    ifc="$(ib_kernel)$nl"
    inspect verify "$plan" "$ifc"
    succeeds
    inspect snapshot "$plan" "$ifc"
    succeeds
    is "$(value G ib0)" 02:00:00:00:00:00:00:01
    is "$(rows E)" ''
    is "$(rows A | wc -l)" 2
    inspect links "$plan" "${ifc/0.0.0.46/0.0.0.77}"
    succeeds
    inspect links "$plan" "${ifc/"0.1$nl"/"0.2$nl"}"
    fails 'port GUID differs'
    inspect verify-prior "$plan" "${ifc/"0.1$nl"/"0.2$nl"}"
    succeeds
    inactive=${ifc/,LOWER_UP/}
    inspect verify "$plan" "$inactive"
    fails 'InfiniBand link is not active'
    inspect verify-prior "$plan" "$inactive"
    succeeds
    inspect carrier "$plan" "$inactive"
    fails
    inspect carrier "$plan" "$ifc"
    succeeds
    unconfigured=${inactive/flags=1008043<UP,BROADCAST,RUNNING,MULTICAST>/flags=8002<BROADCAST,MULTICAST>}
    [ "$unconfigured" != "$inactive" ]
    inspect carrier "$plan" "$unconfigured"
    succeeds
    inspect verify "$plan" "$inactive" -v check_carrier=no
    succeeds
    inspect verify "$plan" "$(grep -v 'inet 192.0.2.10' <<<"$inactive")$nl" -v check_carrier=no
    fails
    inspect rcoptions "$plan" $'ifconfig_ib0: inet 192.0.2.10/24 mtu 2044 up\n'
    succeeds
}

@test "an InfiniBand port cannot replace the Ethernet provisioning interface" {
    infiniband
    E[NICTYPES]='vtnet0!ethernet,ib0!infiniband' E[NICMACS]='vtnet0!52:54:00:00:00:01'
    planner -v mode=bootstrap -v bootstrapnic=vtnet0 -v bootmac=52:54:00:00:00:01
    succeeds
    is "$(rows I)" $'I\tvtnet0\tethernet'
    planner -v mode=bootstrap -v bootstrapnic=ib0 -v bootmac=52:54:00:00:00:01
    fails 'bootstrap interface must contain the boot NIC'
    [ -z "$output" ]
}

@test "InfiniBand options outside the native constraints are rejected" {
    infiniband; E[NICEXTRAPARAMS]='ib0!CONNECTED_MODE=yes'; rejects 'GENERIC IPoIB module supports datagram'
    infiniband; E[NICEXTRAPARAMS]='ib0!MTU=4093'; rejects 'MTU cannot exceed 4092'
    infiniband; E[NICEXTRAPARAMS]='ib0!MACADDR=02:00:00:00:00:01'; rejects 'cannot be set with MACADDR'
    infiniband; E[NICEXTRAPARAMS]='ib0!IB_DRIVER=arbitrary'; rejects 'IB_DRIVER must be'
    infiniband; E[NICEXTRAPARAMS]='ib0!PORT_GUID=not-a-guid'; rejects 'Invalid InfiniBand port GUID'
    infiniband; E[NICEXTRAPARAMS]='ib0!BOOTPROTO=auto'; rejects 'BOOTPROTO must be'
}

ib_lagg()
{
    base
    E[NICTYPES]='ib0!infiniband,ib1!infiniband,lagg0!bond-infiniband' E[NICDEVICES]='lagg0!ib0|ib1'
    E[NICEXTRAPARAMS]='lagg0!LAGGPROTO=failover'
    E[NICIPS]=${E[NICIPS]//vtnet1/lagg0} E[NICNETWORKS]=${E[NICNETWORKS]//vtnet1/lagg0}
}

ib_partition()
{
    ib_lagg
    E[NICTYPES]='ib0!infiniband,vlan10!vlan' E[NICDEVICES]='vlan10!ib0' E[NICEXTRAPARAMS]='vlan10!PKEY=0x800a'
    E[NICIPS]=${E[NICIPS]//lagg0/vlan10} E[NICNETWORKS]=${E[NICNETWORKS]//lagg0/vlan10}
}

@test "InfiniBand failover and partitions use the native LAGG type and partition tag" {
    ib_lagg
    compile
    succeeds
    is "$(rows I | cut -f2 | paste -sd ' ')" 'ib0 ib1 lagg0'
    is "$(value J lagg0)" 'laggtype infiniband'
    is "$(value K create_args_lagg0)" 'laggtype infiniband'
    is "$(rows C)" $'C\tlagg0'
    E[NICTYPES]='ib0!infiniband,ib1!infiniband,ib2!infiniband,ib3!infiniband,lagg0!bond-infiniband'
    E[NICDEVICES]='lagg0!ib2|ib3'
    compile
    succeeds
    inspect carrier "$output" $'lagg0: flags=8043<UP,BROADCAST,RUNNING,MULTICAST> metric 0 mtu 2044\n'
    succeeds
    ib_partition
    compile
    succeeds
    is "$(value X vlan10)" 'vlan 10 vlandev ib0 mtu 2044 up'
    is "$(rows C)" $'C\tvlan10'
    inspect carrier "$output" $'vlan10: flags=8003<UP,BROADCAST,MULTICAST> metric 0 mtu 2044\n'
    succeeds
}

@test "invalid InfiniBand topologies are rejected without a plan" {
    local spec pattern assignment
    while IFS='|' read -r pattern spec; do
        ib_partition
        while IFS= read -r -d ';' assignment; do
            E[${assignment%%=*}]=${assignment#*=}
        done <<<"$spec;"
        rejects "$pattern"
    done <<'CASES'
failover only|NICTYPES=ib0!infiniband,ib1!infiniband,lagg0!lagg;NICDEVICES=lagg0!ib0|ib1;NICIPS=;NICNETWORKS=;NICEXTRAPARAMS=lagg0!LAGGPROTO=lacp
Ethernet and InfiniBand|NICTYPES=vtnet1!ethernet,ib0!infiniband,lagg0!lagg;NICDEVICES=lagg0!vtnet1|ib0;NICIPS=;NICNETWORKS=;NICEXTRAPARAMS=lagg0!LAGGPROTO=failover
partitions require a physical ibN parent|NICTYPES=ib0!infiniband,ib1!infiniband,lagg0!lagg,vlan10!vlan;NICDEVICES=lagg0!ib0|ib1,vlan10!lagg0;NICEXTRAPARAMS=lagg0!LAGGPROTO=failover,vlan10!PKEY=0x800a
VLAN parent is an aggregate member|NICTYPES=ib0!infiniband,ib1!infiniband,lagg0!lagg,vlan10!vlan;NICDEVICES=lagg0!ib0|ib1,vlan10!ib0;NICEXTRAPARAMS=lagg0!LAGGPROTO=failover,vlan10!PKEY=0x800a
full-member PKEY|NICEXTRAPARAMS=vlan10!PKEY=0x000a
full-member PKEY|NICEXTRAPARAMS=vlan10!PKEY=0x900a
PKEY and VLAN_TAG differ|NICEXTRAPARAMS=vlan10!PKEY=0x800a VLAN_TAG=11
bridges require Ethernet|NICTYPES=ib0!infiniband,bridge0!bridge;NICDEVICES=bridge0!ib0;NICIPS=;NICNETWORKS=;NICEXTRAPARAMS=
CASES
}

@test "IPoIB DHCPv4 uses a separate client and the common lease contract" {
    local spec nic types members options
    for spec in 'ib0;ib0!infiniband;;' 'lagg0;ib0!infiniband,ib1!infiniband,lagg0!bond-infiniband;lagg0!ib0|ib1;LAGGPROTO=failover ' \
        'vlan10;ib0!infiniband,vlan10!vlan;vlan10!ib0;PKEY=0x800a '; do
        IFS=';' read -r nic types members options <<<"$spec"
        base
        E[NICTYPES]=$types E[NICDEVICES]=$members E[NICIPS]="$nic!192.0.2.10" E[NICNETWORKS]="$nic!data4"
        E[NICEXTRAPARAMS]="$nic!${options}BOOTPROTO=dhcp PEERDNS=no DEFROUTE=yes"
        compile
        succeeds
        is "$(rows H)" "H	$nic	192.0.2.10	24	no	yes"
        is "$(value K xcat_ipoib_dhcp4_enable)" YES
        [[ ! "$(value K "ifconfig_$nic" || true)" =~ SYNCDHCP|inet\  ]]
        is "$(rows K | cut -f2 | grep -cx "dhclient_flags_$nic" || true)" 0
        E[NICIPS]+='|192.0.2.11'
        compile
        fails
    done
}

@test "dhcpcd routes translate to the native DHCP event format" {
    local side
    routes_case()
    {
        E=(["${side}_classless_static_routes"]="$1" ["${side}_ms_classless_static_routes"]="$2")
        local -a exports=(PATH="$PATH" LC_ALL=C)
        local key rc=0
        for key in "${!E[@]}"; do exports+=("$key=${E[$key]}"); done
        env -i "${exports[@]}" awk -f "$PLANNER" -v mode=dhcp4-routes -v lease_side="$side" </dev/null \
            >"$WORK/out" 2>/dev/null || rc=1
        [ "$rc" = "$3" ] || { echo "$side '$1' '$2': status $rc"; return 1; }
        printf "$4" | cmp -s - "$WORK/out" || { echo "$side '$1' '$2': $(od -c "$WORK/out")"; return 1; }
    }
    for side in old new; do
        routes_case '' '' 0 '\n'
        routes_case '0.0.0.0/0 192.0.2.1' '' 0 '0 192 0 2 1\n'
        routes_case '198.51.100.0/24 192.0.2.2 0.0.0.0/0 192.0.2.1' '' 0 '24 198 51 100 192 0 2 2 0 192 0 2 1\n'
        routes_case '' '203.0.113.7/32 0.0.0.0' 0 '32 203 0 113 7 0 0 0 0\n'
        routes_case '0.0.0.0/0 192.0.2.1' '0.0.0.0/0 192.0.2.2' 0 '0 192 0 2 1\n'
        routes_case '198.51.100.1/24 192.0.2.1' '' 1 ''
        routes_case '198.51.100.0/33 192.0.2.1' '' 1 ''
        routes_case '0.0.0.0/0' '' 1 ''
        routes_case '0.0.0.0/0 256.0.0.1' '' 1 ''
        routes_case $'0.0.0.0/0 192.0.2.1\n' '' 1 ''
    done
}
