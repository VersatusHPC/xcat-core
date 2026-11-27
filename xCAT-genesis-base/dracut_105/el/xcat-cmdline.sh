#!/bin/bash
root=1
rootok=1
netroot=xcat

# The image ships the C.UTF-8 locale only. tmux refuses to start under the C locale.
export LC_ALL=C.UTF-8

# The x86_64 network drivers to load, one name per line, from a modules.dep file.
# xen-netfront is left out: the hook loads it quietly before this list, and outside a Xen
# guest a second modprobe prints "could not insert 'xen_netfront': No such device".
xcat_x86_net_modules() {
    grep -vE 'tunnel|ieee|ifb|bond|dummy|fjes|hv_netvsc|ntb_netdev|xen-netfront|hdlc_fr|dlci' "$1" |
        awk -F: '$1 ~ /kernel\/drivers\/net/ {print $1}' |
        sed -e 's/\.ko.*//' -e 's/.*\///'
}

# tmux exits when the image carries no UTF-8 locale. doxcat is the whole of Genesis, so it
# must run whether or not the multiplexer starts. Prints tmux or direct.
xcat_console_mode() {
    if tmux -f /dev/null new-session -d -s xcatprobe true >/dev/null 2>&1; then
        tmux kill-session -t xcatprobe >/dev/null 2>&1
        echo tmux
    else
        echo direct
    fi
}

# Run doxcat in the tmux session doxcat, or attach to that session when it exists. The caller
# loops, so a person who leaves the session gets it back. attach-session before the session
# exists writes "can't find session" to the console; new-session -A does not.
xcat_doxcat_session() {
    tmux new-session -A -s doxcat doxcat
}
clear
echo PS1="'"'[xCAT Genesis running on \H \w]\$ '"'" > /.bashrc
echo PS1="'"'[xCAT Genesis running on \H \w]\$ '"'" > /.bash_profile
mkdir -p /etc/ssh
mkdir -p /var/tmp/
mkdir -p /var/empty/sshd
# dracut writes this entry itself, with an empty password field unless the image is
# built --hostonly. Match the user name only. module-setup.sh copies the service users
# from the build root, so only root is rewritten here.
sed -i '/^root:/d' /etc/passwd
cat >>/etc/passwd <<"__ENDL"
root:x:0:0::/:/bin/bash
__ENDL
# Fedora 20 ppc64 uses /lib/dracut/hooks/initqueue/finished
# CentOS 7 probably uses /lib/dracut/hooks/initqueue/finished also
if [ -d "/initqueue-finished" ]; then
    echo '[ -e $NEWROOT/proc ]' > /initqueue-finished/xcatroot.sh
else
    #echo 'if [ -e /proc ]; then /bin/doxcat; fi' > /lib/dracut/hooks/initqueue/finished/xcatroot.sh
    echo '[ -e /proc ]' > /lib/dracut/hooks/initqueue/finished/xcatroot.sh
fi
mkdir /dev/cgroup
mount -t cgroup -o cpu,memory,devices cgroup /dev/cgroup
# Fedora 20 ppc64 does not udevd
# CentOS 7 probably does not have udevd either
if [ -f "/sbin/udevd" ]; then
    udevd --daemon
else
    /usr/lib/systemd/systemd-udevd --daemon
fi
udevadm trigger
mkdir -p /var/lib/dhclient/
mkdir -p /var/log
ip link set lo up
echo '127.0.0.1 localhost' >> /etc/hosts
XCAT_CONSOLE_MODE="$(xcat_console_mode)"
if [ "$XCAT_CONSOLE_MODE" = "tmux" ]; then
    if grep -q console=ttyS /proc/cmdline; then
        while :; do sleep 1; tmux attach-session -t doxcat </dev/tty1 &>/dev/tty1; clear &>/dev/tty1 ; done &
    fi
    while :; do tmux new-session < /dev/tty2 &> /dev/tty2 ; done &
fi

# The section below is just for System P LE hardware discovery

ARCH="$(uname -m)"

if [[ ${ARCH} =~ ppc64 ]]; then
    # Need to wait for NIC initialization (System P LE discovery only)
    sleep 20
    # load all network driver modules listed in /lib/modules/<kernel>/modules.dep file
    KERVER=`uname -r`
    for line in `cat /lib/modules/$KERVER/modules.dep | awk -F: '{print \$1}' | sed -e "s/\(.*\)\.ko.*/\1/"`; do
        if [[ $line =~ "kernel/drivers/net" ]]; then
            modprobe `basename $line`
        fi
    done
    # Check if running on a VM, and load "virtio_pci" module
    cat /proc/cpuinfo | grep "machine" | grep "emulated"
    if [ $? -eq 0 ]; then
        modprobe virtio_pci
    fi
    waittime=2
    ALL_NICS=$(ip link show | grep -v "^ " | awk '{print $2}' | sed -e 's/:$//' | grep -v lo)
    for tmp in $ALL_NICS; do
        tmp_data="$(ip link show "$tmp" | grep -v "^ " | grep "UP")"
        if [ "$tmp_data" == "" ]; then
            ip link set "$tmp" up
        fi
        tmp_data="UP"
        waittime=$((waittime+1))
    done
    # wait 2+number_of_nics seconds for all the LINKed NICs to be UP
    sleep $waittime
elif [[ ${ARCH} =~ x86_64 ]]; then
    # load all network driver modules listed in /lib/modules/<kernel>/modules.dep file
    KERVER=`uname -r`
    # Xen guests require xen-netfront for the paravirtual NIC.
    modprobe xen-netfront 2>/dev/null || :
    for mod in $(xcat_x86_net_modules /lib/modules/$KERVER/modules.dep); do
        modprobe $mod
    done
fi

if [ "$XCAT_CONSOLE_MODE" = "tmux" ]; then
    while :; do xcat_doxcat_session; done
else
    while :; do doxcat; sleep 5; done
fi
