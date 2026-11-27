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
| openSUSE  | Leap 42.3     | yes     | no       | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| openSUSE  | Leap 15.6     | yes     | no       | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+
| openSUSE  | Leap 16.0     | yes     | no       | no        | no        |
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
| FreeBSD   | 15.1          | preview | no       | no        | no        |
+-----------+---------------+---------+----------+-----------+-----------+

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

aarch64 support covers EL 10 on nodes that boot through UEFI firmware and grub2. The
management node, stateful compute nodes and stateless compute nodes are supported.
Sequential discovery is a technology preview. Service nodes and statelite are not covered. See
:doc:`/guides/admin-guides/manage_clusters/aarch64/index` for details.

FreeBSD 15.1 is a technology preview. It covers stateful compute nodes on x86_64 only. The
management node and service nodes stay Linux. See
:doc:`/guides/admin-guides/manage_clusters/x86_64/freebsd` for the tested configuration.

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
