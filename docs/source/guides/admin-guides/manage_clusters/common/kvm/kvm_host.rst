Install an EL KVM Host
======================

xCAT can install an Enterprise Linux node as a KVM host, and then create and install virtual
machines (VMs) on that host with ``mkvm``. This section describes the KVM host. For the VMs, see
:doc:`/guides/admin-guides/manage_clusters/ppc64le/virtual_machines/manage_vms`.

Tested scope
------------

The xCAT CI installs an EL 10 x86_64 node as a KVM host, creates a bridge on it, creates a VM on
it with ``mkvm`` and installs the VM. The table shows what is tested.

+------------------------------------------+-------------------------------------------+
| Item                                     | State                                     |
+==========================================+===========================================+
| KVM host, EL 10 x86_64, installed        | tested                                    |
+------------------------------------------+-------------------------------------------+
| KVM host, EL 8 and EL 9, and ppc64le     | templates shipped, not tested             |
+------------------------------------------+-------------------------------------------+
| KVM host, diskless                       | not supported                             |
+------------------------------------------+-------------------------------------------+
| KVM host on Ubuntu, openSUSE, openEuler  | not supported                             |
+------------------------------------------+-------------------------------------------+
| VM storage ``dir:``                      | tested                                    |
+------------------------------------------+-------------------------------------------+
| VM storage ``nfs:``, ``lvm:``, ``phy:``  | not tested                                |
+------------------------------------------+-------------------------------------------+
| ``chvm``, ``clonevm``, ``rmigrate``      | not tested                                |
+------------------------------------------+-------------------------------------------+

The osimage
-----------

The ``kvm`` profile installs the compute package list plus ``qemu-kvm`` and ``libvirt``. Its
kickstart template is the compute template. ``copycds`` does not create a ``kvm`` osimage, so
define one for the OS that ``copycds`` copied: ::

    mkdef -t osimage -o alma10.1-x86_64-install-kvm imagetype=linux osname=Linux \
        osvers=alma10.1 osarch=x86_64 profile=kvm provmethod=install \
        pkgdir=/install/alma10.1/x86_64

``nodeset`` then finds ``kvm.alma10.tmpl`` and ``kvm.alma10.pkglist`` in
``/opt/xcat/share/xcat/install/alma``. The ``rh`` and ``rocky`` directories carry the same files
for RHEL and Rocky Linux 8, 9 and 10.

The KVM host needs hardware virtualization. On a physical host, enable it in the firmware. On a
host that is itself a VM, use a CPU model that passes ``svm`` or ``vmx`` to the guest. Check
it after the install: ::

    xdsh kvmhost1 "grep -c -w -E 'svm|vmx' /proc/cpuinfo"

The bridge
----------

A VM attaches its network interface to a bridge on the KVM host. The ``xHRM`` postscript creates
the bridge during the install. Add it to the postscripts of the host before you install it: ::

    chdef kvmhost1 -p postscripts="xHRM bridgeprereq br0"
    rinstall kvmhost1 osimage=alma10.1-x86_64-install-kvm

``xHRM`` selects the installation NIC as the bridge port. To name the port, use
``xHRM bridgeprereq eth0:br0``.

On EL 9 and later, ``bridge-utils`` is not available, and ``xHRM`` uses NetworkManager. The bridge
has STP off, no forward delay and the MAC address of its port, so the DHCP reservation of the
host stays valid. The bridge takes the IPv4 setup of the port. During the install,
NetworkManager does not run, so ``xHRM`` writes the profiles to
``/etc/NetworkManager/system-connections`` and they become active at the first boot. When you
run ``xHRM`` on a booted host with ``updatenode kvmhost1 -P "xHRM bridgeprereq br0"``, it
activates the profiles at once.

``xHRM`` does not create a bridge on a bond or a VLAN with NetworkManager. For these, use
``confignetwork`` with ``nictypes.<bridge>=bridge``. See
:doc:`/guides/admin-guides/manage_clusters/ppc64le/diskful/customize_image/network/cfg_network_adapter`.

Check the bridge on the host: ::

    # ip -br link show br0
    br0              UP             42:54:00:c9:9a:10 <BROADCAST,MULTICAST,UP,LOWER_UP>
    # bridge link
    2: ens3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding priority 32 cost 4

Create a VM on the host
-----------------------

Set the KVM host as the ``vmhost`` of the VM and attach the VM to the bridge. Without a
``cpumode`` in ``vmothersetting``, the VM gets the ``qemu64`` CPU model, and EL 9 and later do not
boot on it. ::

    mkdef -t node -o vm1 groups=all,vm ip=192.168.0.11 arch=x86_64 mgt=kvm cons=kvm \
        vmhost=kvmhost1 vmcpus=2 vmmemory=4096 vmnics=br0 vmnicnicmodel=virtio \
        vmstorage=dir:///var/lib/libvirt/images vmothersetting=cpumode:host-passthrough
    makehosts vm1
    makedns -n
    mkvm vm1 -s 10G
    lsvm kvmhost1
    rinstall vm1 osimage=alma10.1-x86_64-install-compute
