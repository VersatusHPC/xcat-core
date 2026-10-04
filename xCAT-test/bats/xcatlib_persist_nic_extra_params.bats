#!/usr/bin/env bats
#
# xcat_persist_nic_extra_params writes the nicextraparams NetworkManager has no setting for
# into the profile NetworkManager keeps on disk. Where that profile lives depends on the
# release: EL9 and later use a keyfile, EL8 uses an ifcfg file.
#
# confignetwork_secondarynic_nicextraparams_updatenode asserts CONNECTED_MODE=yes is in the
# NIC configuration after updatenode. On EL8 it is in neither file.
#
# nmcli is stubbed and both directories point into the test's own tree, so nothing on the host
# is read or written.

load 'helpers/shell_source'

setup()
{
    LIB="$(require_repo_file 'xCAT/postscripts/xcatlib.sh')"
    BIN="${BATS_TEST_TMPDIR}/bin"
    export XCAT_NM_KEYFILE_DIR="${BATS_TEST_TMPDIR}/system-connections"
    export XCAT_IFCFG_DIR="${BATS_TEST_TMPDIR}/network-scripts/"
    mkdir -p "$BIN" "$XCAT_NM_KEYFILE_DIR" "$XCAT_IFCFG_DIR"
    export PATH="$BIN:$PATH"
    networkmanager_active=1
    UUID=21d3e0bf-7bd1-4e0c-9a4a-6f4b0d2c1111
}

# nmcli reports $UUID for the connection, as the keyfile path resolution needs.
stub_nmcli()
{
    cat >"$BIN/nmcli" <<EOF
#!/bin/sh
case "\$*" in
    *connection.uuid*) printf '%s\n' "$UUID" ;;
    *UUID,FILENAME*)   printf '%s:%s\n' "$UUID" "$XCAT_NM_KEYFILE_DIR/xcat-ens4.nmconnection" ;;
esac
EOF
    chmod 0755 "$BIN/nmcli"
}

# The keyfile NetworkManager wrote, named with the uuid suffix it uses on a name collision.
write_keyfile()
{
    cat >"$XCAT_NM_KEYFILE_DIR/xcat-ens4-${UUID}.nmconnection" <<EOF
[connection]
id=xcat-ens4
uuid=$UUID
type=ethernet
EOF
}

# The ifcfg file NetworkManager wrote on EL8. It names the file "<name>-1" when one of that
# name is already there, and the NAME= line says which connection it holds.
write_ifcfg_dash_one()
{
    cat >"$XCAT_IFCFG_DIR/ifcfg-xcat-ens4" <<'EOF'
NAME=some-other-connection
DEVICE=ens4
EOF
    cat >"$XCAT_IFCFG_DIR/ifcfg-xcat-ens4-1" <<'EOF'
TYPE=Ethernet
BOOTPROTO=none
IPADDR=100.168.250.10
NAME=xcat-ens4
DEVICE=ens4
EOF
}

@test "EL9 keeps the parameter in the keyfile's user section" {
    stub_nmcli
    write_keyfile
    . "$LIB"

    run xcat_persist_nic_extra_params xcat-ens4 alma9 unset "CONNECTED_MODE=yes"
    [ "$status" -eq 0 ]
    grep -qx '\[user\]' "$XCAT_NM_KEYFILE_DIR/xcat-ens4-${UUID}.nmconnection"
    grep -qx 'xcat.CONNECTED_MODE=yes' "$XCAT_NM_KEYFILE_DIR/xcat-ens4-${UUID}.nmconnection"
}

@test "EL8 keeps the parameter in the ifcfg file NetworkManager named -1" {
    stub_nmcli
    write_ifcfg_dash_one
    . "$LIB"

    run xcat_persist_nic_extra_params xcat-ens4 alma8 unset "CONNECTED_MODE=yes"
    [ "$status" -eq 0 ]
    grep -qx 'CONNECTED_MODE=yes' "$XCAT_IFCFG_DIR/ifcfg-xcat-ens4-1"
}

@test "EL8 writes nothing into the ifcfg file of another connection" {
    stub_nmcli
    write_ifcfg_dash_one
    . "$LIB"

    run xcat_persist_nic_extra_params xcat-ens4 alma8 unset "CONNECTED_MODE=yes"
    [ "$status" -eq 0 ]
    refute_grep -q 'CONNECTED_MODE' "$XCAT_IFCFG_DIR/ifcfg-xcat-ens4"
}

@test "the token for an unset attribute is not written as a parameter" {
    stub_nmcli
    write_ifcfg_dash_one
    . "$LIB"

    run xcat_persist_nic_extra_params xcat-ens4 alma8 unset unset
    [ "$status" -eq 0 ]
    refute_grep -q 'unset' "$XCAT_IFCFG_DIR/ifcfg-xcat-ens4-1"
}
