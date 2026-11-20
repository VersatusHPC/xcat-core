#!/usr/bin/env bats
#
# A diskless node with the USB NIC of a BMC host interface ends "degraded": NetworkManager starts
# DHCP on that NIC, gets no lease, and NetworkManager-wait-online fails. The image gets a
# NetworkManager file that leaves the USB class drivers of a BMC gadget unmanaged.

load 'helpers/shell_source'

setup()
{
    SCRIPT="$(require_repo_file 'xCAT-server/share/xcat/netboot/imgutils/bmc_usb_nic_unmanaged.sh')"
    ROOTIMG="${BATS_TEST_TMPDIR}/rootimg"
    mkdir -p "$ROOTIMG/etc"
    CONF="$ROOTIMG/etc/NetworkManager/conf.d/90-xcat-bmc-usb-nic.conf"
}

@test "the image gets a NetworkManager file that leaves the BMC USB drivers unmanaged" {
    run sh "$SCRIPT" "$ROOTIMG"
    [ "$status" -eq 0 ]
    [ -f "$CONF" ]
    grep -qx 'managed=0' "$CONF"
    for d in cdc_ether cdc_ncm cdc_eem rndis_host; do
        grep -q "^match-device=.*driver:$d" "$CONF"
    done
}

@test "the file has one device section, so NetworkManager reads it" {
    sh "$SCRIPT" "$ROOTIMG"
    [ "$(grep -c '^\[device' "$CONF")" -eq 1 ]
}

@test "a second run writes the same file" {
    sh "$SCRIPT" "$ROOTIMG"
    first="$(cat "$CONF")"
    sh "$SCRIPT" "$ROOTIMG"
    [ "$(cat "$CONF")" = "$first" ]
}

@test "no rootimg is an error and writes nothing" {
    run sh "$SCRIPT" "${BATS_TEST_TMPDIR}/missing"
    [ "$status" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/missing" ]
}
