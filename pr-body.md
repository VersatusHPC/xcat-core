fix(xcat-core): a riscv64 node never starts, because its emulator refuses the VNC password

makedom sets a VNC password on every domain it starts. qemu needs a DES cipher backend for VNC password authentication. The qemu-system-riscv64 build on the test hypervisor has none, so qemu exits with "Cipher backend does not support DES algorithm". rpower on leaves the riscv64 node down, and both flat provisioning cases of the el10 riscv64 cell fail.

makedom in xCAT-server/lib/xcat/plugins/kvm.pm sets the passwd attribute on the graphics element before it starts the domain, whatever the emulator. build_xmldesc also wrote a password attribute into the description that mkvm stores in the kvm_nodedata table. libvirt reads passwd, so that attribute never reached a domain.

makedom now starts the domain a second time without the VNC password, but only when vnc_password_rejected matches that libvirt error text. Every other error is returned as before, and an emulator that takes the password keeps it. A domain that gives up the password also gives up listen 0.0.0.0: set_graphics_listen moves the console to 127.0.0.1, in the listen attribute and in the child listen element, which libvirt requires to agree. makedom warns the client, so rpower names the node whose console has no password. build_xmldesc no longer writes the password attribute.

xCAT-test/unit/kvm_makedom_vnc_password.t drives makedom against a libvirt connection that refuses a description carrying passwd. It asserts the retry, the empty password, the loopback address in both places, the client warning, and that an unrelated error is not retried. xCAT-test/unit/kvm_graphics_password.t asserts the stored description carries no password. Each test fails on its own commit, before its fix.

Commits: 874bd9bd5 test, cd699323b test, 09bdc1d53 fix, d0244de90 test, cbcd1c34f fix
