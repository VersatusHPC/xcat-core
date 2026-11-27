#!/usr/bin/env bats
#
# genimage ships /etc/netplan/90-xcat-dhcp.yaml, which runs DHCPv4 on every NIC whose name
# starts with "e". A booted stateless node then asks for an address on the NICs xCAT marks
# *NOIP*, forever. xcatroot names the boot NIC in 90-xcat.yaml, so the catch-all must go.

load 'helpers/shell_source'

setup()
{
    XCATROOT_SCRIPT="$(require_repo_file \
      'xCAT-server/share/xcat/netboot/ubuntu/dracut/xcatroot')"
    SNIPPET="${BATS_TEST_TMPDIR}/netplan.sh"
    extract_shell_function "$XCATROOT_SCRIPT" xcat_write_netplan >"$SNIPPET"
    NETPLAN="${BATS_TEST_TMPDIR}/etc/netplan"
    mkdir -p "$NETPLAN"
    printf 'network:\n  ethernets:\n    xcat-cluster:\n      match:\n        name: "e*"\n      dhcp4: true\n' \
      >"$NETPLAN/90-xcat-dhcp.yaml"
    printf 'network:\n  version: 2\n' >"$NETPLAN/50-other.yaml"
}

write_netplan()
{
    (
        # shellcheck disable=SC1090
        . "$SNIPPET"
        xcat_write_netplan "$NETPLAN/90-xcat.yaml" ens3 42:00:c0:a8:00:0a "$@"
    )
}

@test "the netplan of the boot NIC replaces the DHCP netplan for every NIC" {
    run write_netplan
    [ "$status" -eq 0 ]
    grep -qx '        macaddress: "42:00:c0:a8:00:0a"' "$NETPLAN/90-xcat.yaml"
    [ ! -e "$NETPLAN/90-xcat-dhcp.yaml" ]
}

@test "the static IPv6 netplan also replaces the DHCP netplan for every NIC" {
    run write_netplan 2001:db8:147::10 64 2001:db8:147::1
    [ "$status" -eq 0 ]
    [ ! -e "$NETPLAN/90-xcat-dhcp.yaml" ]
}

@test "a netplan that xCAT did not write stays" {
    run write_netplan
    [ "$status" -eq 0 ]
    [ -e "$NETPLAN/50-other.yaml" ]
}
