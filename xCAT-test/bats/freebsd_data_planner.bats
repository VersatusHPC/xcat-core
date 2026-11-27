#!/usr/bin/env bats
#
# configzfs-freebsd.awk compiles a data-pool policy into a create plan, verifies the
# native zpool status against that plan, and reads the startup pool cache.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

setup()
{
    PLANNER="${XCAT_FREEBSD_DATA_PLANNER:-$(repo_path 'xCAT/postscripts/configzfs-freebsd.awk')}"
    FIXTURES="$(repo_path 'xCAT-test/bats/fixtures')"
    D="$BATS_TEST_TMPDIR"
}

# compile [key=value ...]: the base mirrored pool with the overrides applied.
compile()
{
    declare -A p=([format]=xcat-freebsd-data-1 [action]=create [pool]=tank
        [os_disks]='vtbd0@OS0,vtbd1@OS1' [topology]=mirror [vdevs]='vtbd2@DATA2,vtbd3@DATA3')
    local kv k
    for kv in "$@"; do p[${kv%%=*}]=${kv#*=}; done
    for k in "${!p[@]}"; do printf '%s=%s\n' "$k" "${p[$k]}"; done | LC_ALL=C sort >"$D/policy"
    run --separate-stderr awk -f "$PLANNER" "$D/policy"
}

# The C rows of the last plan, one argument per word.
creates() { grep $'^C\t' <<<"$output" | cut -f2 | paste -sd' '; }
setting() { awk -F '\t' -v k="$1" '$1 == "K" && $2 == k { print $3 }' <<<"$output"; }

# verify <plan> <status file>
verify() { run --separate-stderr awk -f "$PLANNER" -v mode=verify "$1" "$2"; }
cache()  { printf '%b' "$1" >"$D/cache"; run --separate-stderr awk -f "$PLANNER" -v mode=cache "$D/cache"; }

# mutate <perl substitution> <in> <out>: the fixture must change.
mutate() { perl -0pe "$1" "$2" >"$3"; ! cmp -s "$2" "$3"; }

status_fixture()
{
    printf '  pool: tank\n state: ONLINE\nconfig:\n\n'
    printf '\tNAME                 STATE     READ WRITE CKSUM\n'
    printf '\ttank                 ONLINE       0     0     0\n'
    printf '\t  mirror-0           ONLINE       0     0     0\n'
    printf '\t    /dev/vtbd2       ONLINE       0     0     0\n'
    printf '\t    /dev/vtbd3       ONLINE       0     0     0\n'
    printf '\nerrors: No known data errors\n'
}

@test "a dedicated mirrored pool compiles with explicit defaults" {
    compile
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    local k want
    for want in format=xcat-freebsd-data-1 action=create pool=tank guid=- compression=lz4 ashift=12 \
        special_small_blocks=0 encryption=off keyfile=- mountpoint=/data/tank; do
        [ "$(setting "${want%%=*}")" = "${want#*=}" ]
    done
    [ "$(grep -c $'^K\t' <<<"$output")" -eq 10 ]
    [ "$(creates)" = 'mirror /dev/vtbd2 /dev/vtbd3' ]
    printf '%s\n' "$output" >"$D/plan"
    status_fixture >"$D/status"
    verify "$D/plan" "$D/status"
    [ "$status" -eq 0 ]
}

@test "an import keeps a full-width pool GUID" {
    compile action=import guid=18446744073709551615 encryption=aes-256-gcm keyfile=/etc/xcat/keys/tank.key
    [ "$status" -eq 0 ]
    [ "$(setting guid)" = 18446744073709551615 ]
}

@test "auxiliary devices keep separate roles and mixed log groups" {
    compile log_vdevs='vtbd4@LOG4,vtbd5@LOG5;vtbd6@LOG6' cache_vdevs='vtbd7@CACHE7,vtbd8@CACHE8' \
        special_vdevs='vtbd9@SPECIAL9,vtbd10@SPECIAL10' special_small_blocks=65536
    [ "$status" -eq 0 ]
    [ "$(creates)" = 'mirror /dev/vtbd2 /dev/vtbd3 special mirror /dev/vtbd9 /dev/vtbd10 log /dev/vtbd6 mirror /dev/vtbd4 /dev/vtbd5 cache /dev/vtbd7 /dev/vtbd8' ]
    printf '%s\n' "$output" >"$D/plan"
    verify "$D/plan" "$FIXTURES/freebsd15.1-zpool-mixed-logs"
    [ "$status" -eq 0 ]
    verify "$D/plan" "$FIXTURES/freebsd15.1-zpool-merged-logs"
    [ "$status" -ne 0 ]
    mutate 's/\tcache\n/\tlogs\n/' "$FIXTURES/freebsd15.1-zpool-mixed-logs" "$D/wrong"
    verify "$D/plan" "$D/wrong"
    [ "$status" -ne 0 ]
}

@test "an invalid policy emits no partial create plan" {
    local change
    for change in action= action=destroy pool=zroot 'pool=tank;reboot' \
        vdevs=vtbd0@OS0,vtbd3@DATA3 vdevs=vtbd2@OS0,vtbd3@DATA3 vdevs=diskid/DISK-DATA2@DATA2,vtbd3@DATA3 \
        vdevs=vtbd2@DATA2 os_disks=- os_disks= log_vdevs=vtbd2@DATA2 topology=draid1 topology=raid10 \
        compression=on compression=zstd-20 ashift=8 ashift=17 special_small_blocks=65536 \
        special_vdevs=vtbd4@SPECIAL4 special_small_blocks=12345 encryption=aes-256-gcm encryption=prompt \
        keyfile=/etc/xcat/keys/tank.key mountpoint=/data/../etc mountpoint=/ unsupported=yes; do
        compile "$change"
        [ "$status" -ne 0 ] || { echo "accepted $change"; return 1; }
        [ -z "$output" ]
        [[ "$stderr" == *configzfs:* ]]
    done
    for change in 'guid=18446744073709551616' 'guid=0' ''; do
        compile action=import ${change:+"$change"}
        [ "$status" -ne 0 ] || { echo "accepted import $change"; return 1; }
        [ -z "$output" ]
    done
}

@test "a special block size must be a power of two" {
    compile special_vdevs=vtbd4@SPECIAL4,vtbd5@SPECIAL5 special_small_blocks=65536
    [ "$status" -eq 0 ]
    compile special_vdevs=vtbd4@SPECIAL4,vtbd5@SPECIAL5 special_small_blocks=12345
    [ "$status" -ne 0 ]
    [[ "$stderr" == *'power of two'* ]]
}

@test "duplicate, control-character or oversized input emits no plan" {
    local bytes
    for bytes in 'format=xcat-freebsd-data-1\nformat=xcat-freebsd-data-1\n' 'pool=tank\t\n'; do
        printf "$bytes" >"$D/malformed"
        run --separate-stderr awk -f "$PLANNER" "$D/malformed"
        [ "$status" -ne 0 ]
        [ -z "$output" ]
    done
    head -c 32769 /dev/zero | tr '\0' x >"$D/malformed"
    run --separate-stderr awk -f "$PLANNER" "$D/malformed"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "special devices must match the data redundancy of each topology" {
    local spec topology vdevs n roles special i
    for spec in 'mirror|vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4|3|mirror /dev/vtbd2 /dev/vtbd3 /dev/vtbd4' \
        'raid10|vtbd2@DATA2,vtbd3@DATA3;vtbd4@DATA4,vtbd5@DATA5|2|mirror /dev/vtbd2 /dev/vtbd3 mirror /dev/vtbd4 /dev/vtbd5' \
        'raidz1|vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4|2|raidz1 /dev/vtbd2 /dev/vtbd3 /dev/vtbd4' \
        'raidz2|vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4,vtbd5@DATA5|3|raidz2 /dev/vtbd2 /dev/vtbd3 /dev/vtbd4 /dev/vtbd5' \
        'raidz3|vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4,vtbd5@DATA5,vtbd6@DATA6|4|raidz3 /dev/vtbd2 /dev/vtbd3 /dev/vtbd4 /dev/vtbd5 /dev/vtbd6'; do
        IFS='|' read -r topology vdevs n roles <<<"$spec"
        special='' ; local devs=''
        for i in $(seq 1 "$n"); do special="$special${special:+,}vtbd$((20 + i))@SPECIAL$i"; devs="$devs /dev/vtbd$((20 + i))"; done
        compile topology="$topology" vdevs="$vdevs" special_vdevs="$special"
        [ "$status" -eq 0 ]
        [ "$(creates)" = "$roles special mirror${devs}" ]
        compile topology="$topology" vdevs="$vdevs" special_vdevs="$special,vtbd30@SPECIAL30"
        [ "$status" -ne 0 ]
        compile topology="$topology" vdevs="$vdevs" special_vdevs="${special%,*}"
        [ "$status" -ne 0 ]
    done
    compile topology=stripe vdevs=vtbd2@DATA2
    [ "$status" -eq 0 ]
    compile topology=stripe vdevs=vtbd2@DATA2 special_vdevs=vtbd3@SPECIAL3,vtbd4@SPECIAL4
    [ "$status" -ne 0 ]
}

@test "compression and ashift agree with native property readback" {
    local compression ashift want
    for compression in off lz4 gzip gzip-1 gzip-6 gzip-9 zstd zstd-1 zstd-19; do
        for ashift in 9 12 16; do
            compile compression="$compression" ashift="$ashift"
            [ "$status" -eq 0 ]
            want=$compression; [ "$compression" = gzip-6 ] && want=gzip
            [ "$(setting compression)" = "$want" ]
            [ "$(setting ashift)" = "$ashift" ]
        done
    done
}

DRAID=(topology=draid2:4d:8c:2s vdevs=vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4,vtbd5@DATA5,vtbd6@DATA6,vtbd7@DATA7,vtbd8@DATA8,vtbd9@DATA9
    special_vdevs=vtbd10@SPECIAL10,vtbd11@SPECIAL11,vtbd12@SPECIAL12 log_vdevs=vtbd13@LOG13,vtbd14@LOG14
    cache_vdevs=vtbd15@CACHE15 encryption=aes-256-gcm keyfile=/etc/xcat/keys/tank.key special_small_blocks=65536)

@test "dRAID keeps its geometry, its roles and its distributed spares" {
    compile "${DRAID[@]}"
    [ "$status" -eq 0 ]
    [ "$(creates)" = 'draid2:4d:8c:2s /dev/vtbd2 /dev/vtbd3 /dev/vtbd4 /dev/vtbd5 /dev/vtbd6 /dev/vtbd7 /dev/vtbd8 /dev/vtbd9 special mirror /dev/vtbd10 /dev/vtbd11 /dev/vtbd12 log mirror /dev/vtbd13 /dev/vtbd14 cache /dev/vtbd15' ]
    printf '%s\n' "$output" >"$D/plan"
    verify "$D/plan" "$FIXTURES/freebsd15.1-zpool-draid"
    [ "$status" -eq 0 ]
    local change
    for change in 's/draid2:4d:8c:2s-0/draid1:4d:8c:2s-0/' 's/draid2:4d:8c:2s-0/draid2:3d:8c:2s-0/' \
        's/draid2:4d:8c:2s-0/draid2:4d:9c:2s-0/' 's/draid2:4d:8c:2s-0/draid2:4d:8c:1s-0/' \
        's/draid2-0-1/draid2-0-2/' 's/draid2-0-1/draid2-0-0/' 's/AVAIL/INUSE/' \
        's/\t\s+draid2-0-1[^\n]*\n//' 's{/dev/vtbd9}{/dev/vtbd1}'; do
        mutate "$change" "$FIXTURES/freebsd15.1-zpool-draid" "$D/wrong"
        verify "$D/plan" "$D/wrong"
        [ "$status" -ne 0 ] || { echo "accepted $change"; return 1; }
    done
}

@test "invalid dRAID geometry cannot reach pool creation" {
    local topology
    for topology in draid draid1 draid0:4d:8c:1s draid4:4d:8c:1s draid2:04d:8c:2s draid2:0d:8c:2s \
        draid2:4d:8c:3s draid2:4d:7c:1s draid2:4d:129c:1s; do
        compile "${DRAID[@]}" topology="$topology"
        [ "$status" -ne 0 ] || { echo "accepted $topology"; return 1; }
        [ -z "$output" ]
    done
}

@test "dRAID parity sets the special redundancy and each vdev its child count" {
    local parity special i
    for parity in 1 2 3; do
        compile "${DRAID[@]}" topology="draid$parity:3d:8c:1s" special_vdevs=- special_small_blocks=0
        [ "$status" -eq 0 ]
        special=''
        for i in $(seq 20 $((20 + parity))); do special="$special${special:+,}vtbd$i@SPECIAL$i"; done
        compile "${DRAID[@]}" topology="draid$parity:3d:8c:1s" special_vdevs="$special" special_small_blocks=0
        [ "$status" -eq 0 ]
        compile "${DRAID[@]}" topology="draid$parity:3d:8c:1s" special_vdevs="${special%,*}" special_small_blocks=0
        [ "$status" -ne 0 ]
    done
    local more='vtbd2@DATA2,vtbd3@DATA3,vtbd4@DATA4,vtbd5@DATA5,vtbd6@DATA6,vtbd7@DATA7,vtbd8@DATA8,vtbd9@DATA9;vtbd16@DATA16,vtbd17@DATA17,vtbd18@DATA18,vtbd19@DATA19,vtbd20@DATA20,vtbd21@DATA21,vtbd22@DATA22,vtbd23@DATA23'
    compile "${DRAID[@]}" special_vdevs=- special_small_blocks=0 log_vdevs=- cache_vdevs=- vdevs="$more"
    [ "$status" -eq 0 ]
    compile "${DRAID[@]}" special_vdevs=- special_small_blocks=0 log_vdevs=- cache_vdevs=- vdevs="${more%,*}"
    [ "$status" -ne 0 ]
}

@test "native topology and health must match the plan exactly" {
    compile
    printf '%s\n' "$output" >"$D/plan"
    status_fixture >"$D/status"
    local change
    for change in 's{/dev/vtbd3}{/dev/vtbd4}' 's/mirror-0/raidz1-0/' 's/ONLINE/DEGRADED/' \
        's/No known data errors/1 data error/' 's{\t\s+/dev/vtbd3[^\n]*\n}{}' 's/errors:[^\n]*//' \
        's{\t\s+/dev/vtbd2[^\n]*}{\t    /dev/vtbd2 ONLINE 0 1 0}'; do
        mutate "$change" "$D/status" "$D/wrong"
        verify "$D/plan" "$D/wrong"
        [ "$status" -ne 0 ] || { echo "accepted $change"; return 1; }
    done
}

NATIVE_CACHE='createproof:\n    pool_guid: 12448067557558924659\nzroot:\n    pool_guid: 6329292263267649316\ntank:\n    pool_guid: 5556949434698476598\n'

@test "the startup cache keeps every full-width pool identity once" {
    cache "$NATIVE_CACHE"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    local want=$'createproof\t12448067557558924659\ntank\t5556949434698476598\nzroot\t6329292263267649316'
    [ "$(sort <<<"$output")" = "$want" ]
    cache "$NATIVE_CACHE$NATIVE_CACHE"
    [ "$status" -eq 0 ]
    [ "$(sort <<<"$output")" = "$want" ]
}

@test "ambiguous or incomplete cached identities are rejected" {
    local invalid
    for invalid in "${NATIVE_CACHE}tank:\n    pool_guid: 5556949434698476599\n" \
        "${NATIVE_CACHE}other:\n    pool_guid: 5556949434698476598\n" 'tank:\n' 'tank:\n    pool_guid: 0\n' \
        'tank:\n    pool_guid: 18446744073709551616\n' 'tank:\n    pool_guid: 12\n    pool_guid: 12\n' \
        'tank;reboot:\n    pool_guid: 12\n'; do
        cache "$invalid"
        [ "$status" -ne 0 ] || { echo "accepted $invalid"; return 1; }
        [ -z "$output" ]
    done
}

@test "an absent cache invents no startup membership" {
    cache ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
