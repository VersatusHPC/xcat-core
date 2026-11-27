#!/usr/bin/env bats
#
# The ZFS disk preflight of xcat-install-lib.sh: the complete disk set, its identities and
# providers, the boundary reads, the reinstall ownership checks and automatic selection. Every
# FreeBSD command is a stub; the tests check that no selected or unrelated disk byte changes.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

POOL=18446744073709551610
DESTRUCTIVE='^(zpool labelclear|gpart destroy|dd .*of=/dev/)'

setup()
{
    LIB="$(freebsd_installer_dir)/xcat-install-lib.sh"
    POLICY=()
}

zeros() { head -c "${2:-1048576}" /dev/zero >"$1"; }
used()  { { printf USED; head -c $((1048576 - 4)) /dev/zero; } >"$1"; }

# edit <file> <perl substitution>: the file must change.
edit() { cp "$1" "$1.before"; perl -0pi -e "$2" "$1"; ! cmp -s "$1" "$1.before"; rm -f "$1.before"; }

stub()
{
    freebsd_stub "$ROOT/bin/$1" <<STUB
#!/bin/sh
printf '%s %s\n' '$1' "\$*" >> "\$FIXTURE_DIR/events"
test ! -f "\$FIXTURE_DIR/fail-$1" || exit 1
$2
STUB
}

# fixture [members]: members ada0..ada<n-1> and one more disk. Sets ROOT.
fixture()
{
    local count=${1:-3} i members='' disks=''
    ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
    mkdir -p "$ROOT/bin" "$ROOT/work" "$ROOT/labels"
    : >"$ROOT/expected"; : >"$ROOT/graph"
    for i in $(seq 0 "$count"); do
        disks="$disks${disks:+ }ada$i"
        if [ "$i" -lt "$count" ]; then
            members="$members${members:+,}ada$i@SERIAL$i"
            printf 'ada%s\tSERIAL%s\t1\t8589934592\t512\tr0w0e0\t%s\n' "$i" "$i" $((100 + i)) >>"$ROOT/expected"
        fi
        printf 'Geom name: ada%s\nProviders:\n1. Name: ada%s\n   Mediasize: 8589934592 (8G)\n   Sectorsize: 512\n   Mode: r0w0e0\n   ident: SERIAL%s\n\n' \
            "$i" "$i" "$i" >"$ROOT/ada$i.geom"
        printf 'Character Device:%s\n' $((100 + i)) >"$ROOT/ada$i.stat"
        printf '8589934592\n' >"$ROOT/ada$i.size"
        zeros "$ROOT/ada$i.head"; zeros "$ROOT/ada$i.tail"
        printf '0 DISK ada%s 8589934592 512 hd 16 sc 63\n1 LABEL diskid/DISK-SERIAL%s 8589934592 512 i 0 o 0\n' "$i" "$i" >>"$ROOT/graph"
    done
    printf '%s\n' "$disks" >"$ROOT/disks"
    printf '%s' "$members" >"$ROOT/members"
    : >"$ROOT/pools"; : >"$ROOT/geli"; : >"$ROOT/partitions"
    zeros "$ROOT/ada0.head.zero"
    stub geom 'test "$1 $2" = "disk list" || exit 90
count=0; test ! -f "$FIXTURE_DIR/geom-count" || count=$(cat "$FIXTURE_DIR/geom-count")
count=$((count+1)); printf "%s\n" "$count" > "$FIXTURE_DIR/geom-count"
for f in "$FIXTURE_DIR"/ada*.geom; do
    test -z "${3:-}" || test "$f" = "$FIXTURE_DIR/$3.geom" || continue
    if [ "$count" -gt 1 ] && [ -f "$f.changed" ]; then cat "$f.changed"; else cat "$f"; fi
done'
    stub sysctl 'case "$*" in
"-n kern.disks") cat "$FIXTURE_DIR/disks" ;;
"-n kern.geom.conftxt") cat "$FIXTURE_DIR/graph" ;;
"-n vm.swap_total") printf "0\n" ;;
"-n hw.physmem") printf "8589934592\n" ;;
*) exit 90 ;;
esac'
    stub stat 'test "$1" = -f && test "$2" = "%HT:%r" || exit 90
