#!/usr/bin/env bats
#
# xcat-install-lib.sh reads the boot and console settings that xCAT::FreeBSDConfig writes,
# renders them into the installer, and brings up the bootstrap network. The configurations
# come from the Perl producer (fixtures/freebsd-render-config.pl).

bats_require_minimum_version 1.5.0
load 'helpers/freebsd'

ENHANCED='"disk":{"bootstrap":"static"},"options":"hint.example=install R::hint.example=target R::boot_verbose=yes","console":{"serialport":"1","serialspeed":"115200","serialflow":"hard"}'
LOADER_START="cat >> /boot/loader.conf <<'XCAT_LOADER_SETTINGS'"
TARGET_LOADER='boot_verbose="YES"
hint.example="target"
comconsole_port="0x2f8"
comconsole_speed="115200"
console="comconsole,${console}"
boot_serial="YES"
boot_multicons="YES"
hw.uart.console="io:0x2f8,br:115200"
hint.uart.1.at="acpi"
hint.uart.1.port="0x2f8"'

setup()
{
    LIB="$(freebsd_installer_dir)/xcat-install-lib.sh"
    ROOT="$BATS_TEST_TMPDIR"
    printf '#!/bin/sh\nset -eu\n' >"$ROOT/template"
}

render() { perl "$(repo_path xCAT-test/bats/fixtures/freebsd-render-config.pl)" "{$1}"; }

# lib <script> [args]: run a script with the installer library sourced.
lib() { LC_ALL=C run sh -c '. "$1"; shift; '"$1" xcat-test "$LIB" "${@:2}"; }

# read_config <config file> [script]
read_config() { lib 'xcat_read_config "$1" || exit 1; shift; '"${2:-:}" "$1"; }

# installer <config file>: the rendered installer script.
installer() { lib 'xcat_read_config "$1" || exit 1; XCAT_WORK=/tmp/work; xcat_write_installer "$2" "$3"' "$1" "$ROOT/template" "$LIB"; }

# The loader block an installer persists for the target.
persisted() { awk -v start="$LOADER_START" '$0 == start {on=1; next} on && $0 == "XCAT_LOADER_SETTINGS" {exit} on' <<<"$1"; }

enhanced() { render "$ENHANCED" >"$ROOT/config"; }

@test "the runtime consumes the exact bootstrap and console settings" {
    enhanced
    read_config "$ROOT/config" 'printf "%s|%s|%s|%s\n" "$XCAT_BOOTSTRAP" "$XCAT_CONSOLE_PORT" "$XCAT_CONSOLE_SPEED" "$XCAT_CONSOLE_FLOW"'
    [ "$status" -eq 0 ]
    [ "$output" = 'static|1|115200|hard' ]
}

@test "the runtime keeps only the R:: boot options, with canonical values" {
    enhanced
    read_config "$ROOT/config" 'xcat_boot_options "$XCAT_TARGET_BOOT_OPTIONS_BASE64"'
    [ "$status" -eq 0 ]
    [ "$output" = $'boot_verbose="YES"\nhint.example="target"' ]
}

@test "the installer persists the target options and the native console settings" {
    enhanced
    installer "$ROOT/config"
    [ "$status" -eq 0 ]
    [ "$(persisted "$output")" = "$TARGET_LOADER" ]
    [[ "$output" == *'xcatserial:np:nc:sp#115200:hw:'* ]]
    [[ "$output" == *'ttyu1 "/usr/libexec/getty xcatserial" vt100 on insecure'* ]]
}

