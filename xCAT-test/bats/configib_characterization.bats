#!/usr/bin/env bats
#
# The behaviour of configib that the 2.21 changes keep: the nmcli arguments on EL 10, the ifcfg
# file on EL 8, the /etc/network/interfaces stanza on an Ubuntu node that runs ifupdown, and the
# exit status. These tests run the script in a private filesystem namespace, with a scratch /etc
# and /sys bound over the real ones, so they need no change to configib and run the same against
# every revision of it.
#
# The commands that change a node are stubs in /run/fixture/bin, first in PATH. They append
# "<command> <arguments>" to /run/fixture/events.

load 'helpers/shell_source'

setup()
{
    [ "$(uname -s)" = Linux ] || skip 'configib filesystem isolation requires Linux'
    local bwrap command
    bwrap=$(PATH=/usr/bin:/bin type -P bwrap) || {
        echo 'Install bubblewrap to run the configib tests' >&2
        return 1
    }
    CONFIGIB="$(require_repo_file 'xCAT/postscripts/configib')"
    fixture="${BATS_TEST_TMPDIR}/fixture"
    mkdir -p "$fixture"/{bin,etc/sysconfig/network-scripts,sys/class/net/ib0,nmcli,tmp}
    : >"$fixture/events"
    : >"$fixture/etc/sysctl.conf"
    printf '32\n' >"$fixture/sys/class/net/ib0/type"
    for command in logger sysctl systemctl modprobe ifup ifdown sleep; do
        printf '#!/bin/sh\necho "%s $*" >>/run/fixture/events\n' "$command" >"$fixture/bin/$command"
    done
    # "systemctl is-active" answers inactive unless the test writes /run/fixture/active.
    printf '#!/bin/sh\necho "systemctl $*" >>/run/fixture/events\n[ "$1" = is-active ] && { [ -e /run/fixture/active ]; exit; }\nexit 0\n' \
        >"$fixture/bin/systemctl"
    cat >"$fixture/bin/nmcli" <<'SH'
#!/bin/sh
echo "nmcli $*" >>/run/fixture/events
case "$*" in
    "--field connection.id con show "*) [ -e "/run/fixture/nmcli/$5" ] ;;
    "con up "*) [ ! -e /run/fixture/up-fails ] || exit 4 ;;
esac
SH
    chmod 0755 "$fixture/bin"/*
    sandbox=(env -i PATH=/run/fixture/bin:/usr/bin:/bin LC_ALL=C "$bwrap"
        --unshare-all --die-with-parent --new-session
        --ro-bind / / --tmpfs /run --proc /proc --dev /dev
        --bind "$fixture" /run/fixture --bind "$fixture/tmp" /tmp
        --bind "$fixture/etc" /etc --ro-bind "$fixture/sys" /sys
        --ro-bind "$(dirname "$CONFIGIB")" /run/postscripts --chdir /tmp)
}

network()
{
    printf 'netname=%s||net=%s||mask=%s||mgtifname=||gateway=||dhcpserver=||tftpserver=||nameservers=||ntpservers=||logservers=||dynamicrange=||staticrange=||staticrangeincrement=||nodehostname=||ddnsdomain=||vlanid=||domain=||mtu=||disable=||comments=' \
        "$1" "$2" "$3"
}

# run_configib <VAR=value>...
run_configib()
{
    run "${sandbox[@]}" /usr/bin/env NIC_IBNICS=ib0 NETWORKS_LINES=1 \
        NETWORKS_LINE1="$(network ib4 10.10.0.0 255.255.0.0)" \
        'NICIPS=ib0!10.10.0.5' 'NICNETWORKS=ib0!ib4' "$@" \
        bash /run/postscripts/configib
}

show()
{
    printf 'status=%s\n%s\n--- events\n' "$status" "$output" >&2
    cat "$fixture/events" >&2
}

@test "EL 10: a new ib0 is an infiniband connection made with nmcli, and it comes up" {
    printf 'AlmaLinux release 10.0\n' >"$fixture/etc/redhat-release"
    run_configib OSVER=rhels10 NMCLI_USED=1
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'nmcli con add type infiniband con-name ib0 ifname ib0 ipv4.method manual ipv4.addresses 10.10.0.5/16' \
        "$fixture/events" || { show; false; }
    grep -qx 'nmcli con up ib0' "$fixture/events" || { show; false; }
    [ -z "$(ls -A "$fixture/etc/sysconfig/network-scripts")" ]
}

@test "EL 10: an existing ib0 connection is modified" {
    printf 'AlmaLinux release 10.0\n' >"$fixture/etc/redhat-release"
    : >"$fixture/nmcli/ib0"
    run_configib OSVER=rhels10 NMCLI_USED=1
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'nmcli con modify ib0 type infiniband con-name ib0 ifname ib0 connection.autoconnect yes ipv4.method manual ipv4.addresses 10.10.0.5/16' \
        "$fixture/events" || { show; false; }
}

@test "EL 10: a connection that does not come up fails configib" {
    printf 'AlmaLinux release 10.0\n' >"$fixture/etc/redhat-release"
    : >"$fixture/up-fails"
    run_configib OSVER=rhels10 NMCLI_USED=1
    [ "$status" -ne 0 ] || { show; false; }
}

@test "EL 8 without NetworkManager: configib writes ifcfg-ib0 and runs ifup" {
    printf 'AlmaLinux release 8.10\n' >"$fixture/etc/redhat-release"
    run_configib OSVER=rhels8.10 NMCLI_USED=0
    [ "$status" -eq 0 ] || { show; false; }
    cfg="$fixture/etc/sysconfig/network-scripts/ifcfg-ib0"
    [ "$(sed '/^$/d' "$cfg")" = "$(printf '%s\n' DEVICE=ib0 NM_CONTROLLED=no BOOTPROTO=none ONBOOT=yes DEFROUTE=no NAME=ib0 IPADDR=10.10.0.5 NETMASK=255.255.0.0)" ] \
        || { show; cat "$cfg" >&2; false; }
    grep -qx 'ifup ib0' "$fixture/events" || { show; false; }
}

@test "Ubuntu with ifupdown: configib appends an interfaces stanza" {
    printf 'NAME="Ubuntu"\n' >"$fixture/etc/os-release"
    mkdir -p "$fixture/etc/network"
    printf 'auto lo\niface lo inet loopback\n' >"$fixture/etc/network/interfaces"
    : >"$fixture/active"
    run_configib OSVER=ubuntu22.04
    [ "$status" -eq 0 ] || { show; false; }
    [ "$(cat "$fixture/etc/network/interfaces")" = "$(printf '%s\n' 'auto lo' 'iface lo inet loopback' 'auto ib0' 'iface ib0 inet static' 'address 10.10.0.5' 'netmask 255.255.0.0')" ] \
        || { show; cat "$fixture/etc/network/interfaces" >&2; false; }
    grep -qx 'ifup ib0' "$fixture/events" || { show; false; }
}

@test "configib changes sysctl.conf so that ib0 answers ARP only for its own address" {
    printf 'AlmaLinux release 10.0\n' >"$fixture/etc/redhat-release"
    run_configib OSVER=rhels10 NMCLI_USED=1
    [ "$status" -eq 0 ] || { show; false; }
    grep -qx 'net.ipv4.conf.ib0.arp_filter=1' "$fixture/etc/sysctl.conf"
    grep -qx 'net.ipv4.conf.ib0.arp_ignore=1' "$fixture/etc/sysctl.conf"
}
