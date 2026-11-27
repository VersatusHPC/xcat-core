#!/usr/bin/env bats
#
# Drive xcat_write_bootif_ifcfg() out of the openSUSE stateless and statelite dracut hooks.
# The hooks cannot be sourced: they mount the root image and switch to it.

load 'helpers/shell_source'

setup()
{
    STATELESS="$(require_repo_file 'xCAT-server/share/xcat/netboot/sles/dracut_033/xcatroot')"
    STATELITE="$(require_repo_file 'xCAT-server/share/xcat/netboot/sles/dracut_033/xcat-prepivot.sh')"
    NEWROOT_DIR="$BATS_TEST_TMPDIR/root"
    RUN_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$NEWROOT_DIR/etc/sysconfig/network" "$RUN_DIR"
    export STATELESS STATELITE NEWROOT_DIR RUN_DIR
}

write_ifcfg()
{
    local hook="$1" body
    body="$(extract_shell_function "$hook" xcat_write_bootif_ifcfg)" ||
        { echo "xcat_write_bootif_ifcfg() not found in $hook" >&2; return 99; }
    ( eval "$body"; xcat_write_bootif_ifcfg "$NEWROOT_DIR" "$RUN_DIR" ) 2>&1
}

ifcfg_files()
{
    ls -A "$NEWROOT_DIR/etc/sysconfig/network"
}

# Leap 16 boots with the dracut NetworkManager module, which leaves no net.<nic>.up file.
@test "with no net.<nic>.up file the hooks write nothing and print no error" {
    for hook in "$STATELESS" "$STATELITE"; do
        rm -rf "$NEWROOT_DIR/etc/sysconfig/network"/*
        run write_ifcfg "$hook"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [ -z "$(ifcfg_files)" ]
    done
}

@test "the hooks write ifcfg-<nic> for the NIC that network-legacy brought up" {
    touch "$RUN_DIR/net.eth0.up" "$RUN_DIR/net.eth0:1.up"
    for hook in "$STATELESS" "$STATELITE"; do
        rm -rf "$NEWROOT_DIR/etc/sysconfig/network"/*
        run write_ifcfg "$hook"
        [ "$status" -eq 0 ]
        [ "$(ifcfg_files)" = ifcfg-eth0 ]
        grep -qx "BOOTPROTO='dhcp'" "$NEWROOT_DIR/etc/sysconfig/network/ifcfg-eth0"
        grep -qx "STARTMODE='auto'" "$NEWROOT_DIR/etc/sysconfig/network/ifcfg-eth0"
    done
}