@test "multi-disk rendering keeps the member order, the topology and the boot settings" {
    local spec topology vdevs ordered
    for spec in 'mirror|vtbd2@C,vtbd0@A|vtbd2 vtbd0' 'raid10|vtbd3@D,vtbd1@B;vtbd2@C,vtbd0@A|vtbd3 vtbd1 vtbd2 vtbd0' \
        'raidz1|vtbd2@C,vtbd0@A,vtbd1@B|vtbd2 vtbd0 vtbd1' 'raidz2|vtbd3@D,vtbd1@B,vtbd2@C,vtbd0@A|vtbd3 vtbd1 vtbd2 vtbd0' \
        'raidz3|vtbd4@E,vtbd2@C,vtbd0@A,vtbd3@D,vtbd1@B|vtbd4 vtbd2 vtbd0 vtbd3 vtbd1'; do
        IFS='|' read -r topology vdevs ordered <<<"$spec"
        render "$ENHANCED"',"contract":"xcat-freebsd-install-4","set":{"filesystem":"zfs","swap_size":"0","swap_mode":"none","zfs_topology":"'"$topology"'","zfs_vdevs":"'"$vdevs"'"},"delete":["target_disk","target_disk_ident"]' >"$ROOT/config"
        installer "$ROOT/config"
        [ "$status" -eq 0 ]
        grep -qxF "export ZFSBOOT_DISKS=\"$ordered\"" <<<"$output"
        grep -qxF "export ZFSBOOT_VDEV_TYPE=\"$topology\"" <<<"$output"
        ! grep -q '^PARTITIONS=' <<<"$output"
        [ "$(persisted "$output")" = "$TARGET_LOADER" ]
        read_config "$ROOT/config" 'XCAT_BOOTSTRAP_MODE=dhcp; xcat_check_bootstrap'
        [ "$status" -ne 0 ]
        read_config "$ROOT/config" 'XCAT_BOOTSTRAP_MODE=static; XCAT_BOOTSTRAP_IPV4=$XCAT_IPV4; XCAT_BOOTSTRAP_NETMASK=$XCAT_NETMASK; XCAT_BOOTSTRAP_GATEWAY=$XCAT_GATEWAY; xcat_check_bootstrap'
        [ "$status" -eq 0 ]
    done
}

@test "new media defaults to DHCP and the firmware console" {
    render '' >"$ROOT/config"
    read_config "$ROOT/config" 'printf "%s|%s\n" "$XCAT_BOOTSTRAP" "$XCAT_CONSOLE_PORT"'
    [ "$status" -eq 0 ]
    [ "$output" = 'dhcp|none' ]
}

@test "the runtime rejects malformed and executable target options" {
    enhanced
    local options encoded
    for options in 'console="comconsole"\n' 'hint.uart.0.port="0x2f8"\n' 'xcat_config_url="bad"\n' \
        'exec="reboot"\n' 'foo_before="reboot"\n' 'hint.a="1"\nhint.a="2"\n' 'hint.z="1"\nhint.a="2"\n' \
        'foo_load="yes"\n' 'hint.a="${bad}"\n' 'hint.a="x"' 'hint.a="x"\n\n' 'hint.a="x"\0\n'; do
        encoded=$(printf "$options" | base64 -w0)
        sed "s|^target_boot_options_base64=.*|target_boot_options_base64=$encoded|" "$ROOT/config" >"$ROOT/invalid"
        ! cmp -s "$ROOT/config" "$ROOT/invalid"
        read_config "$ROOT/invalid"
        [ "$status" -ne 0 ] || { echo "accepted $options"; return 1; }
    done
}

@test "the runtime requires every enhanced key and the enhanced contract" {
    enhanced
    local key
    for key in bootstrap console_port console_speed console_flow install_boot_options_base64 target_boot_options_base64; do
        sed "/^$key=/d" "$ROOT/config" >"$ROOT/missing"
        ! cmp -s "$ROOT/config" "$ROOT/missing"
        read_config "$ROOT/missing"
        [ "$status" -ne 0 ] || { echo "accepted a config without $key"; return 1; }
    done
    sed 's/xcat-freebsd-install-3/xcat-freebsd-install-2/' "$ROOT/config" >"$ROOT/legacy"
    read_config "$ROOT/legacy"
    [ "$status" -ne 0 ]
}

