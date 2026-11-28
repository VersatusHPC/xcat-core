#!/usr/bin/env bats
#
# xcat_read_config in xcat-install-lib.sh reads the installer configuration that
# xCAT::FreeBSDConfig writes, and validates every field again on the node. The
# configurations come from the Perl producer (fixtures/freebsd-render-config.pl);
# the byte layout of the producer is asserted in xCAT-test/unit/freebsd_config.t.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

GEN=dddddddddddddddddddddddddddddddd
OMIT='"omit":["target_disk","target_disk_ident"]'
# The dedicated OS disk policy of contract 5.
P5='"filesystem":"zfs","swap_size":"0","swap_mode":"none","zfs_topology":"mirror","zfs_vdevs":"vtbd0@OS_A,vtbd1@OS_B","zfs_compression":"lz4"'
# The auxiliary device policy of contract 6.
P6="$P5"',"zfs_special_vdevs":"vtbd2@SPECIAL_A,vtbd3@SPECIAL_B","zfs_log_vdevs":"vtbd4@LOG_A,vtbd5@LOG_B;vtbd7@LOG_C","zfs_cache_vdevs":"vtbd6@CACHE_A","zfs_special_small_blocks":"4096","preserve_disks":"vtbd8@DATA_A","disk_action":"erase"'
# The ordered redundant policy of contract 4.
P4='"filesystem":"zfs","swap_size":"0","swap_mode":"none","zfs_topology":"mirror","zfs_vdevs":"vtbd0@A,vtbd1@B"'

setup()
{
    LIB="$(freebsd_installer_dir)/xcat-install-lib.sh"
    ROOT="$BATS_TEST_TMPDIR"
}

render() { perl "$(repo_path xCAT-test/bats/fixtures/freebsd-render-config.pl)" "{$1}"; }

# policy <contract> <disk settings> [more disk settings]: render a disk policy.
policy() { render '"contract":"xcat-freebsd-install-'"$1"'",'"$OMIT"',"disk":{'"$2${3:+,$3}"'}'; }

# read_config <config file> [script]: run a script after xcat_read_config.
read_config()
{
    LC_ALL=C run --separate-stderr sh -c '. "$1"; xcat_read_config "$2" || exit; '"${2:-:}" xcat-test "$LIB" "$1"
}

# set_value <in> <key> <value> <out>: replace the value of one key.
set_value()
{
    K="$2" V="$3" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' \
        "$1" >"$4"
}

# mutate <in> <key> <value> <out>: set_value, and the value must change.
mutate() { set_value "$@"; ! cmp -s "$1" "$4"; }

# drop <in> <key> <out>: remove one key.
drop() { grep -v "^$2=" "$1" >"$3"; ! cmp -s "$1" "$3"; }

# rejects <file>: the reader fails and prints nothing.
rejects()
{
    read_config "$1" 'printf unsafe'
    [ "$status" -ne 0 ] || { echo "accepted: $(grep -v '^authorized' "$1")"; return 1; }
    [ -z "$output" ]
}

@test "the runtime reads the exact fields of the legacy distribution format" {
    render '"output":"legacy"' >"$ROOT/config"
    read_config "$ROOT/config" 'printf "%s|%s|%s|%s|%s\n" "$XCAT_NODE" "$XCAT_GENERATION" "$XCAT_TARGET_DISK" "$XCAT_FILESYSTEM" "$XCAT_GATEWAY"'
    [ "$status" -eq 0 ]
    [ "$output" = "node1|$GEN|vtbd0|ufs|" ]
}

@test "the runtime reads the node settings and every package pin of the pkgbase format" {
    render '"contract":null' >"$ROOT/config"
    grep -qx 'format=xcat-freebsd-install-2' "$ROOT/config"
    read_config "$ROOT/config" 'printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$XCAT_NODE" "$XCAT_GENERATION" "$XCAT_TARGET_DISK" "$XCAT_FILESYSTEM" "$XCAT_INSTALL_URL" "$XCAT_PACKAGE_PLAN_SHA256" "$XCAT_BOOT_MEDIA_SHA256" "$XCAT_RUNTIME_SHA256"'
    [ "$status" -eq 0 ]
    [ "$output" = "node1|$GEN|vtbd0|ufs|http://192.0.2.1/install|$(printf 'c%.0s' {1..64})|$(printf 'a%.0s' {1..64})|$(printf 'b%.0s' {1..64})" ]
}

