#!/usr/bin/env bats
#
# The stateless relabel hook must tell "nothing to do" apart from "wanted and did not
# happen". It returned 0 on every path, so a node booted with an unlabelled root and
# nothing said so: /etc/ld.so.cache kept tmpfs_t and every domain that execs was denied.

HOOK="${BATS_TEST_DIRNAME}/../../xCAT-server/share/xcat/netboot/rh/dracut_047/xcat-selinux-relabel.sh"

setup() {
    NEWROOT="$BATS_TEST_TMPDIR/newroot"
    mkdir -p "$NEWROOT/etc/selinux/targeted/contexts/files" \
             "$NEWROOT/usr/sbin" "$NEWROOT/proc" "$NEWROOT/sys"
    export NEWROOT
    export XCAT_SELINUX_RELABEL_MARKER=/etc/xcat-selinux-relabel-failed
    xcat_sfs_image="$BATS_TEST_TMPDIR/absent.sfs"

    WARNINGS="$BATS_TEST_TMPDIR/warnings"
    CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$WARNINGS"
    : >"$CALLS"

    warn()   { echo "$*" >>"$WARNINGS"; }
    mount()  { echo "mount $*" >>"$CALLS"; return "${STUB_MOUNT_RC:-0}"; }
    umount() { echo "umount $*" >>"$CALLS"; return 0; }
    chroot() { echo "chroot $*" >>"$CALLS"; return "${STUB_SETFILES_RC:-0}"; }
    # Sourcing runs the hook once. Make that run the cheap no-op path.
    getarg() { return 0; }

    . "$HOOK"
}

# The image wants a label: config present, contexts present, setfiles present.
wants_label() {
    printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' >"$NEWROOT/etc/selinux/config"
    : >"$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts"
    printf '#!/bin/sh\n' >"$NEWROOT/usr/sbin/setfiles"
    chmod +x "$NEWROOT/usr/sbin/setfiles"
    getarg() { return 1; }
}

marker() { cat "$NEWROOT/etc/xcat-selinux-relabel-failed" 2>/dev/null; }

@test "selinux=0 on the command line is nothing to do, not a failure" {
    wants_label
    getarg() { return 0; }
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [ -z "$(marker)" ]
}

# A squashfs root was skipped unconditionally, on the stated ground that a relabel
# "would copy every file to the overlay". Measured: 153 inodes of 27232, and skipping it
# left /etc/ld.so.cache at tmpfs_t with 175 denial records across 23 domains.
@test "a squashfs root is relabelled like any other, not skipped" {
    wants_label
    : >"$BATS_TEST_TMPDIR/absent.sfs"
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [[ "$(cat "$CALLS")" == *"setfiles -F"* ]]
}

@test "an image with no selinux config is nothing to do" {
    wants_label
    rm -f "$NEWROOT/etc/selinux/config"
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [ -z "$(marker)" ]
}

@test "SELINUX=disabled is nothing to do" {
    wants_label
    printf 'SELINUX=disabled\n' >"$NEWROOT/etc/selinux/config"
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [ -z "$(marker)" ]
}

@test "missing file_contexts is a failure, not a pass" {
    wants_label
    rm -f "$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts"
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"file_contexts is not in the image"* ]]
    [[ "$(cat "$WARNINGS")" == *"not labelled"* ]]
}

@test "the policy type from the config picks the file_contexts path" {
    wants_label
    printf 'SELINUX=enforcing\nSELINUXTYPE=mls\n' >"$NEWROOT/etc/selinux/config"
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"/etc/selinux/mls/contexts/files/file_contexts"* ]]
}

@test "an image with no setfiles is a failure, not a pass" {
    wants_label
    rm -f "$NEWROOT/usr/sbin/setfiles"
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"no setfiles"* ]]
}

@test "setfiles returning non-zero is a failure, and the status is named" {
    wants_label
    STUB_SETFILES_RC=126
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"setfiles returned 126"* ]]
}

@test "a failing setfiles still unmounts proc and sys" {
    wants_label
    STUB_SETFILES_RC=1
    run xcat_selinux_relabel
    [[ "$(cat "$CALLS")" == *"umount $NEWROOT/sys"* ]]
    [[ "$(cat "$CALLS")" == *"umount $NEWROOT/proc"* ]]
}

@test "a mount that fails is a failure, and setfiles is not run" {
    wants_label
    STUB_MOUNT_RC=1
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"cannot mount /proc"* ]]
    [[ "$(cat "$CALLS")" != *"chroot"* ]]
}

@test "the config is read without tail, which the initramfs does not carry" {
    wants_label
    printf 'SELINUX=disabled\nSELINUXTYPE=targeted\n' >"$NEWROOT/etc/selinux/config"
    tail() { echo "tail: command not found" >&2; return 127; }
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [[ "$(cat "$CALLS")" != *"setfiles"* ]]
}

@test "the last assignment in the config wins, with no tail" {
    wants_label
    printf 'SELINUXTYPE=targeted\nSELINUXTYPE=mls\n' >"$NEWROOT/etc/selinux/config"
    tail() { echo "tail: command not found" >&2; return 127; }
    run xcat_selinux_relabel
    [ "$status" -ne 0 ]
    [[ "$(marker)" == *"/etc/selinux/mls/contexts/files/file_contexts"* ]]
}

@test "a relabel that works returns 0 and leaves no marker" {
    wants_label
    echo "stale" >"$NEWROOT/etc/xcat-selinux-relabel-failed"
    run xcat_selinux_relabel
    [ "$status" -eq 0 ]
    [ -z "$(marker)" ]
    [[ "$(cat "$CALLS")" == *"setfiles -F -e /proc -e /sys -e /dev"* ]]
}
