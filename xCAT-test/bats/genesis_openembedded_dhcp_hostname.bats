#!/usr/bin/env bats
#
# Every OpenEmbedded Genesis node runs one image with one hostname, xcat-genesis-<arch>. When
# NetworkManager sends that hostname in DHCP, the ISC dhcpd of the MN makes a DDNS update for it,
# and the second nic or node to ask is refused: "Has an address record but no DHCID, not mine".
#
# The value NetworkManager uses for <family>.dhcp-send-hostname is the one in the connection
# profile when the profile sets it, else the last [connection] default in conf.d, else true.
# NetworkManager 1.56 reads that default as an integer from 0 to 1 and uses true for any other
# value, "false" included (_prop_get_ipvx_dhcp_send_hostname in src/core/devices/nm-device.c).
# The profiles are the two that genesis-bootnic writes, or the default wired profile when the
# command line has no BOOTIF.

load 'helpers/shell_source'

NETWORK='xCAT-genesis-base/oe/meta-xcat-genesis/recipes-connectivity/xcat-genesis-network'

setup()
{
    PACKAGED_CONF="$(repo_path "$NETWORK/files/10-xcat-genesis.conf")"
    BOOTNIC="$(repo_path "$NETWORK/files/genesis-bootnic")"
    DUID="$(repo_path "$NETWORK/files/genesis-duid")"
    CONFD="${BATS_TEST_TMPDIR}/conf.d"
    CONND="${BATS_TEST_TMPDIR}/system-connections"
    CMDLINE="${BATS_TEST_TMPDIR}/cmdline"
    UUID="${BATS_TEST_TMPDIR}/product_uuid"
    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$CONFD" "$BIN"
    printf '#!/bin/sh\nexit 0\n' >"$BIN/logger"
    chmod 0755 "$BIN/logger"
    cp "$PACKAGED_CONF" "$CONFD/10-xcat-genesis.conf"
    printf '%s\n' '4c4c4544-0042-3510-8051-b4c04f4e3732' >"$UUID"
}

# Run genesis-duid and genesis-bootnic as the image runs them, before NetworkManager.
boot_image()
{
    printf '%s\n' "$1" >"$CMDLINE"
    env PATH="$BIN:$PATH" XCAT_PRODUCT_UUID_FILE="$UUID" XCAT_NM_CONF_DIR="$CONFD" \
        bash "$DUID"
    env PATH="$BIN:$PATH" XCAT_CMDLINE_FILE="$CMDLINE" XCAT_NM_CONF_DIR="$CONFD" \
        XCAT_NM_CONNECTION_DIR="$CONND" bash "$BOOTNIC"
}

# keyfile_value <file> <section> <key>: the last value of section.key in one keyfile.
keyfile_value()
{
    awk -v section="[$2]" -v key="$3" '
        /^\[/ { in_section = ($0 == section); next }
        in_section && index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
        END { if (value != "") print value }
    ' "$1"
}

# send_hostname <family> [profile]: 0 or 1, the value NetworkManager uses for that profile.
send_hostname()
{
    local family=$1 profile=${2:-} value="" file found
    if [ -n "$profile" ]; then
        case $(keyfile_value "$profile" "$family" dhcp-send-hostname) in
            true | 1) value=1 ;;
            false | 0) value=0 ;;
        esac
    fi
    if [ -z "$value" ]; then
        for file in $(LC_ALL=C ls "$CONFD"/*.conf); do
            found=$(keyfile_value "$file" connection "$family.dhcp-send-hostname")
            [ -z "$found" ] || value=$found
        done
        case $value in
            0 | 1) ;;
            *) value=1 ;;
        esac
    fi
    printf '%s\n' "$value"
}

@test "the boot nic profile sends no hostname in DHCPv4 or DHCPv6" {
    boot_image 'BOOTIF=01-42-7c-b6-21-e1-81'
    [ "$(send_hostname ipv4 "$CONND/xcat-genesis-bootnic.nmconnection")" = 0 ]
    [ "$(send_hostname ipv6 "$CONND/xcat-genesis-bootnic.nmconnection")" = 0 ]
}

@test "the secondary nic profile sends no hostname in DHCPv4 or DHCPv6" {
    boot_image 'BOOTIF=01-42-7c-b6-21-e1-81'
    [ "$(send_hostname ipv4 "$CONND/xcat-genesis-secondary.nmconnection")" = 0 ]
    [ "$(send_hostname ipv6 "$CONND/xcat-genesis-secondary.nmconnection")" = 0 ]
}

@test "without BOOTIF the default wired profile sends no hostname" {
    boot_image 'quiet'
    [ ! -e "$CONND" ] || [ -z "$(ls "$CONND")" ]
    [ "$(send_hostname ipv4)" = 0 ]
    [ "$(send_hostname ipv6)" = 0 ]
}
