#!/usr/bin/env bats
#
# patch-bsdinstall-umount.sh turns the native FreeBSD 15.1 bsdinstall umount
# helper into one that accepts an fstab with no mount entries.

load 'helpers/freebsd'

setup()
{
    HELPER="$(freebsd_installer_dir)/patch-bsdinstall-umount.sh"
    NATIVE="$(repo_path 'xCAT-test/bats/fixtures/freebsd15.1-bsdinstall-umount')"
    ROOT="$BATS_TEST_TMPDIR"
    freebsd_stub "$ROOT/bin/sha256" <<'STUB'
#!/bin/sh
openssl dgst -sha256 -r "$2" | awk '{print $1}'
STUB
    freebsd_stub "$ROOT/bin/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FIXTURE_DIR/events"
if [ "$1" = -F ]; then
    cp "$2" "$FIXTURE_DIR/unmount-fstab"
    [ -s "$2" ] || exit 1
    exit "${FSTAB_UMOUNT_STATUS:-0}"
fi
exit "${DEVFS_UMOUNT_STATUS:-0}"
STUB
    PATH="$ROOT/bin:$PATH"
    export PATH
}

patched()
{
    sh "$HELPER" "$NATIVE" >"$ROOT/patched"
}

# cleanup_case <script> <fstab> <fstab-umount-status> <packages> [missing_input|bad_output] [devfs-status]
# Sets CASE, STATUS and EVENTS.
cleanup_case()
{
    local script="$1" fstab="$2" error="$3" packages="$4" failure="${5:-}" devfs="${6:-0}"
    CASE="$(mktemp -d "$ROOT/case.XXXXXX")"
    mkdir -p "$CASE/target/dev" "$CASE/tmp"
    [ "$packages" = 1 ] && mkdir -p "$CASE/target/dist/packages"
    [ "$failure" = missing_input ] || printf '%b' "$fstab" >"$CASE/fstab"
    local tmpdir="$CASE/tmp"
    [ "$failure" = bad_output ] && tmpdir="$CASE/missing"
    STATUS=0
    FIXTURE_DIR="$CASE" BSDINSTALL_CHROOT="$CASE/target" PATH_FSTAB="$CASE/fstab" \
        TMPDIR="$tmpdir" FSTAB_UMOUNT_STATUS="$error" DEVFS_UMOUNT_STATUS="$devfs" \
        sh "$script" >"$CASE/output" 2>&1 || STATUS=$?
    EVENTS="$(read_file_or_empty "$CASE/events")"
}

@test "the fixture is the pinned native FreeBSD 15.1 cleanup helper" {
    run sha256sum "$NATIVE"
    [ "${output%% *}" = 624ae8e292566b28bb6c5a37d14c6e98f06c1fe9b77712cf195982dfc0f9dec0 ]
}

@test "the build helper accepts the native source and writes valid shell" {
    sh -n "$HELPER"
    patched
    sh -n "$ROOT/patched"
}

@test "the build helper rejects source drift, a missing helper and missing arguments" {
    { cat "$NATIVE"; echo; } >"$ROOT/changed"
    run sh "$HELPER" "$ROOT/changed"
    [ "$status" -ne 0 ]
    [[ "$output" == *'Unsupported FreeBSD 15.1 bsdinstall umount checksum'* ]]
    run sh "$HELPER" "$ROOT/missing"
    [ "$status" -ne 0 ]
    run sh "$HELPER"
    [ "$status" -eq 2 ]
}

@test "an fstab without mount entries unmounts devfs only" {
    patched
    local fstab
    for fstab in '' '# Device Mountpoint FStype Options Dump Pass#\n' '/dev/ada0p2 none swap sw 0 0\n'; do
        cleanup_case "$ROOT/patched" "$fstab" 0 0
        [ "$STATUS" -eq 0 ]
        [ "$EVENTS" = "$CASE/target/dev" ]
        [ ! -s "$CASE/tmp/bsdinstall-tmp-fstab" ]
    done
}

@test "the unfixed native helper fails on an empty fstab" {
    cleanup_case "$NATIVE" '' 0 0
    [ "$STATUS" -eq 1 ]
    [[ "$EVENTS" =~ (^|$'\n')-F\ .*\ -a($|$'\n') ]]
}

@test "a missing input or output fails before any unmount" {
    patched
    local failure
    for failure in missing_input bad_output; do
        cleanup_case "$ROOT/patched" '' 0 0 "$failure"
        [ "$STATUS" -ne 0 ]
        [ -z "$EVENTS" ]
    done
}

@test "a devfs failure stops before the other unmounts" {
    patched
    local fstab
    for fstab in '' '/dev/ada0p1 /boot/efi msdosfs rw 2 2\n'; do
        cleanup_case "$ROOT/patched" "$fstab" 0 0 '' 42
        [ "$STATUS" -ne 0 ]
        [ "$EVENTS" = "$CASE/target/dev" ]
    done
}

@test "a non-empty fstab keeps the unmount status and prefixes the target root" {
    patched
    local error
    for error in 0 7; do
        cleanup_case "$ROOT/patched" '/dev/ada0p1 /boot/efi msdosfs rw 2 2\n' "$error" 0
        [ "$STATUS" -eq "$error" ]
        [ "$EVENTS" = "$CASE/target/dev"$'\n'"-F $CASE/tmp/bsdinstall-tmp-fstab -a" ]
        grep -qF "$CASE/target/boot/efi"$'\t'"msdosfs"$'\t' "$CASE/unmount-fstab"
        cleanup_case "$ROOT/patched" '/dev/ada0p3 / ufs rw 1 1\n' "$error" 0
        [ "$STATUS" -eq "$error" ]
        grep -qF "$CASE/target"$'\t'"ufs"$'\t' "$CASE/unmount-fstab"
    done
}

@test "an empty fstab still unmounts and removes the package media" {
    patched
    cleanup_case "$ROOT/patched" '' 0 1
    [ "$STATUS" -eq 0 ]
    [ "$EVENTS" = "$CASE/target/dist/packages"$'\n'"$CASE/target/dev" ]
    [ ! -e "$CASE/target/dist" ]
}