cat "$FIXTURE_DIR/${3##*/}.stat"'
    stub zpool 'test "$*" = "list -H -o name" || exit 90; cat "$FIXTURE_DIR/pools"'
    stub geli 'test "$*" = "status -s" || exit 90; cat "$FIXTURE_DIR/geli"'
    stub gpart 'test "$*" = list || exit 90; cat "$FIXTURE_DIR/partitions"'
    stub zdb 'case "$1" in -l|-ll) ;; *) exit 90 ;; esac
name=${2##*/}; test ! -f "$FIXTURE_DIR/zdb-status-$name" || exit "$(cat "$FIXTURE_DIR/zdb-status-$name")"
test -f "$FIXTURE_DIR/labels/$name" || exit 2; cat "$FIXTURE_DIR/labels/$name"'
    stub sha256 "test \"\$*\" = -q || exit 90; openssl dgst -sha256 | awk '{print \$NF}'"
    stub fstyp 'test "$1" = -u || exit 90
name=${2##*/}
if [ -f "$FIXTURE_DIR/fstyp-$name" ]; then
    cat "$FIXTURE_DIR/fstyp-$name"; exit "$(cat "$FIXTURE_DIR/fstyp-status-$name")"
fi
printf "fstyp: /dev/%s: filesystem not recognized\n" "$name" >&2; exit 1'
    stub dd 'src= dst= block= skip=0 count=
for arg do
    case "$arg" in if=*) src=${arg#if=} ;; of=*) dst=${arg#of=} ;; bs=*) block=${arg#bs=} ;;
        skip=*) skip=${arg#skip=} ;; count=*) count=${arg#count=} ;; *) exit 90 ;; esac
done
case "$dst" in "$FIXTURE_DIR"/work/storage.*/zero|"$FIXTURE_DIR"/work/storage.*/window|\
    "$FIXTURE_DIR"/work/pkgbase-work/storage.*/zero|"$FIXTURE_DIR"/work/pkgbase-work/storage.*/window) ;; *) exit 90 ;; esac
if [ "$src" = /dev/zero ]; then
    test "$block" = 1048576 && test "$count" = 1 || exit 90
    cp "$FIXTURE_DIR/ada0.head.zero" "$dst"; exit
fi
name=${src#/dev/}; region=tail; test "$skip" != 0 || region=head
test "$((block*count))" -eq 1048576 || exit 90
if [ "$region" = tail ]; then
    size=$(cat "$FIXTURE_DIR/$name.size") || exit 90
    test "$((block*skip))" -eq "$((size-1048576))" || exit 90
fi
test ! -f "$FIXTURE_DIR/dd-fail-$name-$region" || exit 1
cp "$FIXTURE_DIR/$name.$region" "$dst"'
}

# preflight [operation]: run one operation with POLICY as extra environment. Sets status,
# output and ERR, and fails when any head or tail byte changed.
preflight()
{
    local operation=${1:-xcat_check_zfs_initial} before after
    before=$(cd "$ROOT" && sha256sum ada*.head ada*.tail)
    run --separate-stderr env PATH="$ROOT/bin:$PATH" FIXTURE_DIR="$ROOT" XCAT_WORK="$ROOT/work" \
        XCAT_FORMAT=xcat-freebsd-install-4 XCAT_FILESYSTEM=zfs XCAT_ZFS_TOPOLOGY=mirror \
        XCAT_ZFS_VDEVS="$(cat "$ROOT/members")" XCAT_SWAP_SIZE=0 XCAT_SWAP_MODE=none "${POLICY[@]}" \
        sh -c '. "$1"; if [ "$2" = xcat_erase_os_disks ]; then "$2" "$FIXTURE_DIR/before.snapshot";
            elif [ "$2" = xcat_resolve_disks ]; then
                xcat_read_config "$XCAT_WORK/config" && "$2" && cat "$XCAT_WORK/config";
            else "$2"; fi 2>"$FIXTURE_DIR/stderr"' sh "$LIB" "$operation"
    ERR=$(cat "$ROOT/stderr" 2>/dev/null || true)
    after=$(cd "$ROOT" && sha256sum ada*.head ada*.tail)
    [ "$before" = "$after" ] || { echo 'a disk byte changed'; return 1; }
}

