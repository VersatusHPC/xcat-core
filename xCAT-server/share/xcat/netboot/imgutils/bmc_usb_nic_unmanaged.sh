#!/bin/sh
# Usage: bmc_usb_nic_unmanaged.sh <rootimg>
#
# Write a NetworkManager file into a diskless image that leaves the USB NIC of a BMC host
# interface unmanaged. The NIC always has link and never gets a lease, so the node ends degraded.
# The driver list is the one post.rhels8 skips for a diskful node.

root=$1
if [ -z "$root" ] || [ ! -d "$root/etc" ]; then
    echo "bmc_usb_nic_unmanaged.sh: $root is not a rootimg" >&2
    exit 1
fi

mkdir -p "$root/etc/NetworkManager/conf.d" || exit 1
cat >"$root/etc/NetworkManager/conf.d/90-xcat-bmc-usb-nic.conf" <<'END'
# Written by xCAT: the USB NIC of a BMC host interface gets no DHCP lease.
[device-xcat-bmc-usb-nic]
match-device=driver:cdc_ether,driver:cdc_ncm,driver:cdc_eem,driver:rndis_host
managed=0
END
