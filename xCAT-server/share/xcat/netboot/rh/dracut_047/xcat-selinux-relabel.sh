#!/bin/sh
# Label the stateless root with the policy of the image. dracut 98selinux loads that
# policy at pre-pivot 50, and systemd cannot start from an unlabelled tmpfs root.

# A squashfs root needs this as much as a cpio root. The directories dracut creates
# before the policy loads carry the tmpfs default, children inherit it, and the node
# then denies every exec once: a measured boot kept /etc/ld.so.cache at tmpfs_t and
# logged 175 records across 23 domains. The relabel copies up 153 inodes of 27232.

# A relabel that was wanted and did not happen must not report success. Nothing to do
# returns 0; a failure returns non-zero and names itself in the marker. The marker is
# in /etc and not /run, because systemd mounts a fresh tmpfs over /run and hides it.
XCAT_SELINUX_RELABEL_MARKER=${XCAT_SELINUX_RELABEL_MARKER:-/etc/xcat-selinux-relabel-failed}

xcat_selinux_relabel_failed()
{
    local reason="$1"

    warn "xCAT: the stateless root is not labelled: $reason"
    echo "$reason" >"$NEWROOT$XCAT_SELINUX_RELABEL_MARKER" 2>/dev/null
    return 1
}

# The initramfs has no tail. sed is there, so take the last match with sed itself.
xcat_selinux_config_value()
{
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | sed -n '$p'
}

xcat_selinux_relabel()
{
    getarg selinux=0 >/dev/null && return 0

    local config="$NEWROOT/etc/selinux/config" mode type fc setfiles rc
    [ -r "$config" ] || return 0
    mode=$(xcat_selinux_config_value SELINUX "$config")
    [ "$mode" = disabled ] && return 0
    type=$(xcat_selinux_config_value SELINUXTYPE "$config")
    fc="/etc/selinux/${type:-targeted}/contexts/files/file_contexts"

    # From here the image asks for a labelled root, so every exit is a verdict.
    if [ ! -r "$NEWROOT$fc" ]; then
        xcat_selinux_relabel_failed "$fc is not in the image"
        return 1
    fi

    setfiles=/usr/sbin/setfiles
    [ -x "$NEWROOT$setfiles" ] || setfiles=/sbin/setfiles
    if [ ! -x "$NEWROOT$setfiles" ]; then
        xcat_selinux_relabel_failed "the image carries no setfiles"
        return 1
    fi

    if ! mount -t proc proc "$NEWROOT/proc"; then
        xcat_selinux_relabel_failed "cannot mount /proc under the new root"
        return 1
    fi
    if ! mount --bind /sys "$NEWROOT/sys"; then
        umount "$NEWROOT/proc"
        xcat_selinux_relabel_failed "cannot bind /sys under the new root"
        return 1
    fi
    chroot "$NEWROOT" "$setfiles" -F -e /proc -e /sys -e /dev "$fc" /
    rc=$?
    umount "$NEWROOT/sys"
    umount "$NEWROOT/proc"
    if [ "$rc" -ne 0 ]; then
        xcat_selinux_relabel_failed "setfiles returned $rc"
        return 1
    fi

    rm -f "$NEWROOT$XCAT_SELINUX_RELABEL_MARKER"
    return 0
}

xcat_selinux_relabel