# reject <stderr pattern or ''>: the preflight fails and publishes no snapshot.
reject()
{
    preflight
    [ "$status" -ne 0 ] || { echo 'preflight accepted'; return 1; }
    [ -z "$output" ]
    [ -z "$1" ] || [[ "$ERR" =~ $1 ]] || { echo "stderr: $ERR"; return 1; }
}

no_destruction() { ! grep -Eq "$DESTRUCTIVE" "$ROOT/events" 2>/dev/null; }

@test "an ordered complete initial disk set passes with its exact identities" {
    local count
    for count in 2 3 16; do
        fixture "$count"
        preflight
        [ "$status" -eq 0 ]
        [ "$output" = "$(cat "$ROOT/expected")" ]
        [ -z "$ERR" ]
    done
    fixture
    edit "$ROOT/ada1.geom" 's/Sectorsize: 512/Sectorsize: 4096/'
    edit "$ROOT/graph" 's{((?:DISK ada1|LABEL diskid/DISK-SERIAL1) 8589934592) 512}{$1 4096}g'
    edit "$ROOT/expected" 's/ada1\tSERIAL1\t1\t8589934592\t512/ada1\tSERIAL1\t1\t8589934592\t4096/'
    preflight
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$ROOT/expected")" ]
    [ -z "$ERR" ]
}

@test "a wrong identity, capacity, consumer or sector size fails at every member before disk reads" {
    local index spec name from to reason
    for index in 0 1 2; do
        while IFS='|' read -r name from to; do
            fixture
            edit "$ROOT/ada$index.geom" "s/\\Q${from}\\E/${to}/"
            reason='Cannot identify the complete ZFS disk set'
            [ "$name" = active ] && reason='disk is in use'
            reject "$reason"
            ! grep -q '^dd ' "$ROOT/events"
        done <<CASES
identity|ident: SERIAL$index|ident: REPLACED
capacity|8589934592|4294966784
active|Mode: r0w0e0|Mode: r1w0e0
sector|Sectorsize: 512|Sectorsize: 520
CASES
    done
}

@test "an ambiguous or incomplete inventory fails" {
    local file value
    while IFS='|' read -r file value; do
        fixture
        printf '%b' "$value" >"$ROOT/$file"
        reject ''
    done <<'CASES'
disks|ada0 ada1 ada3\n
disks|ada0 ada1 ada2 ada2 ada3\n
ada1.stat|Character Device:100\n
ada1.stat|Symbolic Link:101\n
ada1.stat|Character Device:101\nCharacter Device:102\n
ada1.geom|unrecognized inventory
CASES
    local disk change
    while IFS='|' read -r disk change; do
        fixture
        edit "$ROOT/$disk.geom" "$change"
        reject ''
    done <<'CASES'
ada1|s/ident: SERIAL1/ident:/
ada3|s/ident: SERIAL3/ident: SERIAL1/
ada1|s/1\. Name: ada1/1. Name: ada2/
ada1|s/Sectorsize: 512/Sectorsize: 512\nSectorsize: 512/
ada1|s/8589934592/8589934593/
ada1|s/8589934592/9007199254740992/
CASES
}

@test "an existing provider or foreign metadata prevents installation" {
    local entry
    while IFS= read -r entry; do
        fixture
        edit "$ROOT/graph" "s{1 LABEL diskid/DISK-SERIAL1[^\\n]*}{$entry}"
        reject 'existing layout or provider'
    done <<'CASES'
1 PART ada1p1 8588886016 512 i 1 o 1048576 ty freebsd-zfs
1 MIRROR mirror/root 8589934080 512
1 ELI ada1.eli 8589934080 512
1 LABEL ufs/oldroot 8589934592 512 i 0 o 0
1 LABEL diskid/DISK-WRONG 8589934592 512 i 0 o 0
2 LABEL diskid/DISK-SERIAL1 8589934592 512 i 0 o 0
CASES
    local file value
    while IFS='|' read -r file value; do
        fixture
        printf '%b' "$value" >"$ROOT/$file"
        reject ''
    done <<'CASES'
pools|otherpool\n
geli|ada3.eli ACTIVE ada3\n
labels/ada1|pool_guid: 123\nname: 'otherpool'\n
labels/ada3|pool_guid: 456\nname: 'zroot'\n
CASES
    fixture
    printf "pool_guid: 456\nname: 'unrelated'\n" >"$ROOT/labels/ada3"
    preflight
    [ "$status" -eq 0 ]
}

