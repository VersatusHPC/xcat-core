grub2 support for x86_64, aarch64 and riscv64
=============================================

xCAT does not ship a grub2 binary for x86_64. To use grub2 for x86_64, download the binary from an EL OS repository.

aarch64 nodes boot through UEFI firmware and grub2 only. The ``grub2-xcat`` package from xcat-dep (1.0-4 or later) installs ``/tftpboot/boot/grub2/grub2.aarch64``, built with the ``/boot/grub2`` prefix that the configuration written by ``nodeset`` needs. Use it instead of the distribution ``grubaa64.efi``, which carries the distribution prefix.

riscv64 nodes can only boot through UEFI firmware and grub2, so they always need ``grub2.riscv64``. ``copycds`` publishes it from the riscv64 installation media, and recent ``grub2-xcat`` packages from xcat-dep install the same image; if your management node has neither (``ls /tftpboot/boot/grub2/grub2.riscv64``), copy the binary by hand as described below.

#. Download files from an BaseOS EL repository mirror

        For EL these files are named ``grubx64.efi`` (x86_64), ``grubaa64.efi`` (aarch64) and ``grubriscv64.efi`` (riscv64) and usually in ``BaseOS/<arch>/os/EFI/BOOT``.
        For very recent hardware you might need to use a newer grub version. Therefore, it's recommended to use a binary from the latest operationg system release available.
        You can use Red Hat Enterprise Linux, AlmaLinux, Rocky Linux or even Fedora repositories to download the grub files.

#. Copy downloaded files to ``/tftpboot/boot/grub2``:

        * x86_64: ``/tftpboot/boot/grub2/grub2.x86_64``
        * aarch64: ``/tftpboot/boot/grub2/grub2.aarch64``
        * riscv64: ``/tftpboot/boot/grub2/grub2.riscv64``

