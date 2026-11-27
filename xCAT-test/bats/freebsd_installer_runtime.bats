#!/usr/bin/env bats
#
# xcat-install-lib.sh, the installer runtime: configuration reading, the controller status
# exchange, the disk and label preflight and the installation sequence. Every FreeBSD command
# is a stub that records its arguments in $ROOT/events.

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPu2fQbGvNixfzG3hYrKcXFP6eZDrZMDnuES0GhLWDPE'
LABELS=$'pool_guid: 12345\nname: \'zroot\'\nvdev_children: 1\nvdev_tree:\n    type: \'disk\''

setup()
{
    DIR="$(freebsd_installer_dir)"
    LIB="$DIR/xcat-install-lib.sh"
    TEMPLATE="$DIR/installerconfig.tmpl"
    # parse is the last command of a pipeline and sets $status for the test.
    shopt -s lastpipe
}

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# configuration [field=value ...]: the legacy configuration, sorted by field.
configuration()
{
    declare -A f=([format]=xcat-freebsd-install-1 [release]=15.1-RELEASE [node]=node01
        [generation]=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa [master]=192.0.2.1 [port]=3002
        [mac]=52:54:00:12:34:56 [ipv4]=192.0.2.20 [netmask]=255.255.255.0 [gateway]=
        [hostname]=node01.example.test [target_disk]=ada0 [target_disk_ident]=XCAT_TEST_DISK
        [filesystem]=zfs [swap_size]=2g [dist_url]=http://192.0.2.1/install/freebsd/dist
        [base_sha256]="$(sha 'base archive')" [kernel_sha256]="$(sha 'kernel archive')"
        [authorized_key_base64]="$(printf '%s' "$KEY" | base64 -w0)" [nameservers]=192.0.2.1,192.0.2.2)
    local kv k
    for kv in "$@"; do f[${kv%%=*}]=${kv#*=}; done
    for k in "${!f[@]}"; do printf '%s=%s\n' "$k" "${f[$k]}"; done | LC_ALL=C sort
}

# The pkgbase configuration: format 2, no legacy distribution fields, four new ones.
pkgbase_configuration()
{
    configuration format=xcat-freebsd-install-2 | grep -Ev '^(dist_url|base_sha256|kernel_sha256)='
    printf 'install_url=http://192.0.2.1/install\npackage_plan_sha256=%s\nboot_media_sha256=%s\nruntime_sha256=%s\n' \
        "$(printf '3%.0s' {1..64})" "$(printf '4%.0s' {1..64})" "$(printf '5%.0s' {1..64})"
}

# set_field <field> <value>: replace one field read on stdin, which must be present.
set_field() { awk -v f="$1" -v v="$2" 'BEGIN {FS = OFS = "="} $1 == f {print f "=" v; n++; next} {print} END {exit n != 1}'; }

stub()
{
    freebsd_stub "$ROOT/bin/$1" <<STUB
#!/bin/sh
printf '%s %s\n' '$1' "\$*" >> "\$FIXTURE_DIR/events"
$2
STUB
}

# fixture [field=value ...]: sets ROOT.
fixture()
{
    ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
    mkdir -p "$ROOT/bin" "$ROOT/labels" "$ROOT/work"
    configuration "$@" >"$ROOT/config"
    printf 'base archive' >"$ROOT/base.txz"
    printf 'kernel archive' >"$ROOT/kernel.txz"
    printf 'base.txz\t%s\t10\tbase\tBase\ton\nkernel.txz\t%s\t5\tkernel\tKernel\ton\n' \
        "$(sha 'base archive')" "$(sha 'kernel archive')" >"$ROOT/MANIFEST"
    printf 'Geom name: ada0\nMediasize: 8589934592 (8.0G)\nMode: r0w0e0\nident: XCAT_TEST_DISK\n' >"$ROOT/disk"
    : >"$ROOT/pools"; : >"$ROOT/geli"
    printf 'Geom name: ada0\nProviders:\n1. Name: ada0p3\nConsumers:\n1. Name: ada0\n\nGeom name: ada1\nProviders:\n1. Name: ada1p3\nConsumers:\n1. Name: ada1\n' >"$ROOT/partitions"
    stub kldload 'test ! -f "$FIXTURE_DIR/kldload-status-$2" || exit "$(cat "$FIXTURE_DIR/kldload-status-$2")"'
    stub geom 'cat "$FIXTURE_DIR/disk"'
    stub geli 'cat "$FIXTURE_DIR/geli"'
    stub sysctl 'printf "ada0 ada1\n"'
    stub gpart 'test ! -f "$FIXTURE_DIR/gpart-status" || exit "$(cat "$FIXTURE_DIR/gpart-status")"; cat "$FIXTURE_DIR/partitions"'
    stub zdb 'test ! -f "$FIXTURE_DIR/zdb-status-${2##*/}" || exit "$(cat "$FIXTURE_DIR/zdb-status-${2##*/}")"
test -f "$FIXTURE_DIR/labels/${2##*/}" || exit 2; cat "$FIXTURE_DIR/labels/${2##*/}"'
    stub zpool 'case "$1" in list) cat "$FIXTURE_DIR/pools" ;; labelclear) ;; *) exit 1 ;; esac'
    stub fetch 'cp "$FIXTURE_DIR/${5##*/}" "$4"'
    stub sha256 'openssl dgst -sha256 -r "$2" | awk "{print \$1}"'
    stub nc 'read -r protocol generation attempt phase members; printf "phase %s\n" "$phase" >> "$FIXTURE_DIR/events"
count=0; test ! -f "$FIXTURE_DIR/nc-count" || count=$(cat "$FIXTURE_DIR/nc-count"); count=$((count+1)); printf "%s\n" "$count" > "$FIXTURE_DIR/nc-count"
if [ -f "$FIXTURE_DIR/reject-$phase" ] || { test -f "$FIXTURE_DIR/nc-busy" && test "$count" -le "$(cat "$FIXTURE_DIR/nc-busy")"; }; then printf "ready\n"; else printf "ready\n%s %s %s ok\n" "$protocol" "$generation" "$phase"; fi'
    stub date 'if test -f "$FIXTURE_DIR/clock"; then cat "$FIXTURE_DIR/clock"; else printf "0\n"; fi'
    stub sleep 'now=0; test ! -f "$FIXTURE_DIR/clock" || now=$(cat "$FIXTURE_DIR/clock"); printf "%s\n" "$((now+$1))" > "$FIXTURE_DIR/clock"'
    stub timeout 'shift; exec "$@"'
    stub ifconfig 'case "$*" in -l) printf "em0 em1 lo0\n" ;; em0) printf "ether 52:54:00:12:34:56\n" ;; em1) printf "ether 52:54:00:12:34:57\n" ;; lo0) printf "inet 127.0.0.1\n" ;; esac'
    # The installer starts bsdinstall without FIXTURE_DIR, so this stub names the root itself.
    printf '#!/bin/sh\nprintf "bsdinstall %%s\\n" "$*" >> "%s/events"\ntest ! -e "%s/install-fails"\n' "$ROOT" "$ROOT" |
        freebsd_stub "$ROOT/bin/bsdinstall"
}

# runtime <script> [args]: the script runs with the library sourced and $1 the config.
runtime()
{
    PATH="$ROOT/bin:$PATH" FIXTURE_DIR="$ROOT" XCAT_WORK="$ROOT/work" \
        XCAT_ATTEMPT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb XCAT_PROVISIONING_IF=em0 \
        run sh -c '. "$1"; shift; '"$1"' 2>&1' sh "$LIB" "$ROOT/config" "${@:2}"
}

events() { cat "$ROOT/events" 2>/dev/null || true; }

# parse <bytes on stdin>: status of xcat_read_config on those bytes, in a fresh fixture.
parse() { fixture; cat >"$ROOT/config"; runtime 'xcat_read_config "$1"'; }

@test "the runtime files have shell syntax" {
    local file
    for file in xcat-install xcat-install-lib.sh buildmfsbsd.sh installerconfig.tmpl; do sh -n "$DIR/$file"; done
}

@test "a configuration download waits for a delayed virtual network, once for a physical one" {
    fixture
    freebsd_stub "$ROOT/bin/fetch" <<'STUB'
#!/bin/sh
now=0
test ! -f "$FIXTURE_DIR/clock" || now=$(cat "$FIXTURE_DIR/clock")
if test "$now" -lt 12; then printf partial > "$4"; exit 1; fi
cp "$FIXTURE_DIR/config" "$4"
STUB
    runtime 'XCAT_BOOT_NETWORK_BASE64=present; xcat_fetch_config http://192.0.2.1/config'
    [ "$status" -eq 0 ]
    cmp "$ROOT/work/config" "$ROOT/config"
    rm "$ROOT/clock"
    runtime 'XCAT_BOOT_NETWORK_BASE64=; xcat_fetch_config http://192.0.2.1/config'
    [ "$status" -ne 0 ]
    printf '#!/bin/sh\nprintf partial > "$4"\nexit 1\n' | freebsd_stub "$ROOT/bin/fetch"
    rm -f "$ROOT/work/config"
    runtime 'XCAT_BOOT_NETWORK_BASE64=present; xcat_fetch_config http://192.0.2.1/config'
    [ "$status" -ne 0 ]
    [ ! -e "$ROOT/work/config" ]
}

@test "ZFS and UFS render their own partitioning" {
    fixture filesystem=zfs
    runtime 'xcat_read_config "$1" && xcat_write_installer "$2"' "$TEMPLATE"
    [ "$status" -eq 0 ]
    grep -qx 'export ZFSBOOT_DISKS="ada0"' <<<"$output"
    grep -qx 'export ZFSBOOT_VDEV_TYPE="stripe"' <<<"$output"
    ! grep -q '^PARTITIONS=' <<<"$output"
    fixture filesystem=ufs
    runtime 'xcat_read_config "$1" && xcat_write_installer "$2"' "$TEMPLATE"
    [ "$status" -eq 0 ]
    grep -qxF 'PARTITIONS="ada0 GPT { 2g freebsd-swap, auto freebsd-ufs / }"' <<<"$output"
    ! grep -q '^export ZFSBOOT_DISKS=' <<<"$output"
}

@test "the reader rejects invalid field values" {
    local bad
    for bad in target_disk=md0 'target_disk=ada0 ada1' target_disk=/dev/ada0 target_disk_ident= generation=bad \
        "base_sha256=$(printf 'f%.0s' {1..63})" filesystem=ext4 'swap_size=$(touch BAD)' port=0 \
        mac=52:54:00:12:34:xx ipv4=192.0.2.256 ipv4=192.0.02.1 netmask=255.0.255.0 netmask=255.255.127.0 \
        nameservers=192.0.2.1, dist_url=http://192.0.2.1/../dist 'authorized_key_base64=$(id)' unknown=value; do
        fixture "$bad"
        runtime 'xcat_read_config "$1"'
        [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
    done
}

@test "only a real public key is accepted, and duplicate fields fail" {
    fixture
    runtime 'xcat_read_config "$1" && xcat_validate_key "$XCAT_WORK/key"'
    [ "$status" -eq 0 ]
    local bad
    for bad in '-----BEGIN OPENSSH PRIVATE KEY-----' 'ssh-ed25519 AAAAA'; do
        configuration authorized_key_base64="$(printf '%s' "$bad" | base64 -w0)" >"$ROOT/config"
        runtime 'xcat_read_config "$1" && xcat_validate_key "$XCAT_WORK/key"'
        [ "$status" -ne 0 ]
    done
    { configuration; echo filesystem=ufs; } >"$ROOT/config"
    runtime 'xcat_read_config "$1"'
    [ "$status" -ne 0 ]
}

@test "the boot MAC selects only the provisioning NIC" {
    fixture
    runtime 'xcat_find_interface 52:54:00:12:34:56'
    [ "$status" -eq 0 ]
    [ "$output" = em0 ]
    runtime 'xcat_find_interface 52:54:00:12:34:99'
    [ "$status" -ne 0 ]
    runtime 'xcat_find_interface ""'
    [ "$status" -ne 0 ]
}

@test "the status exchange retries a busy controller for fifteen minutes" {
    fixture
    echo 4 >"$ROOT/nc-busy"
    runtime 'xcat_read_config "$1" && xcat_status complete'
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/nc-count")" = 5 ]
    [[ "$(events)" == *'nc -w 65 '* ]]
    : >"$ROOT/reject-booted"
    runtime 'xcat_read_config "$1" && xcat_status booted'
    [ "$status" -ne 0 ]
    [ "$(cat "$ROOT/clock")" = 920 ]
}

scan() { runtime 'xcat_read_config "$1" && xcat_scan_labels && printf "%s" "$XCAT_CLEAR_LABELS"'; }

@test "a blank target has no labels to clear" {
    local partitions
    for partitions in '' $'Geom name: ada1\nProviders:\n1. Name: ada1p3\nConsumers:\n1. Name: ada1\n'; do
        fixture
        printf '%s' "$partitions" >"$ROOT/partitions"
        scan
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "nested providers and disk-ID aliases resolve to the selected disk once" {
    fixture
    printf 'Geom name: ada0\nProviders:\n1. Name: ada0s1\nConsumers:\n1. Name: ada0\n\nGeom name: ada0s1\nProviders:\n1. Name: ada0s1a\nConsumers:\n1. Name: ada0s1\n' >"$ROOT/partitions"
    printf '%s\n' "$LABELS" >"$ROOT/labels/ada0s1a"
    scan
    [ "$status" -eq 0 ]
    [ "$output" = ' /dev/ada0s1a' ]
    fixture
    printf '\nGeom name: diskid/DISK-QM00001\nProviders:\n1. Name: diskid/DISK-QM00001p3\nConsumers:\n1. Name: diskid/DISK-QM00001\n' >>"$ROOT/partitions"
    printf '%s\n' "$LABELS" >"$ROOT/labels/ada0p3"
    scan
    [ "$status" -eq 0 ]
    [ "$output" = ' /dev/ada0p3' ]
}

@test "unreadable or malformed metadata stops before authorization and disk mutation" {
    local spec file value
    while IFS='|' read -r file value; do
        fixture
        printf '%b' "$value" >"$ROOT/$file"
        runtime 'xcat_read_config "$1" && xcat_install_system "$2"' "$TEMPLATE"
        [ "$status" -ne 0 ] || { echo "accepted $file=$value"; return 1; }
        ! grep -Eq 'phase begin|zpool labelclear|bsdinstall script' "$ROOT/events"
    done <<'CASES'
kldload-status-zfs|1
kldload-status-geom_eli|1
kldload-status-zfs|127
kldload-status-geom_eli|127
gpart-status|1
gpart-status|127
zdb-status-ada0p3|1
zdb-status-ada0p3|127
zdb-status-ada1p3|1
zdb-status-ada1p3|127
labels/ada0p3|unrecognized valid label
partitions|unrecognized partition list
partitions|Geom name: ada0\nProviders:\n1. Name: ../ada1\nConsumers:\n1. Name: ada0\n
CASES
}

@test "label clearing selects only the authorized single-disk pool" {
    fixture
    printf '%s\n' "$LABELS" >"$ROOT/labels/ada0p3"
    runtime 'xcat_read_config "$1" && xcat_scan_labels && printf "%s\n" "$XCAT_CLEAR_LABELS"'
    [ "$status" -eq 0 ]
    [ "$output" = ' /dev/ada0p3' ]
    printf '%s\n' "$LABELS" >"$ROOT/labels/ada1p3"
    runtime 'xcat_read_config "$1" && xcat_scan_labels'
    [ "$status" -ne 0 ]
    ! grep -q 'zpool labelclear' "$ROOT/events"
    local topology
    for topology in 'vdev_children: 2' $'vdev_children: 1\n    type: \'mirror\''; do
        fixture
        printf "pool_guid: 12345\nname: 'zroot'\n%s\n" "$topology" >"$ROOT/labels/ada0p3"
        runtime 'xcat_read_config "$1" && xcat_scan_labels'
        [ "$status" -ne 0 ]
    done
}

@test "an unsafe disk state is rejected" {
    local file value
    while IFS='|' read -r file value; do
        fixture
        printf '%b' "$value" >"$ROOT/$file"
        runtime 'xcat_read_config "$1" && xcat_check_disk'
        [ "$status" -ne 0 ] || { echo "accepted $file"; return 1; }
    done <<'CASES'
disk|Geom name: ada0\nMediasize: 8589934592\nMode: r0w0e0\nident: OTHER_DISK\n
disk|Geom name: ada0\nMediasize: 8589934592\nMode: r1w1e1\nident: XCAT_TEST_DISK\n
pools|data\n
geli|ada1p3.eli ACTIVE ada1p3\n
CASES
}

@test "the installation runs checksums, authorization, label clearing, installer and completion in order" {
    fixture
    printf '%s\n' "$LABELS" >"$ROOT/labels/ada0p3"
    runtime 'xcat_read_config "$1" && xcat_install_system "$2"' "$TEMPLATE"
    [ "$status" -eq 0 ]
    local e; e=$(tr '\n' ' ' <"$ROOT/events")
    [[ "$e" =~ kldload\ -n\ zfs.*kldload\ -n\ geom_eli.*zpool\ list.*geli\ status ]]
    [[ "$e" =~ sha256\ .*base\.txz.*sha256\ .*kernel\.txz.*phase\ begin.*zpool\ labelclear\ -f\ /dev/ada0p3.*bsdinstall\ script.*phase\ complete ]]
    ! grep -q 'zpool labelclear.*ada1' "$ROOT/events"
}

@test "a failure stops the installation before it modifies the disk or reports completion" {
    local failure
    for failure in checksum manifest begin installer complete; do
        fixture
        printf '%s\n' "$LABELS" >"$ROOT/labels/ada0p3"
        case $failure in
            checksum) printf 'bad archive' >"$ROOT/base.txz" ;;
            manifest) printf 'base.txz\tbad\n' >"$ROOT/MANIFEST" ;;
            begin|complete) : >"$ROOT/reject-$failure" ;;
            installer) : >"$ROOT/install-fails" ;;
        esac
        runtime 'xcat_read_config "$1" && xcat_install_system "$2"' "$TEMPLATE"
        [ "$status" -ne 0 ] || { echo "$failure did not stop"; return 1; }
        case $failure in
            checksum|manifest|begin) ! grep -Eq 'zpool labelclear|bsdinstall script' "$ROOT/events" ;;
            installer) ! grep -q 'phase complete' "$ROOT/events" ;;
        esac
    done
}