@test "boundary reads and filesystem inspection fail closed" {
    local index region
    for index in 0 1 2; do
        for region in head tail; do
            fixture
            { printf X; head -c 1048575 /dev/zero; } >"$ROOT/ada$index.$region"
            reject 'metadata or an unreadable boundary'
            fixture
            head -c 1048575 /dev/zero >"$ROOT/ada$index.$region"
            reject 'metadata or an unreadable boundary'
            fixture
            : >"$ROOT/dd-fail-ada$index-$region"
            reject 'metadata or an unreadable boundary'
        done
    done
    local code text
    while IFS='|' read -r code text; do
        fixture
        printf '%b' "$text" >"$ROOT/fstyp-ada1"
        printf '%s\n' "$code" >"$ROOT/fstyp-status-ada1"
        reject 'filesystem or cannot be inspected'
    done <<'CASES'
0|ufs\n
1|fstyp: fread: Input/output error\nfstyp: /dev/ada1: filesystem not recognized\n
1|fstyp: /dev/ada1: Permission denied\n
2|fstyp: /dev/ada1: filesystem not recognized\n
CASES
}

@test "a failed observation or a change during preflight rejects the request" {
    local name
    for name in geom sysctl stat zpool geli gpart zdb fstyp dd; do
        fixture
        : >"$ROOT/fail-$name"
        reject ''
    done
    fixture
    sed 's/Mode: r0w0e0/Mode: r1w0e0/' "$ROOT/ada2.geom" >"$ROOT/ada2.geom.changed"
    reject 'disk set changed during preflight'
}

REINSTALL=(XCAT_FORMAT=xcat-freebsd-install-5 XCAT_DISK_ACTION=erase XCAT_ZFS_COMPRESSION=lz4
    XCAT_ZFS_ASHIFT=12 XCAT_PRESERVE_DISKS=ada3@SERIAL3)

@test "a whole OS disk reinstall keeps separate identities and rejects foreign storage" {
    fixture
    printf "pool_guid: 123\nname: 'zroot'\n" >"$ROOT/labels/ada0"
    printf "pool_guid: 456\nname: 'tank'\n" >"$ROOT/labels/ada3"
    POLICY=("${REINSTALL[@]}")
    preflight xcat_check_zfs_reinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *$'preserved\nada3\tSERIAL3\t'* ]]
    grep -A1 -x labels <<<"$output" | tail -n1 | grep -Eqx 'ada0 [0-9a-f]{64}'
    local bad
    for bad in XCAT_DISK_ACTION=empty XCAT_PRESERVE_DISKS=ada0@SERIAL0 XCAT_PRESERVE_DISKS=ada3@WRONG XCAT_PRESERVE_DISKS=ada4@MISSING; do
        POLICY=("${REINSTALL[@]}" "$bad")
        preflight xcat_check_zfs_reinstall
        [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
    done
    POLICY=("${REINSTALL[@]}")
    printf "pool_guid: 123\nname: 'zroot'\n" >"$ROOT/labels/ada3"
    preflight xcat_check_zfs_reinstall; [ "$status" -ne 0 ]
    printf "pool_guid: 456\nname: 'tank'\n" >"$ROOT/labels/ada3"
    printf "pool_guid: 456\nname: 'tank'\n" >"$ROOT/labels/ada0"
    preflight xcat_check_zfs_reinstall; [ "$status" -ne 0 ]
    printf "pool_guid: 123\nname: 'zroot'\n" >"$ROOT/labels/ada0"
    edit "$ROOT/graph" 's{1 LABEL diskid/DISK-SERIAL0[^\n]*}{1 ELI ada0.eli 8589934080 512}'
    preflight xcat_check_zfs_reinstall; [ "$status" -ne 0 ]
}

