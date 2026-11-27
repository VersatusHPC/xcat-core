#!/usr/bin/env bats
#
# Drive xcat_make_loop0() out of the Ubuntu diskless dracut hook with mknod shadowed.
# The hook cannot be sourced: it mounts the root image and switches to it.

load 'helpers/shell_source'

setup()
{
    HOOK="$(require_repo_file 'xCAT-server/share/xcat/netboot/ubuntu/dracut/xcatroot')"
    MKNOD_LOG="$BATS_TEST_TMPDIR/mknod.log"
    LOOP0="$BATS_TEST_TMPDIR/loop0"
    export HOOK MKNOD_LOG LOOP0
}

make_loop0()
{
    local body
    body="$(extract_shell_function "$HOOK" xcat_make_loop0)" ||
        { echo "xcat_make_loop0() not found in $HOOK" >&2; return 99; }
    (
        eval "$body"
        mknod() {
            echo "$*" >> "$MKNOD_LOG"
            if [ -e "$1" ]; then
                echo "mknod: $1: File exists" >&2
                return 1
            fi
            : > "$1"
        }
        xcat_make_loop0 "$LOOP0"
    ) 2>&1
}

# udev on Ubuntu 22.04 and 26.04 creates /dev/loop0 before the hook runs.
@test "an existing loop0 node is kept and mknod prints no error" {
    : > "$LOOP0"
    run make_loop0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$MKNOD_LOG" ]
}

@test "a missing loop0 node is created as block device 7:0" {
    run make_loop0
    [ "$status" -eq 0 ]
    [ "$(cat "$MKNOD_LOG")" = "$LOOP0 b 7 0" ]
}
