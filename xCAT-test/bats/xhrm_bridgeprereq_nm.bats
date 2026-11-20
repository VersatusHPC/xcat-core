#!/usr/bin/env bats
#
# xHRM bridgeprereq on a host with NetworkManager and no bridge-utils, which is EL 9 and later.
# The bridge must keep the MAC of its port, so the DHCP reservation of the node stays valid, and
# it must forward at once, so a guest network boot is not held back by STP.
#
# nmcli, ip and modprobe are stubbed. PATH holds no sbin directory, so brctl is absent. The
# stub nmcli answers "running" only when NM_STATE=running, as in a booted host; otherwise it
# fails like nmcli in the anaconda %post chroot, where no NetworkManager runs.

load 'helpers/shell_source'

PORT=ens3
PORT_MAC=42:54:00:c9:9a:10

setup()
{
    SCRIPT="$(require_repo_file 'xCAT-server/share/xcat/scripts/xHRM')"
    BIN="${BATS_TEST_TMPDIR}/bin"
    CONNDIR="${BATS_TEST_TMPDIR}/system-connections"
    NMCLI_LOG="${BATS_TEST_TMPDIR}/nmcli.log"
    mkdir -p "$BIN" "$CONNDIR"
    : >"$NMCLI_LOG"

    cat >"$BIN/nmcli" <<EOF
#!/bin/bash
echo "\$*" >>"$NMCLI_LOG"
if [ "\$*" = "-t -f RUNNING general" ]; then
    if [ "\${NM_STATE:-}" = running ]; then echo running; exit 0; fi
    echo "Error: NetworkManager is not running." >&2
    exit 8
fi
if [ "\$1" = "--offline" ]; then
    shift
    echo "[connection]"
    echo "# \$*"
fi
exit 0
EOF
    cat >"$BIN/ip" <<EOF
#!/bin/bash
case "\$*" in
    "-o link show dev $PORT")
        echo "2: $PORT: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000\\    link/ether $PORT_MAC brd ff:ff:ff:ff:ff:ff" ;;
    "-4 -o addr show dev $PORT scope global")
        echo "2: $PORT    inet 192.0.2.10/24 brd 192.0.2.255 scope global dynamic noprefixroute $PORT\\       valid_lft 43000sec preferred_lft 43000sec" ;;
    *) echo "unexpected ip \$*" >&2; exit 1 ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' >"$BIN/modprobe"
    chmod 0755 "$BIN"/*

    export PATH="$BIN:/usr/bin:/bin"
    export INSTALLNIC="$PORT"
    export XHRM_NM_CONNDIR="$CONNDIR"
    if command -v brctl >/dev/null; then
        echo "brctl is on PATH at $(command -v brctl); this file measures a host without it" >&2
        return 1
    fi
}

@test "a booted host gets a bridge with the port MAC, no STP, and the port enslaved" {
    NM_STATE=running run bash "$SCRIPT" bridgeprereq br0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"No bridge-utils installed"* ]]

    grep -E "^connection add type bridge .*ifname br0" "$NMCLI_LOG"
    grep -E "^connection add type bridge .*bridge.stp no" "$NMCLI_LOG"
    grep -E "^connection add type bridge .*bridge.forward-delay 0" "$NMCLI_LOG"
    grep -E "^connection add type bridge .*bridge.mac-address $PORT_MAC" "$NMCLI_LOG"
    grep -E "^connection add type bridge .*ipv4.method auto" "$NMCLI_LOG"
    grep -E "^connection add type ethernet .*ifname $PORT .*connection.master br0 connection.slave-type bridge" "$NMCLI_LOG"
    grep -E "^connection up br0-port-$PORT" "$NMCLI_LOG"
    ! grep -E "^--offline" "$NMCLI_LOG"
}

@test "the anaconda %post chroot gets keyfiles, mode 600, and no connection is brought up" {
    run bash "$SCRIPT" bridgeprereq br0
    echo "$output"
    [ "$status" -eq 0 ]

    [ -f "$CONNDIR/br0.nmconnection" ]
    [ -f "$CONNDIR/br0-port-$PORT.nmconnection" ]
    [ "$(stat -c %a "$CONNDIR/br0.nmconnection")" = 600 ]
    [ "$(stat -c %a "$CONNDIR/br0-port-$PORT.nmconnection")" = 600 ]
    grep -E "bridge.mac-address $PORT_MAC" "$CONNDIR/br0.nmconnection"
    grep -E "bridge.stp no" "$CONNDIR/br0.nmconnection"
    grep -E "connection.master br0 connection.slave-type bridge" "$CONNDIR/br0-port-$PORT.nmconnection"
    ! grep -E "^connection up" "$NMCLI_LOG"
}

@test "a static address given on the command line goes to the bridge" {
    run bash "$SCRIPT" bridgeprereq br0 192.0.2.20 255.255.255.0
    echo "$output"
    [ "$status" -eq 0 ]
    grep -E "ipv4.method manual ipv4.addresses 192.0.2.20/24" "$CONNDIR/br0.nmconnection"
}

@test "a bridge that already has a keyfile is left alone" {
    echo "[connection]" >"$CONNDIR/br0.nmconnection"
    run bash "$SCRIPT" bridgeprereq br0
    [ "$status" -eq 0 ]
    [[ "$output" == *"br0 already exists"* ]]
    ! grep -E "connection add" "$NMCLI_LOG"
}

@test "a bond port is refused and the message names confignetwork" {
    INSTALLNIC="ens3&ens4" run bash "$SCRIPT" bridgeprereq br0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confignetwork"* ]]
    ! grep -E "connection add" "$NMCLI_LOG"
}