gpt_partitions() { printf 'Geom name: ada0\nscheme: GPT\nstate: OK\nmodified: false\nMode: r0w0e0\n' >"$ROOT/partitions"; }

@test "native GPT UFS labels are confined to their filesystem partition" {
    fixture
    edit "$ROOT/ada0.geom" 's/8589934592/17179869184/g'
    local native='0 DISK ada0 17179869184 512 hd 16 sc 63
1 PART ada0p3 16642433024 512 i 3 o 537415680 ty freebsd-ufs xs GPT xt 516e7cb6-6ecf-11d6-8ff8-00022d09712b
2 LABEL ufsid/0123456789abcdef 16642433024 512 i 0 o 0
1 PART ada0p2 524288 512 i 2 o 536891392 ty freebsd-boot xs GPT xt 83bd6b9d-7f41-11dc-be0b-001560b84f0f
1 PART ada0p1 536870912 512 i 1 o 20480 ty freebsd-swap xs GPT xt 516e7cb5-6ecf-11d6-8ff8-00022d09712b'
    NATIVE="$native" edit "$ROOT/graph" 's/0 DISK ada0[^\n]*\n1 LABEL[^\n]*\n/$ENV{NATIVE}\n/'
    cp "$ROOT/graph" "$ROOT/graph.native"
    gpt_partitions
    POLICY=("${REINSTALL[@]}")
    local label change
    for label in ufsid/0123456789abcdef ufs/oldroot; do
        sed "s|ufsid/0123456789abcdef|$label|" "$ROOT/graph.native" >"$ROOT/graph"
        preflight xcat_check_zfs_reinstall
        [ "$status" -eq 0 ] || { echo "rejected $label: $ERR"; return 1; }
        [[ "$output" == *$'preserved\nada3\tSERIAL3\t'* ]]
    done
    for change in 's/freebsd-ufs/freebsd-zfs/' 's{ufsid/0123456789abcdef}{mirror/userdata}' 's/2 LABEL/2 ELI/'; do
        cp "$ROOT/graph.native" "$ROOT/graph"
        edit "$ROOT/graph" "$change"
        preflight xcat_check_zfs_reinstall
        [ "$status" -ne 0 ] || { echo "accepted $change"; return 1; }
    done
}

@test "erase rechecks the accepted snapshot before any destructive command" {
    POLICY=("${REINSTALL[@]}")
    local change
    for change in snapshot identity labels; do
        fixture
        preflight xcat_check_zfs_reinstall
        [ "$status" -eq 0 ]
        printf '%s\n' "$output" >"$ROOT/before.snapshot"
        case $change in
            snapshot) echo changed >>"$ROOT/before.snapshot" ;;
            identity) edit "$ROOT/ada3.geom" 's/SERIAL3/REPLACED/' ;;
            labels) printf "pool_guid: 123\nname: 'zroot'\n" >"$ROOT/labels/ada0" ;;
        esac
        : >"$ROOT/events"
        preflight xcat_erase_os_disks
        [ "$status" -ne 0 ] || { echo "$change did not invalidate erase"; return 1; }
        no_destruction
    done
}

@test "native FAT labels are confined to EFI partitions" {
    fixture
    local native='0 DISK ada0 8589934592 512 hd 16 sc 63
1 PART ada0p1 67108864 512 i 1 o 20480 ty efi xs GPT xt c12a7328-f81f-11d2-ba4b-00a0c93ec93b
2 LABEL msdosfs/XCAT_EFI 67108864 512 i 0 o 0'
    NATIVE="$native" edit "$ROOT/graph" 's/0 DISK ada0[^\n]*\n1 LABEL[^\n]*\n/$ENV{NATIVE}\n/'
    cp "$ROOT/graph" "$ROOT/graph.native"
    gpt_partitions
    POLICY=("${REINSTALL[@]}")
    preflight xcat_check_zfs_reinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *$'preserved\nada3\tSERIAL3\t'* ]]
    local change
    for change in 's/ty efi/ty freebsd-zfs/' 's{msdosfs/XCAT_EFI}{mirror/userdata}' 's/2 LABEL/2 ELI/'; do
        cp "$ROOT/graph.native" "$ROOT/graph"
        edit "$ROOT/graph" "$change"
        preflight xcat_check_zfs_reinstall
        [ "$status" -ne 0 ] || { echo "accepted $change"; return 1; }
    done
}

