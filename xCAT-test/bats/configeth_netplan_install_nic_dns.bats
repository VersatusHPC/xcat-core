#!/usr/bin/env bats
#
# configeth -s replaces the DHCP configuration of the install NIC with a static netplan
# drop-in. That drop-in sets dhcp4: false, so systemd-resolved also loses the name servers
# that DHCP gave the NIC. Without a nameservers: list the node resolves no names, and on
# Ubuntu 24.04 every later "curl https://<mn>" from the compute node fails.

load 'helpers/shell_source'

setup()
{
    local configeth xcatlib fn
    configeth="$(require_repo_file 'xCAT/postscripts/configeth')"
    xcatlib="$(require_repo_file 'xCAT/postscripts/xcatlib.sh')"
    LIB="${BATS_TEST_TMPDIR}/netplan.sh"
    extract_shell_function "$xcatlib" v4mask2prefix >"$LIB"
    for fn in netplan_file _netplan_touch _netplan_state _netplan_record _netplan_forget \
        _netplan_param_key _netplan_yaml_scalar _netplan_route_dest _netplan_render \
        netplan_reset_nic write_netplan_addr write_netplan_route write_netplan_dns \
        write_netplan_install_nic; do
        extract_shell_function "$configeth" "$fn" >>"$LIB" || {
            echo "configeth has no $fn" >&2
            return 1
        }
    done
    export NETPLAN_DIR="${BATS_TEST_TMPDIR}/netplan"
    mkdir -p "$NETPLAN_DIR"
}

# install_nic <dns> <search> -- print the drop-in written for ens3
install_nic()
{
    bash -c '
        str_default_token=default
        . "$1"
        write_netplan_install_nic ens3 192.168.224.22 255.255.255.0 192.168.224.1 "" "$2" "$3"
        cat "$NETPLAN_DIR/90-xcat-ens3.yaml"
    ' bash "$LIB" "$1" "$2"
}

@test "the static install NIC keeps its name servers and search domain" {
    run install_nic '192.168.224.1' 'xcat24.lab'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx '      dhcp4: false'
    printf '%s\n' "$output" | grep -qx '        - 192.168.224.22/24'
    printf '%s\n' "$output" | grep -qx '      nameservers:'
    printf '%s\n' "$output" | grep -qx '          - 192.168.224.1'
    printf '%s\n' "$output" | grep -qx '          - xcat24.lab'
}

@test "a comma-separated server list gives one entry per server" {
    run install_nic '192.0.2.1,192.0.2.2' ''
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx '          - 192.0.2.1'
    printf '%s\n' "$output" | grep -qx '          - 192.0.2.2'
    [[ "$output" != *'search:'* ]]
}

@test "no name server and no domain writes no nameservers key" {
    run install_nic '' ''
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx '      dhcp4: false'
    [[ "$output" != *'nameservers:'* ]]
}