@test "the installation and the target render the same console for each port" {
    local port ports=(0x3f8 0x2f8 0x3e8 0x2e8) controller
    for port in 0 1 2 3; do
        render '"console":{"serialport":"'$port'","serialspeed":"19200"}' >"$ROOT/config"
        controller=$(render '"console":{"serialport":"'$port'","serialspeed":"19200"},"output":"loader"' | grep -v '^xcat_bootstrap="dhcp"$')
        read_config "$ROOT/config" xcat_console_settings
        [ "$status" -eq 0 ]
        [ "$output" = "$controller" ]
        grep -qxF "comconsole_port=\"${ports[$port]}\"" <<<"$output"
        grep -qxF "hint.uart.$port.at=\"acpi\"" <<<"$output"
        grep -qxF "hint.uart.$port.port=\"${ports[$port]}\"" <<<"$output"
    done
}

@test "the runtime accepts the aggregate byte bound and rejects one byte more" {
    local small pad
    small=$(render "$ENHANCED"',"set":{"authorized_key_base64":"A"}' | wc -c)
    pad=$(printf 'A%.0s' $(seq 1 $((32769 - small))))
    render "$ENHANCED"',"set":{"authorized_key_base64":"'"$pad"'"}' >"$ROOT/exact"
    [ "$(wc -c <"$ROOT/exact")" -eq 32768 ]
    read_config "$ROOT/exact"
    [ "$status" -eq 0 ]
    { cat "$ROOT/exact"; echo; } >"$ROOT/over"
    read_config "$ROOT/over"
    [ "$status" -ne 0 ]
}

@test "the runtime rejects invalid bootstrap and console values" {
    enhanced
    local kv
    for kv in bootstrap=automatic console_port=4 console_speed=115201 console_flow=soft; do
        sed "s|^${kv%%=*}=.*|$kv|" "$ROOT/config" >"$ROOT/bad"
        ! cmp -s "$ROOT/config" "$ROOT/bad"
        read_config "$ROOT/bad"
        [ "$status" -ne 0 ] || { echo "accepted $kv"; return 1; }
    done
}

# bootstrap: the MAC-selected interface, with kenv, ifconfig, dhclient and route as functions.
bootstrap()
{
    lib 'fixture=$1; shift; kenv() { cat "$fixture/env/$2"; }
        ifconfig() { case "$1" in -l) printf "em0 em1 lo0\n";;
            em0) printf "ether 52:54:00:00:00:01\n";;
            em1) if [ "$#" -eq 1 ]; then printf "ether 52:54:00:12:34:56\n";
                 else printf "ifconfig %s\n" "$*" >> "$fixture/calls"; fi;; esac; }
        dhclient() { printf "dhclient %s\n" "$*" >> "$fixture/calls"; }
        route() { printf "route %s\n" "$*" >> "$fixture/calls"; }
        XCAT_PROVISIONING_IF=$(xcat_find_interface 52:54:00:12:34:56) || exit 1
        xcat_bootstrap_network || exit 1; xcat_read_config "$fixture/config" || exit 1; xcat_check_bootstrap' "$ROOT"
}

kenv_set() { mkdir -p "$ROOT/env"; printf '%s\n' "$2" >"$ROOT/env/$1"; }

@test "a static bootstrap configures only the MAC-selected interface" {
    enhanced
    kenv_set xcat_bootstrap static; kenv_set xcat_bootstrap_ipv4 192.0.2.10
    kenv_set xcat_bootstrap_netmask 255.255.255.0; kenv_set xcat_bootstrap_gateway 192.0.2.1
    : >"$ROOT/calls"
    bootstrap
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/calls")" = $'ifconfig em1 inet 192.0.2.10 netmask 255.255.255.0 up\nroute add default 192.0.2.1' ]
    kenv_set xcat_bootstrap_ipv4 192.0.2.11
    bootstrap
    [ "$status" -ne 0 ]
    kenv_set xcat_bootstrap_netmask 255.0.255.0
    : >"$ROOT/calls"
    bootstrap
    [ "$status" -ne 0 ]
    [ ! -s "$ROOT/calls" ]
}

@test "a DHCP bootstrap runs dhclient on the MAC-selected interface only" {
    render "$ENHANCED"',"set":{"bootstrap":"dhcp"}' >"$ROOT/config"
    kenv_set xcat_bootstrap dhcp
    : >"$ROOT/calls"
    bootstrap
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/calls")" = 'dhclient em1' ]
}
