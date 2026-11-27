#!/usr/bin/env bats
#
# The storage readers of xcat-storage check what zpool, gpart and zdb report after the
# installer creates the pool. They run on stubs that answer only query commands; the
# destructive dispatcher of xcat-storage is not entered.

load 'helpers/freebsd'

GENERATION=cccccccccccccccccccccccccccccccc
GUID=18446744073709551610

setup()
{
    DIR="$(freebsd_installer_dir)"
    ROOT="$BATS_TEST_TMPDIR"
    mkdir -p "$ROOT/work"
    : >"$ROOT/readers.sh"
    local name
    for name in storage_pool storage_table storage_labels; do
        extract_shell_function "$DIR/xcat-storage" "$name" >>"$ROOT/readers.sh" ||
            { echo "xcat-storage has no $name()" >&2; return 1; }
    done
    stub zpool 'case "$*" in
        "list -H -o name,guid") cat "$FIXTURE_DIR/pools" ;;
        "status -LP zroot") cat "$FIXTURE_DIR/status" ;;
        *) exit 90 ;;
        esac'
    stub zfs 'case "$*" in
        "get -Hp -o value special_small_blocks zroot") printf "4096\n" ;;
        "get -H -o value compression zroot") printf "lz4\n" ;;
        *) exit 90 ;;
        esac'
    stub zdb 'case "$*" in
        "-C zroot") printf "    ashift: 12\n" ;;
        "-l /dev/ada7p1") cat "$FIXTURE_DIR/cache-label" ;;
        *) exit 90 ;;
        esac'
    stub gpart 'test "$*" = "list -a" || exit 90; cat "$FIXTURE_DIR/partitions"'
    stub stat 'test "$*" = "-f %HT:%r /dev/ada2p1" || exit 90; printf "Character Device:302\n"'
    printf '%s\n' "$GUID" >"$ROOT/work/guid"
    printf 'zroot\t%s\n' "$GUID" >"$ROOT/pools"
    write_status
    write_table
    write_cache
}

teardown()
{
    # Every case uses query commands only.
    ! grep -qE '^(zpool (create|destroy|remove|labelclear)|gpart (create|destroy|add|modify))' \
        "$ROOT/events" 2>/dev/null
}

# edit <file> <sed expression>: the fixture must change, or the rejection would prove nothing.
edit()
{
    cp "$1" "$1.before"
    sed -i -e "$2" "$1"
    ! cmp -s "$1" "$1.before"
}

stub()
{
    freebsd_stub "$ROOT/bin/$1" <<STUB
#!/bin/sh
printf '%s %s\n' '$1' "\$*" >> "\$FIXTURE_DIR/events"
$2
STUB
}

write_status()
{
    local g="$GENERATION"
    cat >"$ROOT/status" <<STATUS
  pool: zroot
 state: ONLINE
config:

        NAME                                           STATE     READ WRITE CKSUM
        zroot                                          ONLINE       0     0     0
          mirror-0                                     ONLINE       0     0     0
            /dev/gpt/z${g}0                   ONLINE       0     0     0
            /dev/gpt/z${g}1                   ONLINE       0     0     0
        special
          mirror-1                                     ONLINE       0     0     0
            /dev/gpt/a${g}0                   ONLINE       0     0     0
            /dev/gpt/a${g}1                   ONLINE       0     0     0
        logs
          /dev/gpt/a${g}2                     ONLINE       0     0     0
          mirror-3                                     ONLINE       0     0     0
            /dev/gpt/a${g}3                   ONLINE       0     0     0
            /dev/gpt/a${g}4                   ONLINE       0     0     0
        cache
          /dev/gpt/a${g}5                     ONLINE       0     0     0

errors: No known data errors
STATUS
}

write_table()
{
    cat >"$ROOT/partitions" <<'TABLE'
Geom name: ada2
scheme: GPT
state: OK
modified: false
first: 34
last: 16777182
entries: 128
Providers:
1. Name: ada2p1
   Mediasize: 8587837440
   Sectorsize: 512
   Mode: r1w1e2
   offset: 1048576
   index: 1
   type: freebsd-zfs
   label: special-a
   rawuuid: 12345678-1234-1234-1234-123456789012
Consumers:
1. Name: ada2
TABLE
}

