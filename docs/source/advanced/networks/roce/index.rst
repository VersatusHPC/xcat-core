RoCE v2 (Tech Preview)
======================

.. note:: RoCE support is a technology preview in xCAT 2.21. It is tested with soft-RoCE (``rdma_rxe``) only. PFC and ECN are not configured.

``confignetwork`` configures a RoCE v2 interface from the ``nics`` table. For a NIC with ``nictypes`` set to ``RoCE``, it:

#. Configures the IP address of the NIC, the same as for an ``Ethernet`` NIC.
#. Uses the RDMA device that the adapter binds to the NIC. If the NIC has no RDMA device, it loads ``rdma_rxe`` and adds a soft-RoCE link named ``rxe_<nic>``.
#. Sets RoCE v2 as the default ``rdma_cm`` mode of the RDMA device, in configfs (``/sys/kernel/config/rdma_cm``).
#. Writes and enables the systemd unit ``xcat-roce-<nic>.service``. The unit does steps 2 and 3 again at boot.

Requirements
------------

* The compute node needs the ``rdma-core`` package (the RDMA libraries and module setup) and the ``rdma`` command from ``iproute``. The xCAT default package lists do not include ``rdma-core``. Add ``rdma-core`` to the package list of the osimage, or install it before you run ``confignetwork``. ``librdmacm-utils`` (``rping``) and ``perftest`` (``ib_send_bw``) are useful to test the link.
* For soft-RoCE, the node kernel must supply the ``rdma_rxe`` module. The openEuler 24.03 and EL 9 kernels supply it. The EL 10 kernel does not.

Configure a RoCE NIC
--------------------

Define a network for the RoCE subnet, then set the NIC attributes of the node: ::

    mkdef -t network -o roce_net net=198.18.0.0 mask=255.255.255.0 mgtifname=ens4
    chdef cn1 nicips.ens4=198.18.0.10 nictypes.ens4=RoCE nicnetworks.ens4=roce_net

Run ``confignetwork`` on the node: ::

    updatenode cn1 -P confignetwork

Verify the RDMA link and the RoCE v2 GID of the address on the node: ::

    xdsh cn1 "rdma link show"
    xdsh cn1 "ibv_devinfo -v | grep -i 'RoCE v2'"
