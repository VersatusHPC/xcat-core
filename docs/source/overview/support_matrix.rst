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

   openEuler support covers the management node, installed and diskless service nodes, and
   stateful and stateless compute nodes. On riscv64, it covers only stateful and stateless
   compute nodes.

riscv64 support covers EL 10 (Rocky Linux 10 and the RHEL 10 RISC-V developer preview) and
Ubuntu 24.04 and 26.04, on nodes that boot through UEFI firmware and grub2. Both stateful and
stateless nodes are supported, and the management node itself can run on riscv64. See
:doc:`/guides/admin-guides/manage_clusters/riscv64/index` for details.

KVM
---

xCAT manages KVM virtual machines (VMs) with ``mkvm``, ``rmvm``, ``rpower`` and ``lsvm``, and
can install an EL node as a KVM host. See
:doc:`/guides/admin-guides/manage_clusters/common/kvm/kvm_host`.

+--------------------------------------------+---------------------------------------------+
| Item                                       | State                                       |
+============================================+=============================================+
| VMs on a KVM host, x86_64 and ppc64le      | tested, management node on EL, openEuler,   |
|                                            | openSUSE Leap and Ubuntu                    |
+--------------------------------------------+---------------------------------------------+
| UEFI Secure Boot VMs                       | tested on x86_64                            |
+--------------------------------------------+---------------------------------------------+
| KVM host installed by xCAT, EL 10 x86_64   | tested                                      |
+--------------------------------------------+---------------------------------------------+
| KVM host installed by xCAT, EL 8 and EL 9, | templates shipped, not tested               |
| and ppc64le                                |                                             |
+--------------------------------------------+---------------------------------------------+
| Diskless KVM host; KVM host on Ubuntu,     | not supported                               |
| openSUSE or openEuler                      |                                             |
+--------------------------------------------+---------------------------------------------+
| ``chvm``, ``clonevm``, ``rmigrate``,       | not tested                                  |
| storage other than ``dir:``                |                                             |
+--------------------------------------------+---------------------------------------------+
