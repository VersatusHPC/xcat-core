#!/usr/bin/env bats
#
# The netplan generator of an Ubuntu 24.04 diskless node lists the NICs that
# systemd-networkd-wait-online waits for, by the names they have when the root switches.
# The initial ramdisk must give each NIC the name that the booted system gives it, or
# wait-online waits for a name that no longer exists and fails the boot.

load 'helpers/shell_source'

setup()
{
    INSTALL="$(require_repo_file 'xCAT-server/share/xcat/netboot/ubuntu/dracut/install.netboot')"
    MOD="$(dirname "$INSTALL")"
    LOG="${BATS_TEST_TMPDIR}/installed"
    : >"$LOG"
    LIBNET="${BATS_TEST_TMPDIR}/lib/systemd/network"
    ETCNET="${BATS_TEST_TMPDIR}/etc/systemd/network"
    mkdir -p "$LIBNET" "$ETCNET"
}

# Run install.netboot as dracut does, with its helpers stubbed to record what it asks for.
run_install()
{
    run env MODDIR="$MOD" LOG="$LOG" LIBNET="$LIBNET" ETCNET="$ETCNET" bash -c '
        moddir=$MODDIR
        systemdnetwork=$LIBNET
        systemdnetworkconfdir=$ETCNET
        dracut_install() { :; }
        inst()           { :; }
        inst_hook()      { :; }
        inst_simple()    { printf "inst_simple %s\n" "$1" >>"$LOG"; }
        . "$MODDIR/install.netboot"
    '
}

@test "the initial ramdisk carries the .link files that name the NICs of the booted system" {
    : >"$LIBNET/99-default.link"
    : >"$LIBNET/73-usb-net-by-mac.link"
    : >"$ETCNET/10-site.link"
    : >"$LIBNET/80-wifi.network"
    run_install
    [ "$status" -eq 0 ]
    grep -qx "inst_simple $LIBNET/99-default.link" "$LOG"
    grep -qx "inst_simple $LIBNET/73-usb-net-by-mac.link" "$LOG"
    grep -qx "inst_simple $ETCNET/10-site.link" "$LOG"
    run grep -c 'wifi.network' "$LOG"
    [ "$output" = "0" ]
}

@test "an image with no .link file installs none" {
    run_install
    [ "$status" -eq 0 ]
    run grep -c '\.link$' "$LOG"
    [ "$output" = "0" ]
}
