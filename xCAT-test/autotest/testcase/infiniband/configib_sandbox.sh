#!/bin/bash
#
# configib_sandbox.sh <el10|el10-nodevice|el10-ethernet|noble|noble-nodevice>
#
# Run the installed configib against a scratch root, so a management node without an IB card can
# check what configib writes. XCAT_CONFIGIB_ROOT moves /etc and /sys into the scratch root. nmcli,
# netplan and the other commands that change a node are stubs that log their arguments.
# The script prints the output of configib, the logged commands and the files configib wrote,
# then exits with the exit status of configib.

scenario=$1
configib=${CONFIGIB:-}
for f in /install/postscripts/configib /xcatpost/configib "${XCATROOT:-/opt/xcat}/share/xcat/postscripts/configib"; do
    [ -z "$configib" ] && [ -r "$f" ] && configib=$f
done
[ -n "$configib" ] || { echo "configib_sandbox: no configib found" >&2; exit 2; }
# A configib older than 2.21 ignores XCAT_CONFIGIB_ROOT and would change /etc of this node.
grep -q XCAT_CONFIGIB_ROOT "$configib" || { echo "configib_sandbox: $configib has no scratch root support" >&2; exit 2; }

work=$(mktemp -d /tmp/configib_sandbox.XXXXXX) || exit 2
trap 'rm -rf "$work"' EXIT
root="$work/root"
bin="$work/bin"
events="$work/events"
mkdir -p "$root/etc/sysconfig/network-scripts" "$root/sys/class/net" "$root/nmcli" "$bin"
: >"$events"
: >"$root/etc/sysctl.conf"

for command in logger sysctl modprobe netplan networkctl ifup ifdown ip sleep; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$command" "$events" >"$bin/$command"
done
printf '#!/bin/sh\necho "systemctl $*" >>"%s"\n[ "$1" = is-active ] && exit 3\nexit 0\n' "$events" >"$bin/systemctl"
cat >"$bin/nmcli" <<SH
#!/bin/sh
echo "nmcli \$*" >>"$events"
case "\$*" in
    "--field connection.id con show "*) [ -e "$root/nmcli/\$5" ] ;;
    "con add "*) : >"$root/nmcli/ib0" ;;
esac
SH
chmod 0755 "$bin"/*

device() # <nic> <ARPHRD type>
{
    mkdir -p "$root/sys/class/net/$1"
    echo "$2" >"$root/sys/class/net/$1/type"
}

network='netname=ib4||net=10.10.0.0||mask=255.255.0.0||mgtifname=||gateway=||dhcpserver=||tftpserver=||nameservers=||ntpservers=||logservers=||dynamicrange=||staticrange=||staticrangeincrement=||nodehostname=||ddnsdomain=||vlanid=||domain=||mtu=||disable=||comments='
network6='netname=ib6||net=fd00:10::||mask=/64||mgtifname=||gateway=||dhcpserver=||tftpserver=||nameservers=||ntpservers=||logservers=||dynamicrange=||staticrange=||staticrangeincrement=||nodehostname=||ddnsdomain=||vlanid=||domain=||mtu=||disable=||comments='

case "$scenario" in
    el10*)
        echo 'AlmaLinux release 10.0 (Purple Lion)' >"$root/etc/redhat-release"
        osver=rhels10 ;;
    noble*)
        printf 'NAME="Ubuntu"\nVERSION_ID="24.04"\n' >"$root/etc/os-release"
        mkdir -p "$root/etc/netplan"
        osver=ubuntu24.04 ;;
    *) echo "configib_sandbox: unknown scenario $scenario" >&2; exit 2 ;;
esac
case "$scenario" in
    *-nodevice) ;;
    *-ethernet) device ib0 1 ;;
    *) device ib0 32 ;;
esac

env -i PATH="$bin:/usr/sbin:/usr/bin:/sbin:/bin" LC_ALL=C XCAT_CONFIGIB_ROOT="$root" \
    OSVER=$osver NMCLI_USED=1 NIC_IBNICS=ib0 NETWORKS_LINES=2 \
    NETWORKS_LINE1="$network" NETWORKS_LINE2="$network6" \
    'NICIPS=ib0!10.10.0.5|fd00:10::5' 'NICNETWORKS=ib0!ib4|ib6' \
    bash "$configib"
rc=$?

echo "== commands"
cat "$events"
for f in $(cd "$root" && find etc/netplan etc/sysconfig/network-scripts etc/network -type f 2>/dev/null); do
    echo "== file /$f"
    cat "$root/$f"
done
echo "== configib exit status $rc"
exit $rc