AUX=(XCAT_FORMAT=xcat-freebsd-install-6 XCAT_DISK_ACTION=erase XCAT_GENERATION=cccccccccccccccccccccccccccccccc
    XCAT_ZFS_COMPRESSION=lz4 XCAT_ZFS_ASHIFT=12 XCAT_PRESERVE_DISKS=ada7@SERIAL7
    XCAT_ZFS_VDEVS=ada0@SERIAL0,ada1@SERIAL1 XCAT_ZFS_SPECIAL_VDEVS=ada2@SERIAL2,ada3@SERIAL3
    XCAT_ZFS_LOG_VDEVS=ada4@SERIAL4,ada5@SERIAL5 XCAT_ZFS_CACHE_VDEVS=ada6@SERIAL6 XCAT_ZFS_SPECIAL_SMALL_BLOCKS=0)

cache_label()
{
    printf "LABEL 0\n    version: 5000\n    state: 4\n    guid: 18331623171503817866\n    ashift: 12\n    path: '/dev/ada6'\n    labels = 0 1 2 3\nL2ARC device header\n    magic: 6504978260106102853\n    version: 1\n    pool_guid: %s\n    flags: 1\n" "$POOL"
}

aux_fixture()
{
    fixture 7
    local i
    for i in 0 1 2 3 4 5; do printf "LABEL 0\n    state: 1\n    name: 'zroot'\n    pool_guid: %s\n" "$POOL" >"$ROOT/labels/ada$i"; done
    cache_label >"$ROOT/labels/ada6"
    printf "LABEL 0\n    state: 1\n    name: 'tank'\n    pool_guid: 18446744073709551611\n" >"$ROOT/labels/ada7"
    POLICY=("${AUX[@]}")
}

@test "OS auxiliary members and L2ARC ownership permit a reinstall" {
    aux_fixture
    preflight xcat_check_zfs_reinstall
    [ "$status" -eq 0 ] || { echo "$ERR"; return 1; }
    grep -q $'^ada6\tSERIAL6\tcache:1\t' <<<"$output"
    [[ "$output" == *$'preserved\nada7\tSERIAL7\t'* ]]
}

@test "groups must have equal capacities, and independent groups may differ" {
    local member
    for member in 1 3 5; do
        aux_fixture
        edit "$ROOT/ada$member.geom" 's/8589934592/8623489024/g'
        preflight xcat_check_zfs_reinstall
        [ "$status" -ne 0 ]
        [[ "$ERR" == *'must have equal capacities'* ]]
        no_destruction
    done
    aux_fixture
    for member in 2 3 4 5 6; do
        local size=536870912
        [ "$member" -lt 6 ] && size=1073741824
        [ "$member" -lt 4 ] && size=2147483648
        edit "$ROOT/ada$member.geom" "s/8589934592/$size/g"
    done
    preflight xcat_zfs_disk_inventory
    [ "$status" -eq 0 ]
}

