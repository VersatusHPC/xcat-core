ARM 64-bit (aarch64)
====================

xCAT manages ARM 64-bit (``aarch64``) nodes running EL 10. The management node,
stateful compute nodes and stateless compute nodes are supported. The general
cluster management documentation under
:doc:`/guides/admin-guides/manage_clusters/index` applies. This page covers only
what is specific to the architecture.

What aarch64 nodes need
-----------------------

* **UEFI firmware that can PXE boot.** aarch64 nodes boot through UEFI and grub2
  only. The firmware sends DHCP option 93 (client system architecture) value 11
  (``0x000b``).
* ``noderes.netboot`` is one of ``grub2``, ``grub2-tftp`` or ``grub2-http``.
* ``nodetype.arch`` and ``osimage.osarch`` are ``aarch64``.
* ``/tftpboot/boot/grub2/grub2.aarch64``: the grub2 UEFI image the firmware
  loads. The ``grub2-xcat`` package from xcat-dep (1.0-4 or later) installs it
  with the ``/boot/grub2`` prefix. The distribution ``grubaa64.efi`` carries the
  distribution prefix and does not find the configuration ``nodeset`` writes.
* The serial console is ``ttyAMA<site.defserialport>``, the PL011 UART of the
  ARM server and QEMU ``virt`` machines.

Boot file names
---------------

Some aarch64 UEFI firmware ignores a DHCP boot file name that does not end in
``.efi`` and requests ``grubaa64.efi`` instead. xCAT therefore offers names that
end in ``.efi``:

* A node with a DHCP reservation gets ``/boot/grub2/grub2-<node>.efi`` after
  ``nodeset`` has created that link.
* A client without a reservation, for example a node in discovery, gets
  ``boot/grub2/grub2.aarch64.efi``. ``mknb aarch64`` links this name to
  ``grub2.aarch64``, and ``makedhcp`` names it only when the link exists.
  Run ``mknb aarch64`` and then ``makedhcp -n`` after you install or update
  ``grub2-xcat``.

Node discovery
--------------

Sequential discovery of aarch64 nodes is a technology preview in this release.

Discovery boots the OpenEmbedded Genesis image
(``xCAT-genesis-openembedded-aarch64`` from ``xcat-dep/common``). ``xCAT``
recommends the package, and ``mknb`` prefers it to the legacy
``xCAT-genesis-base-aarch64`` when both are installed.

``mknb aarch64`` publishes the Genesis kernel and initramfs under
``/tftpboot/xcat`` and writes one grub2 configuration per network,
``/tftpboot/boot/grub2/grub.cfg-<hex network prefix>``. The aarch64 entries are
guarded by the GRUB cpu ``arm64``, so one file serves aarch64 and riscv64 nodes
on the same network. Run ``mknb aarch64`` after you define the networks, and
after a change to ``site.master`` or the serial console settings.

A discovered aarch64 node gets ``nodetype.arch=aarch64`` and, when no grub2
method is set, ``noderes.netboot=grub2``. Use the discovery procedures
documented for the other architectures.

Stateful and stateless nodes
----------------------------

Import the EL 10 aarch64 DVD with ``copycds``. It creates the
``<os>-aarch64-install-compute`` and ``<os>-aarch64-netboot-compute`` osimages.
``genimage`` builds stateless images on an aarch64 management node.

Not covered
-----------

* Service nodes: xCAT ships no ``service.*.aarch64`` package lists.
* Statelite.
* An x86_64 management node that serves aarch64 nodes. A stateless image needs
  ``genimage`` to run aarch64 code, which this configuration does not test.
* Distributions other than EL 10.
* The ``.efi`` boot file names are tested against QEMU UEFI firmware only, which
  accepts any name.
