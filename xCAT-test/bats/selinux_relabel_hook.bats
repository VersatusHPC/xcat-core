#!/usr/bin/env bats
#
# Source the pre-pivot hook that labels a stateless root, as dracut does. getarg, warn,
# mount, umount and chroot are dracut and initramfs commands, so shadow them with functions.

load 'helpers/shell_source'

HOOKS=(
    'xCAT-server/share/xcat/netboot/rh/dracut_047/xcat-selinux-relabel.sh'
    'xCAT-server/share/xcat/netboot/rh/dracut_105/stateless/xcat-selinux-relabel.sh'
)

setup()
{
    NEWROOT="${BATS_TEST_TMPDIR}/sysroot"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    CMDLINE=''
    xcat_sfs_image="${BATS_TEST_TMPDIR}/rootimg.sfs"
    mkdir -p "$NEWROOT/etc/selinux/targeted/contexts/files" "$NEWROOT/usr/sbin" "$NEWROOT/proc" "$NEWROOT/sys"
    : >"$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts"
    : >"$NEWROOT/usr/sbin/setfiles"
    chmod 0755 "$NEWROOT/usr/sbin/setfiles"
    write_config enforcing targeted
    : >"$CALLS"
}

write_config()
{
    printf 'SELINUX=%s\nSELINUXTYPE=%s\n' "$1" "$2" >"$NEWROOT/etc/selinux/config"
}

getarg()
{
    local arg
    for arg in $CMDLINE; do
        [ "$arg" = "$1" ] && return 0
    done
    return 1
}

warn() { echo "warn: $*" >>"$CALLS"; }
mount() { :; }
umount() { :; }
chroot() { echo "chroot $*" >>"$CALLS"; }

source_hook()
{
    # dracut sources every hook into its own shell.
    . "$(repo_path "$1")"
}

@test "selinux=0 on the kernel command line runs no setfiles" {
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        CMDLINE='root=1 selinux=0 quiet'
        source_hook "$hook"
        run cat "$CALLS"
        [ -z "$output" ]
    done
}

@test "an enforcing node runs setfiles once with the file_contexts of the image" {
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        CMDLINE='root=1 quiet'
        source_hook "$hook"
        run grep -c '^chroot ' "$CALLS"
        [ "$output" = 1 ]
        run cat "$CALLS"
        [ "$output" = "chroot $NEWROOT /usr/sbin/setfiles -F -e /proc -e /sys -e /dev /etc/selinux/targeted/contexts/files/file_contexts /" ]
    done
}

@test "a permissive node also runs setfiles" {
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        CMDLINE='root=1 enforcing=0'
        source_hook "$hook"
        run grep -c '^chroot .*/usr/sbin/setfiles' "$CALLS"
        [ "$output" = 1 ]
    done
}

@test "the file_contexts follows SELINUXTYPE of the image" {
    mkdir -p "$NEWROOT/etc/selinux/mls/contexts/files"
    : >"$NEWROOT/etc/selinux/mls/contexts/files/file_contexts"
    write_config enforcing mls
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        source_hook "$hook"
        run cat "$CALLS"
        [[ "$output" == *" /etc/selinux/mls/contexts/files/file_contexts /" ]]
    done
}

# The hook used to return before it did anything for a squashfs root, because a relabel
# "would copy every file to the overlay". Measured on an el10 node: 153 inodes of 27232,
# 0.85 s. The skip left /etc/ld.so.cache at tmpfs_t and the boot logged 175 denials.
@test "a squashfs root is relabelled like any other" {
    : >"$xcat_sfs_image"
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        source_hook "$hook"
        run grep -c '^chroot ' "$CALLS"
        [ "$output" = 1 ]
    done
}

@test "an image configured with SELINUX=disabled runs no setfiles" {
    write_config disabled targeted
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        source_hook "$hook"
        run grep -c '^chroot ' "$CALLS"
        [ "$output" = 0 ]
    done
}

# An image that asks for a label and does not get one is a failure, not a quiet pass:
# the hook returns non-zero and names the reason where userspace can read it.
@test "an image without file_contexts warns, runs no setfiles and reports a failure" {
    rm -f "$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts"
    for hook in "${HOOKS[@]}"; do
        : >"$CALLS"
        rm -f "$NEWROOT/etc/xcat-selinux-relabel-failed"
        run source_hook "$hook"
        [ "$status" -ne 0 ]
        run grep -c '^chroot ' "$CALLS"
        [ "$output" = 0 ]
        run grep -c '^warn: .*file_contexts' "$CALLS"
        [ "$output" = 1 ]
        run cat "$NEWROOT/etc/xcat-selinux-relabel-failed"
        [[ "$output" == *"file_contexts is not in the image"* ]]
    done
}