write_cache()
{
    cat >"$ROOT/cache-label" <<CACHE
LABEL 0
    version: 5000
    state: 4
    guid: 18331623171503817866
    ashift: 12
    path: '/dev/gpt/a${GENERATION}5'
    labels = 0 1 2 3
L2ARC device header
    magic: 6504978260106102853
    version: 1
    pool_guid: $GUID
    flags: 1
CACHE
}

# reader <function> [args]: sets status and output.
reader()
{
    PATH="$ROOT/bin:$PATH" FIXTURE_DIR="$ROOT" \
        storage_work="$ROOT/work" storage_guid="$GUID" storage_phase=created \
        storage_boot=BIOS storage_root_index=2 \
        storage_members="ada0	SERIAL0	1
ada1	SERIAL1	1" \
        storage_snapshot="ada2	SERIAL2	special:1	8589934592	512	r0w0e0	102" \
        storage_all_members="ada7	SERIAL7	cache:1" \
        XCAT_FORMAT=xcat-freebsd-install-6 XCAT_FILESYSTEM=zfs \
        XCAT_SWAP_SIZE=0 XCAT_SWAP_MODE=none XCAT_GENERATION="$GENERATION" \
        XCAT_ZFS_TOPOLOGY=mirror XCAT_ZFS_VDEVS='ada0@SERIAL0,ada1@SERIAL1' \
        XCAT_ZFS_SPECIAL_VDEVS='ada2@SERIAL2,ada3@SERIAL3' \
        XCAT_ZFS_LOG_VDEVS='ada4@SERIAL4,ada5@SERIAL5;ada6@SERIAL6' \
        XCAT_ZFS_CACHE_VDEVS='ada7@SERIAL7' XCAT_ZFS_SPECIAL_SMALL_BLOCKS=4096 \
        XCAT_ZFS_COMPRESSION=lz4 XCAT_ZFS_ASHIFT=12 \
        run sh -c 'set -eu; . "$1"; . "$2"; shift 2; "$@" 2>"$FIXTURE_DIR/stderr"' \
            sh "$DIR/xcat-install-lib.sh" "$ROOT/readers.sh" "$@"
}


@test "the configured special mirror, single log, mirrored log and cache pass pool readback" {
    reader storage_pool
    [ "$status" -eq 0 ]
}

@test "pool readback rejects a missing special group" {
    edit "$ROOT/status" '/^        special$/d'
    reader storage_pool
    [ "$status" -ne 0 ]
}

@test "pool readback rejects a wrong group type" {
    edit "$ROOT/status" 's/mirror-3/raidz1-3/'
    reader storage_pool
    [ "$status" -ne 0 ]
}

@test "pool readback rejects a raw device path" {
    edit "$ROOT/status" "s|/dev/gpt/a${GENERATION}3|/dev/ada4p1|"
    reader storage_pool
    [ "$status" -ne 0 ]
}

@test "pool readback rejects a member in the wrong group" {
    edit "$ROOT/status" "s|/dev/gpt/a${GENERATION}2 |/dev/gpt/a${GENERATION}4 |"
    reader storage_pool
    [ "$status" -ne 0 ]
}

@test "pool readback rejects I/O errors" {
    edit "$ROOT/status" '0,/ONLINE       0     0     0/s//ONLINE 0 1 0/'
    reader storage_pool
    [ "$status" -ne 0 ]
}

@test "partition readback returns the GPT-label provider" {
    reader storage_table 1
    [ "$status" -eq 0 ]
    [[ "$output" == *$'P\tada2\t1\tada2p1\tfreebsd-zfs\t'* ]]
}

@test "partition readback requires the stable-label open mode" {
    local mode
    for mode in r1w1e1 r0w0e0; do
        write_table
        edit "$ROOT/partitions" "s/r1w1e2/$mode/"
        reader storage_table 1
        [ "$status" -ne 0 ]
    done
}

@test "cache readback returns the native cache vdev identity" {
    reader storage_labels 0
    [ "$status" -eq 0 ]
    [ "$output" = "ada7	$GUID	-	18331623171503817866" ]
}

@test "cache readback rejects a foreign owner, a missing and a duplicate label copy" {
    local change
    for change in "s/$GUID/18446744073709551611/g" 's/labels = 0 1 2 3/labels = 0 1 2/' 's/labels = 0 1 2 3/labels = 0 1 2 2/'; do
        write_cache
        edit "$ROOT/cache-label" "$change"
        reader storage_labels 0
        [ "$status" -ne 0 ]
    done
}