@test "each configuration version requires its own field roster" {
    local common='format release node generation master port mac ipv4 netmask gateway hostname target_disk target_disk_ident filesystem swap_size authorized_key_base64 nameservers'
    local label field
    for label in legacy pkgbase; do
        if [ $label = legacy ]; then configuration; else pkgbase_configuration; fi >"$BATS_TEST_TMPDIR/$label"
        parse <"$BATS_TEST_TMPDIR/$label"
        [ "$status" -eq 0 ]
        local specific='dist_url base_sha256 kernel_sha256'
        [ $label = pkgbase ] && specific='install_url package_plan_sha256 boot_media_sha256 runtime_sha256'
        for field in $common $specific; do
            grep -v "^$field=" "$BATS_TEST_TMPDIR/$label" | parse
            if [ $label = legacy ] && { [ $field = gateway ] || [ $field = nameservers ]; }; then
                [ "$status" -eq 0 ] || { echo "legacy needs $field"; return 1; }
            else
                [ "$status" -ne 0 ] || { echo "$label accepted no $field"; return 1; }
            fi
        done
    done
    for field in dist_url base_sha256 kernel_sha256; do
        { pkgbase_configuration; echo "$field="; } | parse; [ "$status" -ne 0 ]
    done
    for field in install_url package_plan_sha256 boot_media_sha256 runtime_sha256; do
        { configuration; echo "$field="; } | parse; [ "$status" -ne 0 ]
    done
}

