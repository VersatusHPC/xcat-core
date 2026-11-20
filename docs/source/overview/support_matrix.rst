Operating System & Hardware Support Matrix
==========================================

+-----------+---------------+---------+----------+-----------+
| Distro    | Version       | x86_64  | ppc64le  | riscv64   |
+===========+===============+=========+==========+===========+
| EL        | 8             | yes     | yes      | no        |
+-----------+---------------+---------+----------+-----------+
| EL        | 9             | yes     | yes      | no        |
+-----------+---------------+---------+----------+-----------+
| EL        | 10            | yes     | yes      | yes       |
+-----------+---------------+---------+----------+-----------+
| SLES      | 12            | yes     | yes      | no        |
+-----------+---------------+---------+----------+-----------+
| SLES      | 15            | yes     | yes      | no        |
+-----------+---------------+---------+----------+-----------+
| openSUSE  | Leap 42.3     | yes     | no       | no        |
+-----------+---------------+---------+----------+-----------+
| openSUSE  | Leap 15.6     | yes     | no       | no        |
+-----------+---------------+---------+----------+-----------+
| openSUSE  | Leap 16.0     | yes     | no       | no        |
+-----------+---------------+---------+----------+-----------+
| Ubuntu    | 22.04         | yes     | yes      | no        |
+-----------+---------------+---------+----------+-----------+
| Ubuntu    | 24.04         | yes     | yes      | yes       |
+-----------+---------------+---------+----------+-----------+
| Ubuntu    | 26.04         | yes     | yes      | yes       |
+-----------+---------------+---------+----------+-----------+
| openEuler | 20.03 LTS SP4 | yes     | no       | no        |
+-----------+---------------+---------+----------+-----------+
| openEuler | 22.03 LTS SP4 | yes     | no       | no        |
+-----------+---------------+---------+----------+-----------+
| openEuler | 24.03 LTS SP4 | yes     | no       | yes       |
+-----------+---------------+---------+----------+-----------+

.. note::

   EL stands for Enterprise Linux, such as: Red Hat Enterprise Linux (RHEL), Rocky Linux, AlmaLinux, CentOS and Oracle Linux.

   openSUSE Leap support covers the management node, and stateful and stateless compute
   nodes. Service nodes, statelite and node discovery are not supported on openSUSE Leap.
   Leap 42.3 installs from its DVD only, because its update repositories are archived.
   Leap 16.0 compute nodes install with the Agama installer, from the offline installer image.

   openEuler support covers the management node, installed and diskless service nodes, and
   stateful and stateless compute nodes. On riscv64, it covers only stateful and stateless
   compute nodes.

riscv64 support covers EL 10 (Rocky Linux 10 and the RHEL 10 RISC-V developer preview) and
Ubuntu 24.04 and 26.04, on nodes that boot through UEFI firmware and grub2. Both stateful and
stateless nodes are supported, and the management node itself can run on riscv64. See
:doc:`/guides/admin-guides/manage_clusters/riscv64/index` for details.
