#!/bin/bash
# Read the firewalld state of the node it runs on, for the configfirewall cases.
#
# A port counts as open on a NIC when the zone of that NIC has the target ACCEPT, lists the
# port (a range counts), or lists a service that defines the port. The cases do not care which
# of the three configfirewall picks.
#
# "check" reads the state twice: once as it is, and once after "firewall-cmd --reload". A
# reload drops every runtime-only change, so the second read is what the node keeps after a
# restart of firewalld.
#
# Usage:
#   fw_check.sh nic-to <ip>                  print the NIC of the route to <ip>
#   fw_check.sh nic-default                  print the NIC of the default route
#   fw_check.sh check <nic> <port/proto>...  firewalld runs, starts at boot, serves the ports
#   fw_check.sh masquerade <nic>             firewalld runs and masquerades out of <nic>
#   fw_check.sh save | restore               keep and put back the firewall state of the node
#
# Prints: FWCHECK-OK when every condition holds, else one FWCHECK-BAD: line per gap.
# Exits:  0 when every condition holds, 1 when one does not, 2 on a usage error.

STATE=/tmp/xcattest-configfirewall.state
bad=0

say_bad() {
    echo "FWCHECK-BAD: $*"
    bad=1
}

zone_of() {
    local z
    z=$(firewall-cmd --get-zone-of-interface="$1" 2>/dev/null) || z=$(firewall-cmd --get-default-zone 2>/dev/null)
    echo "$z"
}

# in_list <port/proto> <entry>... ; an entry is port/proto or lo-hi/proto
in_list() {
    local p=${1%/*} pr=${1#*/} e lo hi
    shift
    for e in "$@"; do
        [ "${e#*/}" = "$pr" ] || continue
        e=${e%/*}
        lo=${e%-*}
        hi=${e#*-}
        [ "$p" -ge "$lo" ] 2>/dev/null && [ "$p" -le "$hi" ] 2>/dev/null && return 0
    done
    return 1
}

served() {
    local zone=$1 pp=$2 s
    [ "$(firewall-cmd --info-zone="$zone" 2>/dev/null | awk '/^ *target:/ {print $2}')" = ACCEPT ] && return 0
    in_list "$pp" $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null) && return 0
    for s in $(firewall-cmd --zone="$zone" --list-services 2>/dev/null); do
        in_list "$pp" $(firewall-cmd --info-service="$s" 2>/dev/null | sed -n 's/^ *ports: *//p') && return 0
    done
    return 1
}

running() {
    local st
    st=$(firewall-cmd --state 2>&1)
    [ "$st" = running ] && return 0
    say_bad "firewalld state is '$st' ($1)"
    return 1
}

check_ports() {
    local when=$1 nic=$2 zone pp
    shift 2
    running "$when" || return
    zone=$(zone_of "$nic")
    for pp in "$@"; do
        served "$zone" "$pp" || say_bad "$pp is not open on $nic, zone '$zone' ($when)"
    done
}

check_masq() {
    local when=$1 nic=$2 zone
    running "$when" || return
    zone=$(zone_of "$nic")
    firewall-cmd --zone="$zone" --query-masquerade >/dev/null 2>&1 \
        || say_bad "zone '$zone' of $nic does not masquerade ($when)"
}

enabled() {
    systemctl is-enabled --quiet firewalld 2>/dev/null || say_bad "firewalld.service is not enabled"
}

verdict() {
    [ "$bad" = 0 ] && echo "FWCHECK-OK"
    exit "$bad"
}

cmd=$1
shift
case "$cmd" in
nic-to)
    [ -n "$1" ] || exit 2
    ip -o route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p'
    ;;
nic-default)
    ip route show default | awk '{print $5; exit}'
    ;;
check)
    [ $# -ge 2 ] || exit 2
    nic=$1
    shift
    check_ports "as configured" "$nic" "$@"
    enabled
    firewall-cmd --reload >/dev/null 2>&1
    check_ports "after a reload" "$nic" "$@"
    verdict
    ;;
masquerade)
    [ -n "$1" ] || exit 2
    check_masq "as configured" "$1"
    enabled
    firewall-cmd --reload >/dev/null 2>&1
    check_masq "after a reload" "$1"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] || say_bad "net.ipv4.ip_forward is not 1"
    verdict
    ;;
save)
    {
        systemctl is-active --quiet firewalld && echo active=1 || echo active=0
        systemctl is-enabled --quiet firewalld && echo enabled=1 || echo enabled=0
        if systemctl is-active --quiet firewalld; then
            for z in $(firewall-cmd --get-zones); do
                firewall-cmd --permanent --zone="$z" --query-masquerade >/dev/null 2>&1 && echo "masq=$z"
            done
        fi
    } >"$STATE"
    cat "$STATE"
    ;;
restore)
    [ -f "$STATE" ] || { echo "no saved state in $STATE"; exit 1; }
    systemctl disable --now iptables >/dev/null 2>&1
    if grep -qx active=1 "$STATE"; then
        systemctl unmask firewalld >/dev/null 2>&1
        systemctl start firewalld
        for z in $(sed -n 's/^masq=//p' "$STATE"); do
            firewall-cmd --permanent --zone="$z" --add-masquerade >/dev/null
        done
        firewall-cmd --reload >/dev/null
    else
        systemctl stop firewalld >/dev/null 2>&1
    fi
    if grep -qx enabled=1 "$STATE"; then
        systemctl enable firewalld >/dev/null 2>&1
    else
        systemctl disable firewalld >/dev/null 2>&1
    fi
    rm -f "$STATE"
    echo "restored: firewalld $(systemctl is-active firewalld) $(systemctl is-enabled firewalld 2>/dev/null)"
    ;;
*)
    echo "usage: $0 nic-to <ip> | nic-default | check <nic> <port/proto>... | masquerade <nic> | save | restore"
    exit 2
    ;;
esac