@test "the runtime receives the exact disk property defaults" {
    policy 5 "$P5" >"$ROOT/config"
    read_config "$ROOT/config" 'printf "%s|%s|%s|%s\n" "$XCAT_ZFS_COMPRESSION" "$XCAT_ZFS_ASHIFT" "$XCAT_DISK_ACTION" "$XCAT_PRESERVE_DISKS"'
    [ "$status" -eq 0 ]
    [ "$output" = 'lz4|12|empty|-' ]
}

@test "every compression and ashift reaches the runtime, and data disks stay apart from the OS" {
    local compression ashift
    for compression in off lz4 gzip gzip-9 zstd zstd-19; do
        for ashift in 9 12 16; do
            policy 5 "$P5" '"zfs_compression":"'$compression'","zfs_ashift":"'$ashift'","disk_action":"erase","preserve_disks":"vtbd2@DATA_A,vtbd3@DATA_B"' >"$ROOT/config"
            read_config "$ROOT/config" xcat_preserved_members
            [ "$status" -eq 0 ] || { echo "$compression $ashift rejected"; return 1; }
            [ "$output" = $'vtbd2\tDATA_A\t1\nvtbd3\tDATA_B\t1' ]
        done
    done
}

@test "the runtime accepts gzip-6 and reads it as the canonical gzip" {
    policy 5 "$P5" '"zfs_compression":"gzip-6"' >"$ROOT/config"
    mutate "$ROOT/config" zfs_compression gzip-6 "$ROOT/gzip6"
    read_config "$ROOT/gzip6" 'printf "%s" "$XCAT_ZFS_COMPRESSION"'
    [ "$status" -eq 0 ]
    [ "$output" = gzip ]
}

@test "one OS disk uses the same guarded policy" {
    policy 5 "$P5" '"zfs_topology":"stripe","zfs_vdevs":"vtbd0@OS_A"' >"$ROOT/config"
    read_config "$ROOT/config" xcat_zfs_members
    [ "$status" -eq 0 ]
    [ "$output" = $'vtbd0\tOS_A\t1' ]
}

@test "the runtime rejects each invalid or missing disk property field" {
    policy 5 "$P5" >"$ROOT/config"
    local kv
    for kv in zfs_compression=on zfs_compression=zstd-20 zfs_ashift=8 zfs_ashift=012 zfs_ashift=17 \
        disk_action=preserve-partitions preserve_disks= preserve_disks=vtbd0@DATA preserve_disks=vtbd2@OS_A \
        preserve_disks=vtbd2@DATA,vtbd3@DATA preserve_disks=/dev/vtbd2@DATA; do
        mutate "$ROOT/config" "${kv%%=*}" "${kv#*=}" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
    for kv in zfs_compression zfs_ashift disk_action preserve_disks; do
        drop "$ROOT/config" "$kv" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
}

@test "boot options cannot disable stable GPT names at the runtime" {
    policy 6 "$P6" >"$ROOT/config"
    local phase option
    option=$(printf 'kern.geom.label.gpt.enable="0"\n' | base64 -w0)
    for phase in install target; do
        mutate "$ROOT/config" "${phase}_boot_options_base64" "$option" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
}