@test "pkgbase digests, URLs and name lengths are checked" {
    local field bad url
    for field in package_plan_sha256 boot_media_sha256 runtime_sha256; do
        for bad in '' "$(printf 'a%.0s' {1..63})" "$(printf 'A%.0s' {1..64})" "$(printf 'a%.0s' {1..65})"; do
            pkgbase_configuration | set_field "$field" "$bad" | parse
            [ "$status" -ne 0 ] || { echo "accepted $field=$bad"; return 1; }
        done
        { pkgbase_configuration; echo "$field=$(printf '3%.0s' {1..64})"; } | parse
        [ "$status" -ne 0 ]
    done
    { pkgbase_configuration; echo unknown=value; } | parse
    [ "$status" -ne 0 ]
    for url in '' file:///install http://192.0.2.1/install/../private; do
        pkgbase_configuration | set_field install_url "$url" | parse
        [ "$status" -ne 0 ] || { echo "accepted $url"; return 1; }
    done
    for field in node hostname; do
        pkgbase_configuration | set_field "$field" "$(printf 'a%.0s' {1..247})" | parse
        [ "$status" -eq 0 ]
        pkgbase_configuration | set_field "$field" "$(printf 'a%.0s' {1..248})" | parse
        [ "$status" -ne 0 ]
    done
}

