test(dhcp): capture Kea losing the reservation of a node on a relayed network

makedhcp writes no DHCP reservation for a node whose network is reached by a DHCP relay. The plugin reports "Unable to find a Kea subnet for testnode (100.100.100.2)" and skips the node. The case makedhcp_remote_network fails on every cell that runs Kea, and passes on the cells that run ISC.

kea_build_dhcp4_intent in xCAT-server/lib/xcat/plugins/dhcp.pm skips a network whose networks.mgtifname carries the !remote! prefix, unless site.dhcpinterfaces also lists the literal !remote! token. The network then gets no subnet4, and the Kea backend has no subnet to name in the reservation.

This branch carries the test commit of fix/kea-remote-network-reservation, and nothing else. The maintainers push it alone so the CI shows the new case red before the fix lands. It is not a separate change to merge on its own. Merge fix/kea-remote-network-reservation, which carries the same test commit and then the fix.

xCAT-test/unit/dhcp_kea_remote_network.t builds the Kea DHCPv4 configuration for a networks table that holds one local network and one relayed network, then builds the reservation of a node on the relayed network. The test executes kea_build_dhcp4_intent; it does not read the source. Nine of its thirteen assertions fail on this branch, because the fix commit is absent.

Commits: 3fa82dc test
