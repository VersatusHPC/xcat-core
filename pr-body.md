fix(xcat-core): a pool-backed KVM disk reaches libvirt with no bus

A node whose vmstorage is a libvirt storage pool (dir://, nfs:// or lvm://) gets a <disk> element with no bus attribute. libvirt then chooses the controller from the name of the device alone, so the disk of a riscv64 node works only while its volume is named sd*.

build_diskstruct in xCAT-server/lib/xcat/plugins/kvm.pm matches the pool entry, a hash reference, against /^vd/, /^hd/ and /^sd/. A reference in a match is its address as a string, so no branch runs and the bus is never set. The name of the device is in the device field of that entry.

The three tests now read that field. The bus each one sets is the bus libvirt gives an hd*, sd* or vd* name, so no domain changes. A riscv64 node keeps the sd* name its volume has, and keeps the scsi controller the riscv64 virt machine provides.

xCAT-test/unit/kvm_diskstruct_bus.t drives build_diskstruct in a scratch package, with a stub storage pool in place of the one routine that reaches libvirt. It asserts the bus of an hd*, an sd* and a vd* volume, and that a riscv64 node keeps the sd* name of its volume. Four of its seven assertions fail without the fix.

Commits: 8d811d6e5 test, 20ff90aad fix