@test "each read clears the fields of the other configuration version" {
    fixture
    pkgbase_configuration >"$ROOT/pkgbase-config"
    runtime 'xcat_read_config "$1" || exit
printf "legacy|%s|%s|%s|%s\n" "$XCAT_INSTALL_URL" "$XCAT_PACKAGE_PLAN_SHA256" "$XCAT_BOOT_MEDIA_SHA256" "$XCAT_RUNTIME_SHA256"
xcat_read_config "$2" || exit
printf "pkgbase|%s|%s|%s|%s\n" "$XCAT_PACKAGE_PLAN_SHA256" "$XCAT_DIST_URL" "$XCAT_BASE_SHA256" "$XCAT_KERNEL_SHA256"
xcat_read_config "$1" || exit
printf "legacy-again|%s|%s|%s|%s\n" "$XCAT_INSTALL_URL" "$XCAT_PACKAGE_PLAN_SHA256" "$XCAT_BOOT_MEDIA_SHA256" "$XCAT_RUNTIME_SHA256"' "$ROOT/pkgbase-config"
    [ "$status" -eq 0 ]
    [ "$output" = "legacy||||
pkgbase|$(printf '3%.0s' {1..64})|||
legacy-again||||" ]
}

@test "the reader keeps the 32768-byte bound and the pkgbase line rules" {
    local label small size
    for label in legacy pkgbase; do
        if [ $label = legacy ]; then configuration; else pkgbase_configuration; fi | set_field authorized_key_base64 A >"$BATS_TEST_TMPDIR/small"
        size=$((32768 - $(wc -c <"$BATS_TEST_TMPDIR/small") + 1))
        set_field authorized_key_base64 "$(head -c "$size" /dev/zero | tr '\0' A)" <"$BATS_TEST_TMPDIR/small" >"$BATS_TEST_TMPDIR/exact"
        [ "$(wc -c <"$BATS_TEST_TMPDIR/exact")" -eq 32768 ]
        parse <"$BATS_TEST_TMPDIR/exact"; [ "$status" -eq 0 ]
        set_field authorized_key_base64 "$(head -c $((size + 1)) /dev/zero | tr '\0' A)" <"$BATS_TEST_TMPDIR/small" | parse
        [ "$status" -ne 0 ]
    done
    { printf '\n# retained legacy comment\n'; configuration | head -c -1; } | parse
    [ "$status" -eq 0 ]
    pkgbase_configuration >"$BATS_TEST_TMPDIR/v2"
    head -c -1 "$BATS_TEST_TMPDIR/v2" | parse; [ "$status" -ne 0 ]
    { echo; cat "$BATS_TEST_TMPDIR/v2"; } | parse; [ "$status" -ne 0 ]
    { echo '# not a v2 record'; cat "$BATS_TEST_TMPDIR/v2"; } | parse; [ "$status" -ne 0 ]
    perl -pe 's/^node=.*/node=node\x0001/' "$BATS_TEST_TMPDIR/v2" | parse; [ "$status" -ne 0 ]
    perl -pe 's/^node=.*/node=node\xc3\xa9/' "$BATS_TEST_TMPDIR/v2" | parse; [ "$status" -ne 0 ]
    set_field target_disk_ident $'XCAT\tTEST' <"$BATS_TEST_TMPDIR/v2" | parse; [ "$status" -ne 0 ]
    set_field target_disk_ident $'XCAT_TEST_DISK\r' <"$BATS_TEST_TMPDIR/v2" | parse; [ "$status" -ne 0 ]
}

@test "a parsed pkgbase configuration cannot start an installation" {
    fixture
    pkgbase_configuration >"$ROOT/config"
    runtime 'xcat_read_config "$1" || exit 91; printf "parsed-pkgbase\n"; xcat_install_system "$2"' "$TEMPLATE"
    [ "$status" -ne 0 ]
    [ "${lines[0]}" = parsed-pkgbase ]
    [[ "$output" == *'Pkgbase installation runtime is not available'* ]]
    [ ! -s "$ROOT/events" ]
    [ ! -e "$ROOT/work/installerconfig" ] && [ ! -e "$ROOT/work/dist" ]
}

@test "only the pkgbase begin reports the resolved primary members" {
    fixture
    pkgbase_configuration >"$ROOT/config"
    freebsd_stub "$ROOT/bin/nc" <<'STUB'
#!/bin/sh
read -r protocol generation attempt phase members
printf '%s|%s|%s\n' "$protocol" "$phase" "$members" >> "$FIXTURE_DIR/status-wire"
printf 'ready\n%s %s %s ok\n' "$protocol" "$generation" "$phase"
STUB
    runtime 'xcat_read_config "$1" && xcat_status begin && xcat_status complete'
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/status-wire")" = $'freebsd-install-v2|begin|ada0@XCAT_TEST_DISK\nfreebsd-install-v1|complete|' ]
    : >"$ROOT/status-wire"
    runtime 'xcat_read_config "$1" || exit; XCAT_FORMAT=xcat-freebsd-install-5; XCAT_FILESYSTEM=zfs; XCAT_SWAP_MODE=none; XCAT_SWAP_SIZE=0; XCAT_ZFS_TOPOLOGY=raid10; XCAT_ZFS_VDEVS="ada0@OS0,ada1@OS1;ada2@OS2,ada3@OS3"; xcat_status begin'
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/status-wire")" = 'freebsd-install-v2|begin|ada0@OS0,ada1@OS1;ada2@OS2,ada3@OS3' ]
}
