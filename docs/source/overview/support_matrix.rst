Operating System & Hardware Support Matrix
==========================================

+-----------+---------------+---------+----------+-----------+-----------+
| Distro    | Version       | x86_64  | ppc64le  | riscv64   | aarch64   |
+===========+===============+=========+==========+===========+===========+
| EL        | 8             | yes     | yes      | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| EL        | 9             | yes     | yes      | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| EL        | 10            | yes     | yes      | yes       | yes       |
+-----------+---------------+---------+----------+-----------+-----------+
| SLES      | 12            | yes     | yes      | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| SLES      | 15            | yes     | yes      | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| Ubuntu    | 22.04         | yes     | yes      | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| Ubuntu    | 24.04         | yes     | yes      | yes       | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| Ubuntu    | 26.04         | yes     | yes      | yes       | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| openEuler | 20.03 LTS SP4 | yes     | no       | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| openEuler | 22.03 LTS SP4 | yes     | no       | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| openEuler | 24.03 LTS SP4 | yes     | no       | yes       | no        |
+-----------+---------------+---------+----------+-----------+-----------+

.. note::

   EL stands for Enterprise Linux, such as: Red Hat Enterprise Linux (RHEL), Rocky Linux, AlmaLinux, CentOS and Oracle Linux.

   openEuler support covers the management node, installed and diskless service nodes, and
   stateful and stateless compute nodes. On riscv64, it covers only stateful and stateless
   compute nodes.

riscv64 support covers EL 10 (Rocky Linux 10 and the RHEL 10 RISC-V developer preview) and
Ubuntu 24.04 and 26.04, on nodes that boot through UEFI firmware and grub2. Both stateful and
stateless nodes are supported, and the management node itself can run on riscv64. See
:doc:`/guides/admin-guides/manage_clusters/riscv64/index` for details.

aarch64 support covers EL 10 on nodes that boot through UEFI firmware and grub2. The
management node, stateful compute nodes and stateless compute nodes are supported.
Sequential discovery is a technology preview. Service nodes and statelite are not covered. See
:doc:`/guides/admin-guides/manage_clusters/aarch64/index` for details.
