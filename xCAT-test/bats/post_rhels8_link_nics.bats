#!/usr/bin/env bats
#
# post.rhels8 runs at the end of an EL8, EL9 and openEuler install, and sets
# ONBOOT=yes on the ifcfg file of each NIC with link. Two kinds of NIC with
# link stay at ONBOOT=no: the USB NIC of a BMC, and a NIC that the mac table
# marks *NOIP*. The management node serves neither an address, so a DHCP
# client on either one makes NetworkManager-wait-online fail.
#
# Each test renders post.rhels8 with xCAT::Template and runs it in a private
# filesystem namespace with a fake /sys, ethtool and nmcli.

load 'helpers/shell_source'

setup()
{
    [ "$(uname -s)" = Linux ] || skip 'Postscript filesystem isolation requires Linux'
    command -v bwrap >/dev/null || { echo 'bubblewrap is required' >&2; return 1; }
    fixture="${BATS_TEST_TMPDIR:?bats-core 1.4 or newer is required}/post"
    mkdir -p "$fixture"/{bin,link,sys/class/net,sys/bus/pci/drivers/e1000e,sys/bus/usb/drivers/cdc_ether,sys/bus/usb/drivers/r8152}
    mkdir -p "$fixture"/{etc/sysconfig/network-scripts,etc/yum.repos.d,var/log/xcat,tmp}
    : >"$fixture/nmcli.log"
    cat >"$fixture/bin/nmcli" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>/work/nmcli.log
SH
    cat >"$fixture/bin/ethtool" <<'SH'
#!/bin/sh
[ -e "/work/link/$1" ] && state=yes || state=no
printf '\tLink detected: %s\n' "$state"
SH
    chmod +x "$fixture/bin/"*
    sandbox=(env -i PATH=/usr/bin:/bin bwrap --unshare-all --die-with-parent --new-session
        --tmpfs / --ro-bind /usr /usr --ro-bind /bin /bin
        --ro-bind /lib /lib --proc /proc --dev /dev
        --bind "$fixture" /work --bind "$fixture/etc" /etc
        --bind "$fixture/tmp" /tmp --bind "$fixture/var" /var
        --ro-bind "$fixture/sys" /sys
        --setenv PATH /work/bin:/usr/bin:/bin --setenv LC_ALL C)
    [ ! -d /etc/alternatives ] || sandbox+=(--ro-bind /etc/alternatives /etc/alternatives)
    [ ! -d /lib64 ] || sandbox+=(--ro-bind /lib64 /lib64)
}

# nic <name> <driver|-> <mac> <link yes|no> -- an ifcfg file at ONBOOT=no, and
# a sysfs entry with that driver and MAC. A driver of - gives the NIC no sysfs entry.
nic()
{
    local name="$1" driver="$2" mac="$3" link="$4" bus
    printf 'DEVICE=%s\nBOOTPROTO=dhcp\nONBOOT=no\n' "$name" \
        >"$fixture/etc/sysconfig/network-scripts/ifcfg-$name"
    [ "$link" = yes ] && : >"$fixture/link/$name"
    [ "$driver" = - ] && return 0
    case "$driver" in
    e1000e) bus=pci ;;
    *)      bus=usb ;;
    esac
    mkdir -p "$fixture/sys/class/net/$name/device"
    ln -s "/sys/bus/$bus/drivers/$driver" "$fixture/sys/class/net/$name/device/driver"
    printf '%s\n' "$mac" >"$fixture/sys/class/net/$name/address"
}

# render_and_run <mac table value> -- render post.rhels8 for a node with that
# mac row, then run it.
render_and_run()
{
    run env -i PATH=/usr/bin:/bin perl "$(repo_path xCAT-test/bats/fixtures/render-network-post.pl)" \
        8 "$fixture" 0 "$1"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    run "${sandbox[@]}" timeout 20 /bin/bash /work/post
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

onboot()
{
    sed -n 's/^ONBOOT=//p' "$fixture/etc/sysconfig/network-scripts/ifcfg-$1"
}

@test "post.rhels8 leaves a NIC that the mac table marks *NOIP* at ONBOOT=no" {
    nic eno1 e1000e 52:54:00:12:34:56 yes
    nic eno3 e1000e 52:54:00:00:00:0a yes
    # The mac table may hold upper case. sysfs always reports lower case.
    render_and_run '52:54:00:12:34:56|52:54:00:00:00:0A!*NOIP*'
    [ "$(onboot eno1)" = yes ]
    [ "$(onboot eno3)" = no ]
}

@test "post.rhels8 activates the NICs with link except the USB NIC of the BMC" {
    nic eno1 e1000e 52:54:00:12:34:56 yes
    nic usb0 cdc_ether 52:54:00:12:34:57 yes
    nic enx1 r8152 52:54:00:12:34:58 yes
    nic eno2 e1000e 52:54:00:12:34:59 no
    nic renamed0 - '' yes
    render_and_run '52:54:00:12:34:56'
    [ "$(onboot eno1)" = yes ]
    [ "$(onboot usb0)" = no ]
    [ "$(onboot enx1)" = yes ]
    [ "$(onboot eno2)" = no ]
    [ "$(onboot renamed0)" = yes ]
    [ ! -s "$fixture/nmcli.log" ]
}

@test "post.rhels8 falls back to NetworkManager when only the USB NIC of the BMC has link" {
    nic eno1 e1000e 52:54:00:12:34:56 no
    nic usb0 cdc_ether 52:54:00:12:34:57 yes
    render_and_run '52:54:00:12:34:56'
    [ "$(onboot eno1)" = no ]
    [ "$(onboot usb0)" = no ]
    grep -Fxq -- '-g NAME,STATE con show' "$fixture/nmcli.log"
}
