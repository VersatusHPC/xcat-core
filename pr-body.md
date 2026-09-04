fix(dhcp): Kea writes no reservation for a node on a relayed network

makedhcp writes no DHCP reservation for a node whose network is reached by a DHCP relay. The plugin reports "Unable to find a Kea subnet for testnode (100.100.100.2)" and skips the node. The case makedhcp_remote_network fails on every cell that runs Kea, and passes on the cells that run ISC.

kea_build_dhcp4_intent in xCAT-server/lib/xcat/plugins/dhcp.pm skips a network whose networks.mgtifname carries the !remote! prefix, unless site.dhcpinterfaces also lists the literal !remote! token. The network then gets no subnet4. subnet_id_for_ip in xCAT::DHCP::Backend::Kea has no subnet to name, so it drops the reservation. The ISC path in the same file calls addnet for a !remote! network with no such condition.

This change removes the condition. A !remote! network now gets a subnet4, as ISC gets a subnet declaration. The subnet names no interface, so Kea keeps listening on the local provisioning interfaces only, and selects the subnet from the giaddr of the relay.

xCAT-test/unit/dhcp_kea_remote_network.t builds the Kea DHCPv4 configuration from a networks table that holds one local network and one relayed network, then builds the reservation of a node on the relayed network. The test executes kea_build_dhcp4_intent; it does not read the source. Nine of its thirteen assertions fail without the change: the relayed network gets no subnet4, and the node gets a warning in place of a reservation.

Commits: 3fa82dc test, 696774a fix