@test "foreign, invalid or changed auxiliary ownership prevents erase" {
    local change operation
    for change in foreign-cache missing-owner magic version cksum foreign-log missing-special \
        preserved-overlap unselected-cache root-guid destroyed partly-overwritten changed-before-erase; do
        aux_fixture
        operation=xcat_check_zfs_reinstall
        case $change in
            foreign-cache) edit "$ROOT/labels/ada6" "s/$POOL/18446744073709551611/g" ;;
            changed-before-erase)
                preflight xcat_check_zfs_reinstall
                [ "$status" -eq 0 ]
                printf '%s\n' "$output" >"$ROOT/before.snapshot"
                edit "$ROOT/labels/ada6" 's/ashift: 12/ashift: 13/'
                preflight xcat_check_zfs_reinstall
                [ "$status" -eq 0 ]
                [ "$output" != "$(cat "$ROOT/before.snapshot")" ]
                operation=xcat_erase_os_disks ;;
            missing-owner) edit "$ROOT/labels/ada6" 's/    pool_guid:[^\n]*\n//' ;;
            magic) edit "$ROOT/labels/ada6" 's/magic: 6504978260106102853/magic: 6504978260106102852/' ;;
            version) edit "$ROOT/labels/ada6" 's/version: 1\n/version: 2\n/' ;;
            cksum) edit "$ROOT/labels/ada6" 's/LABEL 0/LABEL 0 (Bad label cksum)/' ;;
            foreign-log) printf "state: 1\nname: 'tank'\npool_guid: 123\n" >"$ROOT/labels/ada4" ;;
            missing-special) printf 'ada0 ada1 ada2 ada4 ada5 ada6 ada7\n' >"$ROOT/disks" ;;
            preserved-overlap) POLICY+=(XCAT_PRESERVE_DISKS=ada6@SERIAL6) ;;
            unselected-cache) POLICY+=(XCAT_ZFS_CACHE_VDEVS=-) ;;
            destroyed) printf "LABEL 0\n    state: 2\n    name: 'tank'\n    pool_guid: 18446744073709551611\n" >"$ROOT/labels/ada7" ;;
            partly-overwritten) printf "failed to unpack label 0\nLABEL 1\n    state: 1\n    name: 'tank'\n    pool_guid: 18446744073709551611\n" >"$ROOT/labels/ada7" ;;
            root-guid) printf "state: 1\nname: 'zroot'\npool_guid: 18446744073709551611\n" >"$ROOT/labels/ada1" ;;
        esac
        : >"$ROOT/events"
        preflight "$operation"
        [ "$status" -ne 0 ] || { echo "$change did not prevent erase"; return 1; }
        if [ "$change" = changed-before-erase ]; then
            [[ "$ERR" == *'OS or preserved disk state changed before reinstall'* ]]
        fi
        no_destruction
    done
}