@test "the auxiliary policy binds every OS role to its member and its GPT label" {
    policy 6 "$P6" >"$ROOT/config"
    grep -qx 'format=xcat-freebsd-install-6' "$ROOT/config"
    read_config "$ROOT/config" xcat_zfs_all_members
    [ "$status" -eq 0 ]
    [ "$output" = $'vtbd0\tOS_A\t1\nvtbd1\tOS_B\t1\nvtbd2\tSPECIAL_A\tspecial:1\nvtbd3\tSPECIAL_B\tspecial:1\nvtbd7\tLOG_C\tlog:2\nvtbd4\tLOG_A\tlog:1\nvtbd5\tLOG_B\tlog:1\nvtbd6\tCACHE_A\tcache:1' ]
    read_config "$ROOT/config" xcat_zfs_members
    [ "$output" = $'vtbd0\tOS_A\t1\nvtbd1\tOS_B\t1' ]
    read_config "$ROOT/config" 'xcat_zfs_auxiliary arguments'
    [ "$output" = "special
mirror
/dev/gpt/a${GEN}0
/dev/gpt/a${GEN}1
log
/dev/gpt/a${GEN}2
mirror
/dev/gpt/a${GEN}3
/dev/gpt/a${GEN}4
cache
/dev/gpt/a${GEN}5" ]
    read_config "$ROOT/config" 'xcat_zfs_primary arguments'
    [ "$output" = "/dev/gpt/z${GEN}0
/dev/gpt/z${GEN}1" ]
    read_config "$ROOT/config" 'xcat_zfs_auxiliary partitions'
    [ "$output" = "vtbd2	SPECIAL_A	special:1	a${GEN}0
vtbd3	SPECIAL_B	special:1	a${GEN}1
vtbd7	LOG_C	log:2	a${GEN}2
vtbd4	LOG_A	log:1	a${GEN}3
vtbd5	LOG_B	log:1	a${GEN}4
vtbd6	CACHE_A	cache:1	a${GEN}5" ]
    read_config "$ROOT/config" xcat_preserved_members
    [ "$output" = $'vtbd8\tDATA_A\t1' ]
}

@test "the auxiliary policy renders the native installer header" {
    policy 6 "$P6" >"$ROOT/config"
    read_config "$ROOT/config" 'xcat_write_installer "${1%/*}/installerconfig.tmpl"'
    [ "$status" -eq 0 ]
    local header="${output%%#!/bin/sh*}"
    grep -qxF 'export ZFSBOOT_DISKS="vtbd0 vtbd1"' <<<"$header"
    grep -qxF 'export ZFSBOOT_POOL_CREATE_OPTIONS="-o ashift=12 -O compression=lz4 -O atime=off -O special_small_blocks=4096"' <<<"$header"
    grep -qxF "export XCAT_ZFS_AUXILIARY=\"special mirror /dev/gpt/a${GEN}0 /dev/gpt/a${GEN}1 log /dev/gpt/a${GEN}2 mirror /dev/gpt/a${GEN}3 /dev/gpt/a${GEN}4 cache /dev/gpt/a${GEN}5\"" <<<"$header"
}

@test "the runtime rejects auxiliary fields in older formats and invalid or missing auxiliary fields" {
    policy 6 "$P6" >"$ROOT/config"
    local older kv
    for older in 3 4 5; do
        sed "s/install-6/install-$older/" "$ROOT/config" >"$ROOT/bad"
        rejects "$ROOT/bad"
    done
    while IFS= read -r kv; do
        mutate "$ROOT/config" "${kv%%=*}" "${kv#*=}" "$ROOT/bad"
        rejects "$ROOT/bad"
    done <<'CASES'
zfs_special_vdevs=vtbd2@SPECIAL_A
zfs_special_vdevs=vtbd2@SPECIAL_A,vtbd3@SPECIAL_B,vtbd9@SPECIAL_C
zfs_special_vdevs=-
zfs_special_vdevs=
zfs_log_vdevs=vtbd0@LOG_A
zfs_log_vdevs=vtbd9@OS_A
zfs_log_vdevs=vtbd2@LOG_A
zfs_log_vdevs=vtbd9@CACHE_A
zfs_log_vdevs=vtbd4@LOG_A;
zfs_cache_vdevs=vtbd6@CACHE_A;vtbd9@CACHE_B
zfs_cache_vdevs=/dev/vtbd6@CACHE_A
zfs_cache_vdevs=vtbd06@CACHE_A
zfs_special_small_blocks=1
zfs_special_small_blocks=513
zfs_special_small_blocks=16777217
zfs_special_small_blocks=0512
preserve_disks=vtbd6@DATA_A
preserve_disks=vtbd8@SPECIAL_A
CASES
    for kv in zfs_log_vdevs zfs_cache_vdevs zfs_special_vdevs zfs_special_small_blocks; do
        drop "$ROOT/config" "$kv" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
}

@test "each primary topology accepts matching special redundancy and keeps its group boundaries" {
    local spec topology vdevs special expected
    for spec in 'mirror|vtbd0@A,vtbd1@B,vtbd9@C|vtbd2@D,vtbd3@E,vtbd10@F|z0 z1 z2' \
        'raid10|vtbd0@A,vtbd1@B;vtbd9@C,vtbd10@D|vtbd2@E,vtbd3@F|mirror z0 z1 mirror z2 z3' \
        'raidz1|vtbd0@A,vtbd1@B,vtbd9@C|vtbd2@D,vtbd3@E|z0 z1 z2' \
        'raidz2|vtbd0@A,vtbd1@B,vtbd9@C,vtbd10@D|vtbd2@E,vtbd3@F,vtbd11@G|z0 z1 z2 z3' \
        'raidz3|vtbd0@A,vtbd1@B,vtbd9@C,vtbd10@D,vtbd11@E|vtbd2@F,vtbd3@G,vtbd12@H,vtbd13@I|z0 z1 z2 z3 z4'; do
        IFS='|' read -r topology vdevs special expected <<<"$spec"
        policy 6 "$P6" '"zfs_topology":"'$topology'","zfs_vdevs":"'$vdevs'","zfs_special_vdevs":"'$special'"' >"$ROOT/config"
        read_config "$ROOT/config" xcat_zfs_all_members
        [ "$status" -eq 0 ] || { echo "$topology rejected"; return 1; }
        read_config "$ROOT/config" 'xcat_zfs_primary arguments'
        expected=$(sed -E "s|z([0-9]+)|/dev/gpt/z${GEN}\\1|g" <<<"$expected" | tr ' ' '\n')
        [ "$output" = "$expected" ]
    done
}

@test "a single OS disk can use log and cache devices" {
    policy 6 "$P6" '"zfs_topology":"stripe","zfs_vdevs":"vtbd0@OS_A","zfs_special_vdevs":"-","zfs_special_small_blocks":"0"' >"$ROOT/config"
    read_config "$ROOT/config" xcat_zfs_all_members
    [ "$status" -eq 0 ]
}

@test "the runtime keeps the declared member order, serials and groups of a redundant pool" {
    local spec topology vdevs expected long16 long16e
    long16=$(for i in $(seq 0 15); do printf 'vtbd%s@S%s,' "$i" "$i"; done)
    long16e=$(for i in $(seq 0 15); do printf 'vtbd%s\\tS%s\\t1\\n' "$i" "$i"; done)
    while IFS='|' read -r topology vdevs expected; do
        expected=$(printf "$expected")
        policy 4 "$P4" '"zfs_topology":"'$topology'","zfs_vdevs":"'$vdevs'"' >"$ROOT/config"
        grep -qx 'format=xcat-freebsd-install-4' "$ROOT/config"
        read_config "$ROOT/config" xcat_zfs_members
        [ "$status" -eq 0 ] || { echo "$topology $vdevs rejected"; return 1; }
        [ "$output" = "$expected" ]
    done <<CASES
mirror|vtbd1@B,vtbd0@A|vtbd1\tB\t1\nvtbd0\tA\t1
mirror|ada0@A,da1@B,nda2@C|ada0\tA\t1\nda1\tB\t1\nnda2\tC\t1
raid10|vtbd3@D,vtbd1@B;vtbd2@C,vtbd0@A|vtbd3\tD\t1\nvtbd1\tB\t1\nvtbd2\tC\t2\nvtbd0\tA\t2
raidz1|vtbd0@A,vtbd1@B,vtbd2@C|vtbd0\tA\t1\nvtbd1\tB\t1\nvtbd2\tC\t1
raidz2|vtbd0@A,vtbd1@B,vtbd2@C,vtbd3@D|vtbd0\tA\t1\nvtbd1\tB\t1\nvtbd2\tC\t1\nvtbd3\tD\t1
raidz3|vtbd0@A,vtbd1@B,vtbd2@C,vtbd3@D,vtbd4@E|vtbd0\tA\t1\nvtbd1\tB\t1\nvtbd2\tC\t1\nvtbd3\tD\t1\nvtbd4\tE\t1
raid10|vtbd0@A,vtbd1@B;vtbd2@C,vtbd3@D;vtbd4@E,vtbd5@F|vtbd0\tA\t1\nvtbd1\tB\t1\nvtbd2\tC\t2\nvtbd3\tD\t2\nvtbd4\tE\t3\nvtbd5\tF\t3
mirror|nvd99999@$(printf 'A%.0s' {1..128}),vtbd0@a|nvd99999\t$(printf 'A%.0s' {1..128})\t1\nvtbd0\ta\t1
mirror|${long16%,}|$long16e
CASES
}

@test "the runtime rejects each invalid redundant pool field" {
    policy 4 "$P4" >"$ROOT/config"
    read_config "$ROOT/config" 'printf accepted'
    [ "$status" -eq 0 ]
    local kv long17
    long17=$(for i in $(seq 0 16); do printf 'vtbd%s@S%s,' "$i" "$i"; done)
    while IFS= read -r kv; do
        mutate "$ROOT/config" "${kv%%=*}" "${kv#*=}" "$ROOT/bad"
        rejects "$ROOT/bad"
    done <<CASES
zfs_topology=stripe
zfs_topology=raidz
zfs_topology=MIRROR
zfs_vdevs=
zfs_vdevs=vtbd0@A
zfs_vdevs=,vtbd0@A,vtbd1@B
zfs_vdevs=vtbd0@A,vtbd1@B,
zfs_vdevs=vtbd0@A,,vtbd1@B
zfs_vdevs=vtbd0@A;vtbd1@B
zfs_vdevs=;vtbd0@A,vtbd1@B
zfs_vdevs=vtbd0@A,vtbd1@B;
zfs_vdevs=vtbd0@A,vtbd1@B;;
zfs_vdevs=vtbd0@A,vtbd0@B
zfs_vdevs=vtbd0@A,vtbd1@A
zfs_vdevs=vtbd00@A,vtbd1@B
zfs_vdevs=vtbd100000@A,vtbd1@B
zfs_vdevs=/dev/vtbd0@A,vtbd1@B
zfs_vdevs=diskid/A@A,vtbd1@B
zfs_vdevs=vtbd0@A@B,vtbd1@B
zfs_vdevs=vtbd0@,vtbd1@B
zfs_vdevs=vtbd0@A, vtbd1@B
zfs_vdevs=vtbd0@\$(reboot),vtbd1@B
zfs_vdevs=vtbd0@\`reboot\`,vtbd1@B
zfs_vdevs=vtbd0@A$(printf '\t'),vtbd1@B
zfs_vdevs=vtbd0@$(printf 'A%.0s' {1..129}),vtbd1@B
zfs_vdevs=${long17%,}
zfs_vdevs=$(printf 'A%.0s' {1..4097})
filesystem=ufs
swap_size=1g
swap_size=00
swap_mode=mirror
swap_mode=
CASES
}

@test "the runtime rejects invalid topology membership, missing, extra and older-format fields" {
    policy 4 "$P4" >"$ROOT/config"
    local spec field extra format
    for spec in 'raid10|vtbd0@A,vtbd1@B' 'raid10|vtbd0@A,vtbd1@B,vtbd2@C,vtbd3@D' \
        'raid10|vtbd0@A;vtbd1@B,vtbd2@C,vtbd3@D' 'raid10|vtbd0@A,vtbd1@B;vtbd2@C,vtbd0@D' \
        'raidz1|vtbd0@A,vtbd1@B' 'raidz2|vtbd0@A,vtbd1@B,vtbd2@C' 'raidz3|vtbd0@A,vtbd1@B,vtbd2@C,vtbd3@D'; do
        set_value "$ROOT/config" zfs_topology "${spec%%|*}" "$ROOT/topology"
        set_value "$ROOT/topology" zfs_vdevs "${spec#*|}" "$ROOT/bad"
        ! cmp -s "$ROOT/config" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
    for field in zfs_topology zfs_vdevs swap_mode; do
        drop "$ROOT/config" "$field" "$ROOT/bad"
        rejects "$ROOT/bad"
    done
    for extra in target_disk=vtbd0 target_disk_ident=A reinstall_pool_guid=123 zfs_vdevs=vtbd0@A,vtbd1@B; do
        { cat "$ROOT/config"; printf '%s\n' "$extra"; } >"$ROOT/bad"
        rejects "$ROOT/bad"
    done
    for format in 1 2 3; do
        sed "s/install-4/install-$format/" "$ROOT/config" >"$ROOT/bad"
        rejects "$ROOT/bad"
    done
}

@test "automatic disk selection reaches the runtime as blank-only selection and group sizes" {
    local omit disk vdevs
    while IFS='|' read -r omit disk vdevs; do
        render '"contract":"xcat-freebsd-install-6","media":{"disk_selection_contract":"xcat-freebsd-disk-selection-1"},"omit":['"$omit"'],"disk":{'"$disk"'}' >"$ROOT/config"
        read_config "$ROOT/config" 'printf "%s|%s|%s\n" "$XCAT_DISK_SELECTION" "$XCAT_PRESERVE_DISKS" "$XCAT_ZFS_VDEVS"'
        [ "$status" -eq 0 ] || { echo "$disk rejected"; return 1; }
        [ "$output" = "empty|-|$vdevs" ]
        mutate "$ROOT/config" disk_selection erase "$ROOT/bad"
        read_config "$ROOT/bad" true
        [ "$status" -ne 0 ]
    done <<'CASES'
"target_disk_ident"|"target_disk":"auto","filesystem":"ufs"|
"target_disk_ident"|"target_disk":"auto","filesystem":"zfs"|
"target_disk","target_disk_ident"|"zfs_topology":"mirror","zfs_vdevs":"auto:2","swap_mode":"none","filesystem":"zfs"|auto:2
"target_disk","target_disk_ident"|"zfs_topology":"raid10","zfs_vdevs":"auto:2;auto:2","swap_mode":"none","filesystem":"zfs"|auto:2;auto:2
CASES
}
