fix(xcat-core): mkvm builds a riscv64 node as an x86_64 domain

A node with arch=riscv64 gets an x86_64 libvirt domain from mkvm. The node takes a DHCP lease and receives the riscv64 GRUB binary that nodeset staged, and cannot run it. The firmware falls through to the empty disk and stops, so both flat provisioning cases of the riscv64 cell fail.

build_xmldesc and build_diskstruct in xCAT-server/lib/xcat/plugins/kvm.pm read the architecture from the hypervisor cpumodel. The arch of the node is never read while the domain XML is built, so on an x86_64 hypervisor every guest is an x86_64 guest.

guest_arch_profile now takes the arch of the node as well. It returns the domain type, the <os> arch and machine, the firmware and the device settings that follow from them. A riscv64 node becomes a qemu domain with the virt machine type and UEFI firmware. It drops the parts the riscv64 virt machine has no controller for, or that libvirt refuses there: the pae, acpi and apic features, the SeaBIOS serial option, the ich6 sound card, the USB tablet, and the ide disk and hd* optical drive. libvirt resolves the emulator and the UEFI firmware files itself. POWER and x86_64 domains do not change.

xCAT-test/unit/kvm_guest_arch.t drives build_xmldesc and build_diskstruct in a scratch package, with stubs only for the routines that reach libvirt or the xCAT database. It asserts the domain and the disks of a riscv64 node, and keeps the POWER and x86_64 domains as they are. Ten of its twenty assertions fail without the fix.

Commits: a9f1aefe5 test, 1fe2eb8b1 fix