# auto_config [field=value | -field=] ...: the automatic-selection configuration; -field= removes a field.
auto_config()
{
    declare -A c=([format]=xcat-freebsd-install-5 [release]=15.1-RELEASE [node]=node1 [hostname]=node1
        [generation]=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa [master]=192.0.2.1 [port]=3002 [ipv4]=192.0.2.2
        [netmask]=255.255.255.0 [gateway]= [nameservers]= [mac]=52:54:00:12:34:56 [filesystem]=zfs
        [swap_size]=0 [swap_mode]=none [zfs_topology]=mirror [zfs_vdevs]=auto:2 [zfs_compression]=lz4
        [zfs_ashift]=12 [disk_action]=empty [disk_selection]=empty [preserve_disks]=-
        [install_url]=http://192.0.2.1/install [package_plan_sha256]="$(printf 'b%.0s' {1..64})"
        [boot_media_sha256]="$(printf 'c%.0s' {1..64})" [runtime_sha256]="$(printf 'd%.0s' {1..64})"
        [authorized_key_base64]=AAAA [bootstrap]=dhcp [console_port]=none [console_speed]=0
        [console_flow]=none [install_boot_options_base64]= [target_boot_options_base64]=)
    local kv k
    for kv in "$@"; do
        if [[ "$kv" == -* ]]; then k=${kv#-}; unset "c[${k%=}]"; continue; fi
        c[${kv%%=*}]=${kv#*=}
    done
    for k in "${!c[@]}"; do printf '%s=%s\n' "$k" "${c[$k]}"; done | LC_ALL=C sort >"$ROOT/work/config"
}

SCALAR=(format=xcat-freebsd-install-3 target_disk=auto -zfs_topology= -zfs_vdevs= -swap_mode= -zfs_compression= -zfs_ashift= -disk_action=)

@test "automatic selection excludes protected and occupied disks" {
    fixture 4
    auto_config preserve_disks=ada0@SERIAL0
    used "$ROOT/ada1.head"
    preflight xcat_resolve_disks
    [ "$status" -eq 0 ]
    grep -qx 'zfs_vdevs=ada2@SERIAL2,ada3@SERIAL3' <<<"$output"
    ! grep -q '^disk_selection=' <<<"$output"
    grep -qx 'preserve_disks=ada0@SERIAL0' <<<"$output"
    ! grep -q 'dd if=/dev/ada0' "$ROOT/events"
    [[ "$ERR" == *'selected OS disks ada2@SERIAL2,ada3@SERIAL3'* ]]
}

@test "automatic group sizes and scalar filesystems resolve through the same guards" {
    local spec topology vdevs want filesystem
    for spec in 'stripe|auto:1|ada0@SERIAL0' 'raid10|auto:2;auto:2|ada0@SERIAL0,ada1@SERIAL1;ada2@SERIAL2,ada3@SERIAL3' \
        'raidz2|auto:4|ada0@SERIAL0,ada1@SERIAL1,ada2@SERIAL2,ada3@SERIAL3'; do
        IFS='|' read -r topology vdevs want <<<"$spec"
        fixture 4
        auto_config zfs_topology="$topology" zfs_vdevs="$vdevs"
        preflight xcat_resolve_disks
        [ "$status" -eq 0 ]
        grep -qxF "zfs_vdevs=$want" <<<"$output"
    done
    for filesystem in ufs zfs; do
        fixture 1
        auto_config "${SCALAR[@]}" filesystem="$filesystem"
        preflight xcat_resolve_disks
        [ "$status" -eq 0 ]
        grep -qx 'target_disk=ada0' <<<"$output"
        grep -qx 'target_disk_ident=SERIAL0' <<<"$output"
    done
}

@test "automatic selection fails closed without a complete safe disk set" {
    local case
    for case in insufficient duplicate active malformed erase changed; do
        fixture 1
        auto_config
        case $case in
            insufficient) used "$ROOT/ada1.tail" ;;
            duplicate) edit "$ROOT/ada1.geom" 's/SERIAL1/SERIAL0/' ;;
            active) edit "$ROOT/ada1.geom" 's/r0w0e0/r1w0e0/' ;;
            changed) sed 's/SERIAL1/REPLACED/' "$ROOT/ada1.geom" >"$ROOT/ada1.geom.changed" ;;
            malformed) auto_config 'zfs_vdevs=auto:2;ada2@SERIAL2' ;;
            erase) auto_config disk_action=erase ;;
        esac
        cp "$ROOT/work/config" "$ROOT/config.before"
        preflight xcat_resolve_disks
        [ "$status" -ne 0 ] || { echo "$case published a selection"; return 1; }
        cmp "$ROOT/work/config" "$ROOT/config.before"
    done
}

@test "automatic candidates satisfy the swap capacity and the ZFS sector alignment" {
    fixture 2
    edit "$ROOT/ada0.geom" 's/8589934592/5368709120/g'
    printf '5368709120\n' >"$ROOT/ada0.size"
    edit "$ROOT/graph" 's/ada0 8589934592/ada0 5368709120/g; s{diskid/DISK-SERIAL0 8589934592}{diskid/DISK-SERIAL0 5368709120}g'
    auto_config "${SCALAR[@]}" filesystem=ufs swap_size=4G
    preflight xcat_resolve_disks
    [ "$status" -eq 0 ] || { echo "$ERR"; return 1; }
    grep -qx 'target_disk=ada1' <<<"$output"
    fixture 2
    edit "$ROOT/ada0.geom" 's/Sectorsize: 512/Sectorsize: 4096/g'
    edit "$ROOT/graph" 's/(?:ada0|diskid\/DISK-SERIAL0) 8589934592 \K512/4096/g'
    auto_config zfs_ashift=9
    preflight xcat_resolve_disks
    [ "$status" -eq 0 ] || { echo "$ERR"; return 1; }
    grep -qx 'zfs_vdevs=ada1@SERIAL1,ada2@SERIAL2' <<<"$output"
}
