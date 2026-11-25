#!/usr/bin/env bats
#
# netplan warns "Permissions for /etc/netplan/90-xcat.yaml are too open" when the file is
# readable by others. xcatroot writes that file for every Ubuntu stateless node.

load 'helpers/shell_source'

setup()
{
    XCATROOT_SCRIPT="$(require_repo_file \
      'xCAT-server/share/xcat/netboot/ubuntu/dracut/xcatroot')"
    SNIPPET="${BATS_TEST_TMPDIR}/netplan.sh"
    extract_shell_function "$XCATROOT_SCRIPT" xcat_write_netplan >"$SNIPPET"
    YAML="${BATS_TEST_TMPDIR}/90-xcat.yaml"
}

# write_netplan <fields...> -- write the netplan for eth0 with a umask that leaves a new
# file readable by others, as the initial ramdisk does.
write_netplan()
{
    (
        umask 022
        # shellcheck disable=SC1090
        . "$SNIPPET"
        xcat_write_netplan "$YAML" eth0 42:00:c0:a8:00:0a "$@"
    )
}

@test "the DHCPv4 netplan is readable by its owner only" {
    run write_netplan
    [ "$status" -eq 0 ]
    grep -qx '      dhcp4: true' "$YAML"
    [ "$(stat -c %a "$YAML")" = 600 ]
}

@test "the static IPv6 netplan is readable by its owner only" {
    run write_netplan 2001:db8:147::10 64 2001:db8:147::1
    [ "$status" -eq 0 ]
    grep -qx '      addresses: \[2001:db8:147::10/64\]' "$YAML"
    grep -qx '          via: 2001:db8:147::1' "$YAML"
    [ "$(stat -c %a "$YAML")" = 600 ]
}
