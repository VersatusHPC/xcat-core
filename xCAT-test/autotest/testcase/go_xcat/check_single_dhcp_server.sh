#!/bin/bash
# Run on a node with xdsh -e, after go-xcat installed xCAT there.
# Pass when exactly one DHCP server package is installed and it is the backend that
# xCAT::DHCP::Backend selects. A second server starts unconfigured and logs errors at boot.

status_of()
{
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null
}

declare -A backend_of=( [isc-dhcp-server]=isc [kea-dhcp4-server]=kea )
installed=()
for pkg in isc-dhcp-server kea-dhcp4-server; do
    status=$(status_of "$pkg")
    echo "$pkg: ${status:-not-installed}"
    [ "$status" = installed ] && installed+=("$pkg")
done

if [ "${#installed[@]}" -ne 1 ]; then
    echo "FAIL: ${#installed[@]} DHCP server packages installed (${installed[*]}), want 1"
    exit 1
fi

chosen=$(perl -I/opt/xcat/lib/perl -MxCAT::DHCP::Backend -e \
    'my $s = xCAT::DHCP::Backend->choose(check_available => 1); print $s->{error} // $s->{name}')
want=${backend_of[${installed[0]}]}
if [ "$chosen" != "$want" ]; then
    echo "FAIL: ${installed[0]} is installed, xCAT::DHCP::Backend selects '$chosen'"
    exit 1
fi

echo "single DHCP server ${installed[0]}, selected backend $chosen"
