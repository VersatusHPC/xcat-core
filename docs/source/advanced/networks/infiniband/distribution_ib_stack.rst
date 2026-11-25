InfiniBand Stack of the Distribution
====================================

From xCAT 2.21, a node can use the InfiniBand stack that the distribution ships (``rdma-core``)
instead of MLNX_OFED. The distribution stack needs no ISO, no DKMS and no rebuild of the kernel
modules. The ``ib_ipoib`` module comes with the kernel.

.. note:: xCAT 2.21 ships the distribution stack as a technology preview. The package lists and
   ``configib`` are tested in the xCAT CI on nodes without an InfiniBand card. A run on a
   ConnectX card is not done yet.

Package lists
-------------

xCAT ships these lists:

+------------------+-------------------------------------------------------------------------+
| Node             | List                                                                    |
+==================+=========================================================================+
| EL 9, diskless   | ``/opt/xcat/share/xcat/ib/netboot/rh/ib.rhels9.x86_64.pkglist``         |
+------------------+-------------------------------------------------------------------------+
| EL 10, diskless  | ``/opt/xcat/share/xcat/ib/netboot/rh/ib.rhels10.x86_64.pkglist``        |
+------------------+-------------------------------------------------------------------------+
| EL 9, diskful    | ``/opt/xcat/share/xcat/install/rh/ib.rhels9.x86_64.pkglist``            |
+------------------+-------------------------------------------------------------------------+
| EL 10, diskful   | ``/opt/xcat/share/xcat/install/rh/ib.rhels10.x86_64.pkglist``           |
+------------------+-------------------------------------------------------------------------+
| Ubuntu 24.04     | ``/opt/xcat/share/xcat/ib/netboot/ubuntu/ib.pkglist``                   |
+------------------+-------------------------------------------------------------------------+

The EL lists hold ``rdma-core``, ``libibverbs-utils``, ``librdmacm-utils``,
``infiniband-diags``, ``ibacm``, ``opensm``, ``perftest`` and ``ucx``. All eight are on the
AlmaLinux 9 and 10 DVDs, in BaseOS and AppStream. The Ubuntu list holds the same set with the
Ubuntu names. On Ubuntu, all of them except ``rdma-core`` are in ``universe``, which is not on
the installation ISO. Give the osimage a ``pkgdir`` or ``otherpkgdir`` that carries ``universe``.
The ``ib_ipoib`` module of Ubuntu is in ``linux-modules-extra-<kernel>``. The generic kernel
installs it, but the ``linux-virtual`` kernel of the Ubuntu cloud images does not.

The netboot list holds only the InfiniBand packages. Add it after the compute list: ::

    chdef -t osimage <osimage> -p pkglist=/opt/xcat/share/xcat/ib/netboot/rh/ib.rhels10.x86_64.pkglist
    genimage <osimage>
    packimage <osimage>

The diskful list includes the compute list, so it replaces it: ::

    chdef -t osimage <osimage> pkglist=/opt/xcat/share/xcat/install/rh/ib.rhels10.x86_64.pkglist

On a node that is already installed, ``updatenode <node> -P ospkgs`` installs the list of the
osimage.

The IB driver
-------------

``configib`` uses the ``openibd`` service only when MLNX_OFED installed it. On the distribution
stack there is no driver service: ``configib`` loads ``ib_ipoib`` with ``modprobe``, and udev
loads the modules at the next boot. ``configib`` logs which stack it uses.

A node without an InfiniBand device
-----------------------------------

``configib`` fails when an InfiniBand nic of the ``nics`` table has no InfiniBand device on the
node, or when the link layer of the device is not InfiniBand. A broken IB driver in an image
looks the same, and the xCAT CI cannot provision over IB, so this check is what stops a node from
going to production without IB. ``configib`` waits 10 seconds for ``ib_ipoib`` to create the
device, writes no configuration for the nic, prints and logs an error, and exits 1: ::

    configib: ERROR: ib0 is an InfiniBand nic in the nics table, but the node has no InfiniBand device ib0

``confignetwork`` and ``updatenode`` then fail. Define the IB nics of a node only when the node
has the card.
