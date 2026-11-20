Firewall
========

The ``configfirewall`` postscript configures the host firewall of a management node, a service
node or a compute node. Run it on the management node from ``/install/postscripts``, or on a
node as a postbootscript.

Backends
--------

======================================  ===================================================
OS                                      Backend
======================================  ===================================================
EL 9, EL 10, openEuler with firewalld   firewalld (``firewall-cmd --permanent``, then ``--reload``)
EL without firewalld                    iptables, saved to ``/etc/sysconfig/iptables``
SLES, openSUSE                          ``/etc/sysconfig/SuSEfirewall2``
Ubuntu                                  iptables, restored from ``/etc/rc.local``
======================================  ===================================================

The firewalld backend is measured on EL 9 and EL 10 x86_64. The other backends are unchanged.

Usage
-----

::

    configfirewall --private <nic>[,<nic>...] --public <nic> [--nat] [--ports <port>[,<port>...]]
    configfirewall --auto [--nat] [--ports <port>[,<port>...]]

With firewalld:

* Each private NIC goes to the ``trusted`` zone. The zone accepts all traffic, so DHCP,
  DHCPv6, ICMPv6, router advertisements, TFTP and NFS reach the node.
* The public NIC goes to the ``public`` zone, which opens TCP and UDP ports 22, 53, 69, 80,
  443, 873, 3001 and 3002, plus the ports that ``--ports`` names.
* A NIC that is both private and public stays in ``trusted``.
* ``--nat`` turns on IPv4 forwarding, masquerades on the ``public`` zone and adds the policy
  ``xcat-nat`` that forwards from ``trusted`` to ``public``.
* ``--auto`` takes the private NICs from the NICs with an address in an xCAT network: the
  ``networks`` table on the management node, or the ``NETWORKS_LINE`` variables in a
  postscript. The public NIC is the NIC of the default route.

Every change is permanent and only adds. Ports and services that other tools opened stay open.

``configfirewall`` writes ``/etc/xcat/configfirewall.backend``. When that file exists,
``xcatconfig -i`` and ``xcatconfig -f`` keep the firewall running instead of stopping it.

The iptables backend writes IPv4 rules only. Use firewalld for an IPv6 provisioning network.

To configure a service node at boot::

    chdef <sn> -p postbootscripts="configfirewall --auto"

The installation templates keep ``firewall --disable`` in the kickstart, because the
postbootscript runs after the installation.
